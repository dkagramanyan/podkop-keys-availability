"""The manager's core: one runtime per router (status polling, the agent's
live event stream, apply jobs, probe runs, key usage and traffic), the
nightly probe schedule, and fan-out of live updates to the browsers."""

from __future__ import annotations

import asyncio
import contextlib
import datetime as dt
import logging
import time
from pathlib import Path

from . import podkop, usage
from .agent import Agent, AgentError
from .db import DB

log = logging.getLogger("podkop_manager")

FINAL_JOB_STATES = {"applied", "saved", "unchanged", "rejected", "reverted", "failed"}
OK_JOB_STATES = {"applied", "saved", "unchanged"}
# events shown next to the router's name until something newer happens
ALERT_EVENTS = ("reverted", "revert_failed")
POLL_SECONDS = 30
TRAFFIC_SECONDS = 60     # the router's traffic per server
USAGE_SECONDS = 600      # the providers' numbers, read through the router


class RouterRuntime:
    def __init__(self, row: dict, key: Path):
        self.id = row["id"]
        self.row = row
        self.agent = Agent(row["host"], row["port"], row["host_key"], key)
        self.status: dict | None = None
        self.proxies: dict | None = None
        self.names: dict = {}
        self.names_fp = ""
        self.config: dict | None = None    # the last config-get
        self.draft: dict | None = None     # summary of the unapplied draft
        self.alert: dict | None = None     # the last change undone on the router
        self.usage: dict = {"pct": None, "alerts": []}   # daily limits, for the menu and Overview
        self.online = False
        self.error = ""
        self.down_since: float | None = None
        self.checked = 0.0
        self.tasks: list[asyncio.Task] = []
        self.wake = asyncio.Event()

    def snapshot(self) -> dict:
        return {"id": self.id, "name": self.row["name"], "host": self.row["host"], "port": self.row["port"],
                "online": self.online, "error": self.error, "checked": self.checked, "down_since": self.down_since,
                "status": self.status, "proxies": self.proxies, "names": self.names,
                "draft": self.draft, "alert": self.alert, "usage": self.usage}


