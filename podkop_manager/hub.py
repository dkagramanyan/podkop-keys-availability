"""The manager's core: one runtime per router (status polling, the agent's
live event stream, apply jobs, probe runs), the nightly probe schedule, and
fan-out of live updates to the browsers."""

from __future__ import annotations

import asyncio
import contextlib
import datetime as dt
import logging
import time
from pathlib import Path

from . import podkop
from .agent import Agent, AgentError
from .db import DB

log = logging.getLogger("podkop_manager")

FINAL_JOB_STATES = {"applied", "saved", "unchanged", "rejected", "reverted", "failed"}
OK_JOB_STATES = {"applied", "saved", "unchanged"}
# events shown next to the router's name until something newer happens
ALERT_EVENTS = ("reverted", "revert_failed")
POLL_SECONDS = 30


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
                "draft": self.draft, "alert": self.alert}


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
        rt.tasks = [asyncio.create_task(self._poll_loop(rt)), asyncio.create_task(self._watch_loop(rt))]
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
        run_id = self.db.add_probe_run(rid, trigger)
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

    def probe_config(self, rid: int, cur: dict, status: dict) -> dict:
        """The router's config with the probe's lists and the rules by country
        filled in; ValueError when nothing would change."""
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
