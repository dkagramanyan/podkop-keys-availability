import time
from datetime import datetime
from pathlib import Path

import pytest

from podkop_manager import podkop, usage
from podkop_manager.db import DB
from podkop_manager.hub import Hub

GB = usage.GB


def ROW(link, median):
    return {"node": link.split("#")[1], "link": link, "verdict": "GOOD", "median": median, "mbit": "90"}


@pytest.fixture(autouse=True)
def utc(monkeypatch):
    monkeypatch.setenv("TZ", "UTC")
    time.tzset()
    yield
    monkeypatch.undo()
    time.tzset()


def ts(s: str) -> float:
    return datetime.fromisoformat(s + "+00:00").timestamp()


def key(**kw):
    k = {"id": 1, "kind": "sub", "url": "https://sub.example.com/abc", "label": "", "title": "", "why": "",
         "links": ["vless://a@h:1#A", "vless://b@h:2#B"], "limit_source": "provider", "limit_gb": 0,
         "period": "", "reset_time": "00:00", "action": "warn", "threshold": 90, "acted_until": None}
    k.update(kw)
    return k


def test_parse_headers():
    assert usage.parse_userinfo("upload=1073741824; download=2147483648; total=32212254720; expire=1795000000") == {
        "used": 3 * GB, "total": 30 * GB, "expire": 1795000000}
    assert usage.parse_userinfo("") is None
    assert usage.parse_title("base64:0J/RgNC+0LLQsNC50LTQtdGAINCQ") == "Провайдер А"
    assert usage.parse_title("plain") == "plain"


def test_last_reset():
    assert usage.last_reset(ts("2026-10-18T13:30"), "00:00") == ts("2026-10-18T00:00")
    assert usage.last_reset(ts("2026-10-18T02:00"), "03:00") == ts("2026-10-17T03:00")


def test_provider_daily_limit_and_forecast():
    now = ts("2026-10-18T12:00")
    # the provider's counter dropped at 00:10 yesterday and today: it resets daily
    samples = [{"t": ts("2026-10-17T00:00"), "used": 28 * GB, "total": 30 * GB, "expire": None},
               {"t": ts("2026-10-17T00:10"), "used": 0, "total": 30 * GB, "expire": None},
               {"t": ts("2026-10-17T23:50"), "used": 30 * GB, "total": 30 * GB, "expire": None},
               {"t": ts("2026-10-18T00:10"), "used": 0, "total": 30 * GB, "expire": None},
               {"t": ts("2026-10-18T09:00"), "used": 9 * GB, "total": 30 * GB, "expire": None},
               {"t": ts("2026-10-18T12:00"), "used": 21 * GB, "total": 30 * GB, "expire": None}]
    u = usage.key_usage(key(), samples, [], now)
    assert u["daily"] and u["limit_source"] == "provider" and u["reset"] == "00:00"
    assert u["used"] == 21 * GB and u["limit"] == 30 * GB and u["pct"] == 70.0
    # 12 GB in the last 3 hours: 9 GB left lasts until 14:15, before the reset
    assert u["forecast"]["hits_today"] and round(u["forecast"]["eta"]) == round(ts("2026-10-18T14:15"))
    assert [d["hit"] for d in u["days"]][-2:] == [True, False]
    assert not usage.over_threshold(u)


def test_single_link_counted_on_the_router():
    now = ts("2026-10-18T12:00")
    hour = int(ts("2026-10-18T10:00"))
    traffic = [{"hour": hour, "key_id": 2, "rule": "main", "server": "vless://x@h:1#X", "bytes": 5 * GB},
               {"hour": hour, "key_id": 2, "rule": "netflix", "server": "vless://x@h:1#X", "bytes": 4 * GB},
               {"hour": int(ts("2026-10-17T10:00")), "key_id": 2, "rule": "main", "server": "vless://x@h:1#X",
                "bytes": 7 * GB}]
    k = key(id=2, kind="link", url="vless://x@h:1#X", links=[], limit_source="manual", limit_gb=10)
    u = usage.key_usage(k, [], traffic, now)
    assert u["label"] == "X" and u["daily"] and u["used"] == 9 * GB and u["pct"] == 90.0
    assert usage.over_threshold(u)
    assert [r["rule"] for r in u["by_rule"]] == ["main", "netflix"]
    assert [d["bytes"] for d in u["days"]][-2:] == [7 * GB, 9 * GB]
    s = usage.servers_today(traffic, {2: "fra"}, now)
    assert [(x["name"], x["key"], x["rule"], x["bytes"]) for x in s] == [("X", "fra", "main", 5 * GB),
                                                                          ("X", "fra", "netflix", 4 * GB)]


def test_link_index():
    keys = [key(), key(id=2, kind="link", url="vless://x@h:1#X", links=[])]
    assert usage.link_index(keys) == {"vless://a@h:1": 1, "vless://b@h:2": 1, "vless://x@h:1": 2}