class Hub:
    def __init__(self, db: DB, key: Path, src: Path):
        self.db, self.key, self.src = db, key, src
        self.routers: dict[int, RouterRuntime] = {}
        self.subscribers: set[asyncio.Queue] = set()
        self.tasks: list[asyncio.Task] = []
        self.probes: dict[int, asyncio.Task] = {}

    # --- lifecycle ------------------------------------------------------------------
    async def start(self) -> None:
        for row in self.db.routers():
            self._start_router(row)
        self.tasks.append(asyncio.create_task(self._scheduler()))
        self.tasks.append(asyncio.create_task(self._pruner()))

    async def stop(self) -> None:
        for rt in list(self.routers.values()):
            await self._stop_router(rt.id)
        for t in self.tasks:
            t.cancel()

    def _start_router(self, row: dict) -> RouterRuntime:
        rt = RouterRuntime(row, self.key)
        self.routers[rt.id] = rt
        ev = self.db.one(f"SELECT type, t FROM events WHERE router_id = ? AND type IN "
                         f"({', '.join('?' * len(ALERT_EVENTS))}) ORDER BY id DESC LIMIT 1", rt.id, *ALERT_EVENTS)
        rt.alert = ev
        self.update_draft(rt)
        self.db.sync_sub_keys(rt.id, self.db.probe_settings(rt.id)["keys"])
        rt.tasks = [asyncio.create_task(self._poll_loop(rt)), asyncio.create_task(self._watch_loop(rt)),
                    asyncio.create_task(self._usage_loop(rt))]
        return rt

    async def _stop_router(self, rid: int) -> None:
        rt = self.routers.pop(rid, None)
        if rt:
            for t in rt.tasks:
                t.cancel()
            rt.agent.close()

    def add_router(self, row: dict) -> None:
        self._start_router(row)

    async def remove_router(self, rid: int) -> None:
        await self._stop_router(rid)
        self.db.delete_router(rid)

    def get(self, rid: int) -> RouterRuntime:
        rt = self.routers.get(rid)
        if rt is None:
            raise KeyError(rid)
        return rt

    # --- live updates -----------------------------------------------------------------
    def subscribe(self) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=500)
        self.subscribers.add(q)
        return q

    def unsubscribe(self, q: asyncio.Queue) -> None:
        self.subscribers.discard(q)

    def publish(self, msg: dict) -> None:
        for q in list(self.subscribers):
            with contextlib.suppress(asyncio.QueueFull):
                q.put_nowait(msg)

    # --- polling and the event stream ------------------------------------------------
    async def refresh(self, rt: RouterRuntime) -> None:
        try:
            rt.status = await rt.agent.call("status", timeout=30)
            if rt.status.get("fingerprint") != rt.names_fp:
                self._got_config(rt, await rt.agent.call("config-get", timeout=30))
            rt.proxies = None
            if rt.status["podkop"]["running"]:
                with contextlib.suppress(AgentError):
                    rt.proxies = await rt.agent.call("proxies", timeout=30)
            rt.online, rt.error, rt.down_since = True, "", None
        except AgentError as e:
            rt.online, rt.error = False, e.message
            rt.down_since = rt.down_since or time.time()
        rt.checked = time.time()
        self.publish({"type": "router", "router": rt.snapshot()})

    async def _poll_loop(self, rt: RouterRuntime) -> None:
        while True:
            await self.refresh(rt)
            rt.wake.clear()
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(rt.wake.wait(), timeout=POLL_SECONDS)

    async def _watch_loop(self, rt: RouterRuntime) -> None:
        delay = 5
        while True:
            try:
                since = self.db.router(rt.id)["last_event"] or ""
                async for m in rt.agent.watch(since):
                    delay = 5
                    self._on_message(rt, m)
            except AgentError as e:
                log.info("watch %s: %s", rt.row["host"], e.message)
            except Exception:  # noqa: BLE001 - keep the stream alive whatever happens
                log.exception("watch %s", rt.row["host"])
            await asyncio.sleep(delay)
            delay = min(delay * 2, 60)

    def _on_message(self, rt: RouterRuntime, m: dict) -> None:
        typ = m.get("type")
        if typ == "hello":
            return
        if typ == "log":
            line = str(m.get("line", ""))
            p = podkop.parse_log(line)
            self.db.add_log(rt.id, line, p["source"], p["level"])
            self.publish({"type": "log", "router_id": rt.id, "line": line, "t": time.time(), **p})
            return
        data = {k: v for k, v in m.items() if k not in ("id", "t", "type")}
        self.db.add_event(rt.id, typ, dict(data, agent_time=m.get("t")))
        if typ in ALERT_EVENTS:
            rt.alert = {"type": typ, "t": time.time()}
        if m.get("id"):
            self.db.update_router(rt.id, last_event=m["id"])
        self.publish({"type": "event", "router_id": rt.id, "event": typ, "data": data, "t": m.get("t")})
        rt.wake.set()

    # --- config ------------------------------------------------------------------------
    def _got_config(self, rt: RouterRuntime, cfg: dict) -> None:
        rt.config = cfg
        rt.names, rt.names_fp = podkop.tag_names(cfg["config"]), cfg["fingerprint"]
        self.update_draft(rt)

    async def config(self, rid: int) -> dict:
        rt = self.get(rid)
        cfg = await rt.agent.call("config-get", timeout=30)
        self._got_config(rt, cfg)
        return cfg

    # --- the draft: changes made in the web interface, not applied yet ---------------
    def update_draft(self, rt: RouterRuntime) -> None:
        """Recount the draft's changes against the router's settings; a draft
        without changes is dropped."""
        d = self.db.draft(rt.id)
        if not d or not rt.config:
            rt.draft = {"changes": None, "base": d["base"], "updated": d["updated"], "stale": None} if d else None
            return
        n = len(podkop.diff(rt.config["config"], d["config"]))
        if n == 0:
            self.db.delete_draft(rt.id)
            rt.draft = None
            return
        rt.draft = {"changes": n, "base": d["base"], "updated": d["updated"],
                    "stale": d["base"] != rt.config["fingerprint"]}

    async def diff(self, rid: int, config: dict) -> dict:
        cur = await self.config(rid)
        return {"fingerprint": cur["fingerprint"], "diff": podkop.diff(cur["config"], config)}

    async def validate(self, rid: int, config: dict) -> list:
        return (await self.get(rid).agent.call("validate", payload={"config": config}, timeout=90))["problems"]

    async def apply(self, rid: int, base: str, config: dict, note: str = "", trigger: str = "web") -> dict:
        rt = self.get(rid)
        cur = await self.config(rid)
        d = podkop.diff(cur["config"], config)
        vid = self.db.add_version(rid, config, d, note, base, trigger)
        try:
            job = (await rt.agent.call("apply", payload={"base": base, "config": config}, timeout=30))["job"]
        except AgentError as e:
            self.db.update_version(vid, state="failed", message=e.message)
            raise
        self.db.update_version(vid, job=job, state="running")
        asyncio.create_task(self._track_job(rt, vid, job))
        return {"version": vid, "job": job}

    async def _track_job(self, rt: RouterRuntime, vid: int, job: str) -> dict | None:
        deadline = time.time() + 600
        data = None
        while time.time() < deadline:
            try:
                # short waits, so the browser sees checking -> restarting -> done
                data = await rt.agent.call("job", job, "2", timeout=30)
            except AgentError as e:
                log.info("job %s on %s: %s", job, rt.row["host"], e.message)
                await asyncio.sleep(5)
                continue
            self.publish({"type": "job", "router_id": rt.id, "version": vid, "job": data})
            if data.get("state") in FINAL_JOB_STATES:
                break
        state = (data or {}).get("state", "unknown")
        if state not in FINAL_JOB_STATES:
            state = "unknown"
        self.db.update_version(vid, state=state, message=(data or {}).get("message", "no answer from the router"),
                               details=data)
        if state in OK_JOB_STATES:
            # the draft that was applied is done with
            draft, version = self.db.draft(rt.id), self.db.version(vid)
            if draft and version and not podkop.diff(draft["config"], version["config"]):
                self.db.delete_draft(rt.id)
                rt.draft = None
        rt.wake.set()
        return data

    async def wait_version(self, vid: int, timeout: float = 600) -> dict:
        end = time.time() + timeout
        while time.time() < end:
            v = self.db.version(vid)
            if v and v["state"] not in ("pending", "running"):
                return v
            await asyncio.sleep(2)
        return self.db.version(vid)

    # --- probe ----------------------------------------------------------------------------
    async def start_probe(self, rid: int, trigger: str = "manual") -> int:
        rt = self.get(rid)
        ps = self.db.probe_settings(rid)
        if not ps.get("keys"):
            raise AgentError("no_keys", "add your keys (subscription URLs) first")
        if rid in self.probes and not self.probes[rid].done():
            raise AgentError("busy", "a probe is already running")
        await rt.agent.call("probe-start", payload={"keys": ps["keys"], "options": ps["options"]}, timeout=30)
        run_id = self.db.add_probe_run(rid, trigger, ps["keys"])
        self.probes[rid] = asyncio.create_task(self._track_probe(rt, run_id, trigger))
        self.publish({"type": "probe", "router_id": rid, "state": "running", "run": run_id})
        return run_id

    async def _track_probe(self, rt: RouterRuntime, run_id: int, trigger: str) -> None:
        st: dict = {}
        end = time.time() + 3 * 3600
        while time.time() < end:
            await asyncio.sleep(15)
            try:
                st = await rt.agent.call("probe-status", timeout=30)
            except AgentError:
                continue
            self.publish({"type": "probe", "router_id": rt.id, "state": st.get("state"), "run": run_id})
            if st.get("state") != "running":
                break
        state = st.get("state", "unknown")
        vid = None
        ps = self.db.probe_settings(rt.id)
        if state == "done":
            for section, pick in self.auto_picks(rt.id, st).items():
                if not pick["links"]:
                    self._event(rt, "auto_rule_empty", {"section": section})
        if state == "done" and trigger == "schedule" and ps.get("auto_apply"):
            try:
                vid = await self.apply_probe(rt.id, st, note="nightly probe")
            except (AgentError, ValueError) as e:
                self._event(rt, "probe_apply_failed", {"message": str(e)})
        self.db.finish_probe_run(run_id, state, st, vid)
        self.publish({"type": "probe", "router_id": rt.id, "state": state, "run": run_id})

    def _event(self, rt: RouterRuntime, etype: str, data: dict) -> None:
        """An event of the manager itself, stored and sent like the router's."""
        self.db.add_event(rt.id, etype, data)
        self.publish({"type": "event", "router_id": rt.id, "event": etype, "data": data, "t": time.time()})

    def auto_picks(self, rid: int, status: dict) -> dict:
        """The servers of the last probe for each rule by country."""
        max_ping, min_speed = podkop.probe_limits(self.db.probe_settings(rid).get("options") or [])
        return {r["section"]: podkop.auto_pick(status.get("rows") or [], r, max_ping, min_speed)
                for r in self.db.auto_rules(rid)}

    def _avoided_links(self, rid: int) -> set:
        """Links of the keys that passed their traffic threshold and are set to
        move rules to other keys."""
        now = time.time()
        return {usage.norm(link) for k in self.db.keys(rid) if k["action"] == "avoid" and (k["acted_until"] or 0) > now
                for link in (k["links"] if k["kind"] == "sub" else [k["url"]])}

    def probe_config(self, rid: int, cur: dict, status: dict) -> dict:
        """The router's config with the probe's lists and the rules by country
        filled in, without the servers of keys moved away from; ValueError
        when nothing would change."""
        if avoided := self._avoided_links(rid):
            keep = [r for r in status.get("rows") or [] if usage.norm(r.get("link") or "") not in avoided]
            lists = {n: [x for x in v if usage.norm(x) not in avoided] for n, v in (status.get("lists") or {}).items()}
            for n in ("main", "youtube"):
                if not lists.get(n) and lists.get(f"{n}_fallback"):
                    lists[n], lists[f"{n}_fallback"] = lists[f"{n}_fallback"], []
            status = dict(status, rows=keep, lists=lists)
        ps, lists = self.db.probe_settings(rid), status.get("lists") or {}
        picks = self.auto_picks(rid, status)
        if not lists.get("main") and not lists.get("youtube") and not any(p["links"] for p in picks.values()):
            raise ValueError("the probe found no server to use")
        return podkop.merge_probe(cur["config"], lists, ps.get("main_section") or "main",
                                  ps.get("youtube_section") or None, picks)

    async def apply_probe(self, rid: int, status: dict, note: str) -> int:
        cur = await self.config(rid)
        new = self.probe_config(rid, cur, status)
        return (await self.apply(rid, cur["fingerprint"], new, note, "probe"))["version"]

    # --- keys and usage --------------------------------------------------------------------
    async def _usage_loop(self, rt: RouterRuntime) -> None:
        last = 0.0
        while True:
            await asyncio.sleep(TRAFFIC_SECONDS)
            if not rt.online:
                continue
            try:
                await self.read_traffic(rt)
                if time.time() - last >= USAGE_SECONDS:
                    last = time.time()
                    await self.read_usage(rt)
            except AgentError as e:
                log.info("usage %s: %s", rt.row["host"], e.message)
            await self.check_usage(rt)

    async def read_usage(self, rt: RouterRuntime) -> None:
        """Each subscription's usage header and server list, fetched on the router."""
        keys = {k["url"]: k for k in self.db.keys(rt.id) if k["kind"] == "sub"}
        if not keys:
            return
        now = time.time()
        for r in await rt.agent.call("sub-info", payload={"keys": list(keys)}, timeout=300) or []:
            k = keys.get(r.get("url"))
            if not k:
                continue
            fields = {"title": usage.parse_title(r.get("title") or ""), "why": r.get("why") or ""}
            if r.get("links"):
                fields["links"] = r["links"]
            self.db.update_key(k["id"], **fields)
            if info := usage.parse_userinfo(r.get("usage") or ""):
                self.db.add_key_usage(k["id"], now, info["used"], info["total"], info["expire"])

    async def read_traffic(self, rt: RouterRuntime) -> None:
        """The bytes per server since the last read, stored by hour, key and rule."""
        cur = await rt.agent.call("traffic", timeout=30)
        last = self.db.get_setting(f"traffic:{rt.id}")
        self.db.set_setting(f"traffic:{rt.id}", cur)
        if not last or not rt.config:
            return
        base = last.get("servers") or {} if last.get("since") == cur.get("since") else {}
        tags = podkop.tag_links(rt.config["config"])
        index = usage.link_index(self.db.keys(rt.id))
        hour = int(time.time() // 3600 * 3600)
        for tag, total in (cur.get("servers") or {}).items():
            n = total - base.get(tag, 0)
            if n < 0:
                n = total
            if n > 0 and tag in tags:
                rule, link = tags[tag]
                self.db.add_traffic(rt.id, hour, index.get(usage.norm(link), 0), rule, link, n)

    def usage(self, rid: int) -> dict:
        now = time.time()
        since = now - 15 * usage.DAY
        traffic = self.db.traffic(rid, since)
        keys = [usage.key_usage(k, self.db.key_usage(k["id"], since), [r for r in traffic if r["key_id"] == k["id"]], now)
                for k in self.db.keys(rid)]
        return {"now": now, "keys": keys,
                "servers": usage.servers_today(traffic, {k["id"]: k["label"] for k in keys}, now)}

    async def check_usage(self, rt: RouterRuntime) -> None:
        """Act on keys past their threshold once per day, move rules away from
        or back to keys, and refresh the summary for the menu and Overview."""
        u = self.usage(rt.id)
        now = u["now"]
        for k in u["keys"]:
            if usage.over_threshold(k) and not (k["acted_until"] or 0) > now:
                self.db.update_key(k["id"], acted_until=k["next_reset"])
                self._event(rt, "usage_threshold", {"key": k["label"], "pct": k["pct"], "action": k["action"]})
        avoid = sorted(k["id"] for k in self.db.keys(rt.id) if k["action"] == "avoid" and (k["acted_until"] or 0) > now)
        if avoid != (self.db.get_setting(f"avoid:{rt.id}") or []):
            self.db.set_setting(f"avoid:{rt.id}", avoid)
            await self._move_rules(rt, [k["label"] for k in u["keys"] if k["id"] in avoid])
        daily = [k for k in u["keys"] if k["daily"] and k["limit"]]
        rt.usage = {"pct": max((k["pct"] for k in daily), default=None),
                    "alerts": [{k_: k[k_] for k_ in ("id", "label", "used", "limit", "pct", "threshold", "action", "forecast")}
                               for k in daily if usage.over_threshold(k) or (k["forecast"] or {}).get("hits_today")]}
        self.publish({"type": "usage", "router_id": rt.id})
        self.publish({"type": "router", "router": rt.snapshot()})

    async def _move_rules(self, rt: RouterRuntime, labels: list) -> None:
        """Rebuild the probe's rules from its last run without the servers of
        the keys moved away from (or with them again, after the reset). Only
        rules that held those servers (or were changed last time) are touched."""
        status = self.db.last_probe_result(rt.id)
        if not status:
            self._event(rt, "usage_move_failed", {"message": "no probe run to take other servers from"})
            return
        try:
            cur = await self.config(rt.id)
            new = self.probe_config(rt.id, cur, status)
            avoided = self._avoided_links(rt.id)
            touched = set(self.db.get_setting(f"moved:{rt.id}") or []) | {
                sec for sec, link in podkop.tag_links(cur["config"]).values() if usage.norm(link) in avoided}
            old = podkop.sections_by_name(cur["config"])
            secs = [sec if sec["name"] in touched else old[sec["name"]]
                    for sec in new["sections"] if sec["name"] in old or sec["name"] in touched]
            if all(sec["name"] in old for sec in secs):     # nothing added: keep the rules' order
                order = [sec["name"] for sec in cur["config"]["sections"]]
                secs.sort(key=lambda sec: order.index(sec["name"]))
            new = dict(new, sections=secs)
            self.db.set_setting(f"moved:{rt.id}", sorted(touched) if avoided else [])
            if not podkop.diff(cur["config"], new):
                return
            note = f"traffic limit of {', '.join(labels)}: rules moved to other keys" if labels else "traffic limit reset"
            await self.apply(rt.id, cur["fingerprint"], new, note, "usage")
        except (AgentError, ValueError) as e:
            self._event(rt, "usage_move_failed", {"message": str(e)})

    async def _scheduler(self) -> None:
        while True:
            await asyncio.sleep(30)
            now = dt.datetime.now()
            for rid in list(self.routers):
                ps = self.db.probe_settings(rid)
                sched = (ps.get("schedule") or "").strip()
                if not sched or ps.get("last_run_day") == now.strftime("%Y-%m-%d"):
                    continue
                try:
                    hh, mm = (int(x) for x in sched.split(":"))
                except ValueError:
                    continue
                # within an hour after the set time, so a manager started at
                # noon doesn't run the nightly probe right away
                due = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
                if 0 <= (now - due).total_seconds() < 3600:
                    self.db.set_probe_settings(rid, last_run_day=now.strftime("%Y-%m-%d"))
                    try:
                        await self.start_probe(rid, "schedule")
                    except AgentError as e:
                        self.db.add_event(rid, "probe_not_started", {"message": e.message})

    async def _pruner(self) -> None:
        while True:
            self.db.prune()
            await asyncio.sleep(3600)