def test_probe_config_moves_away_from_avoided_keys(tmp_path: Path):
    db = DB(tmp_path / "m.db")
    rid = db.add_router("home", "192.168.1.1", 22, "ssh-ed25519 AAAA")
    db.set_probe_settings(rid, keys=["https://sub.example.com/abc"])
    db.sync_sub_keys(rid, ["https://sub.example.com/abc"])
    kid = db.keys(rid)[0]["id"]
    db.update_key(kid, links=["vless://a@h:1#A"], action="avoid", acted_until=time.time() + 3600)
    db.set_auto_rule(rid, "main", podkop.check_auto_rule({"top": 1, "fallback": 1}))
    hub = Hub(db, tmp_path / "key", tmp_path)
    cur = {"config": {"sections": [{"name": "main", "type": "section", "options": {"connection_type": "proxy"}}]}}
    status = {"rows": [ROW("vless://a@h:1#A", "0.2"), ROW("vless://c@h:3#C", "0.3")]}
    main = hub.probe_config(rid, cur, status)["sections"][0]["options"]
    assert main["urltest_proxy_links"] == ["vless://c@h:3#C"] and "urltest_fallback_links" not in main
    db.update_key(kid, acted_until=time.time() - 1)
    main = hub.probe_config(rid, cur, status)["sections"][0]["options"]
    assert main["urltest_proxy_links"] == ["vless://a@h:1#A"] and main["urltest_fallback_links"] == ["vless://c@h:3#C"]


def test_move_rules_touches_only_rules_with_the_keys_servers(tmp_path: Path):
    import asyncio
    db = DB(tmp_path / "m.db")
    rid = db.add_router("home", "192.168.1.1", 22, "ssh-ed25519 AAAA")
    db.set_probe_settings(rid, keys=["https://sub.example.com/abc"])
    db.sync_sub_keys(rid, ["https://sub.example.com/abc"])
    kid = db.keys(rid)[0]["id"]
    db.update_key(kid, links=["vless://a@h:1#A"], action="avoid", acted_until=time.time() + 3600)
    db.set_auto_rule(rid, "main", podkop.check_auto_rule({"top": 2, "fallback": 0}))
    db.set_auto_rule(rid, "youtube", podkop.check_auto_rule({"top": 1, "fallback": 0, "name_contains": "Y"}))
    run = db.add_probe_run(rid, "manual", [])
    db.finish_probe_run(run, "done", {"rows": [ROW("vless://a@h:1#A", "0.2"), ROW("vless://c@h:3#C", "0.3"),
                                               ROW("vless://y@h:4#Y", "0.4")]})
    sec = lambda n, links: {"name": n, "type": "section", "options": {
        "connection_type": "proxy", "proxy_config_type": "urltest", "urltest_proxy_links": links}}
    cur = {"fingerprint": "fp", "config": {"sections": [sec("youtube", ["vless://old@h:9#O"]),
                                                        sec("main", ["vless://a@h:1#A"])]}}
    hub = Hub(db, tmp_path / "key", tmp_path)
    applied = []

    async def config(_rid):
        return cur

    async def apply(_rid, base, config, note, trigger):
        applied.append((config, note, trigger))
        return {"version": 1}

    hub.config, hub.apply = config, apply
    rt = type("RT", (), {"id": rid})()
    asyncio.run(hub._move_rules(rt, ["provider-a"]))
    new, note, trigger = applied[0]
    by = {s["name"]: s["options"]["urltest_proxy_links"] for s in new["sections"]}
    assert by == {"youtube": ["vless://old@h:9#O"], "main": ["vless://c@h:3#C", "vless://y@h:4#Y"]}   # youtube had none
    assert trigger == "usage" and "provider-a" in note
    # after the reset: main gets the probe's list back, youtube still untouched
    db.update_key(kid, acted_until=time.time() - 1)
    cur["config"] = new
    asyncio.run(hub._move_rules(rt, []))
    by = {s["name"]: s["options"]["urltest_proxy_links"] for s in applied[1][0]["sections"]}
    assert by == {"youtube": ["vless://old@h:9#O"], "main": ["vless://a@h:1#A", "vless://c@h:3#C"]}


def test_old_probe_lists_become_rules_once(tmp_path: Path):
    db = DB(tmp_path / "m.db")
    rid = db.add_router("home", "192.168.1.1", 22, "ssh-ed25519 AAAA")
    db.set_probe_settings(rid, keys=["https://s"], options=["--countries", "europe", "--max-ping", "800", "--top", "7"])
    hub = Hub(db, tmp_path / "key", tmp_path)
    hub._lists_to_rules(rid)
    rules = {r["section"]: r for r in db.auto_rules(rid)}
    assert (rules["main"]["top"], rules["main"]["max_ping"], rules["main"]["youtube"]) == (7, 800, "")
    assert rules["youtube"]["youtube"] == "ru"
    assert hub.probe_options(rid) == ["--countries", "europe", "--max-ping", "800", "--min-speed", "40"]
    db.delete_auto_rule(rid, "youtube")
    hub._lists_to_rules(rid)                      # only once
    assert [r["section"] for r in db.auto_rules(rid)] == ["main"]
    assert hub.probe_options(rid)[-1] == "--no-youtube"
    fresh = db.add_router("new", "192.168.1.2", 22, "ssh-ed25519 AAAA")
    hub._lists_to_rules(fresh)                    # never used the probe: no rules
    assert db.auto_rules(fresh) == []
