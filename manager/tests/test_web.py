import asyncio

from fastapi.testclient import TestClient

from podkop_manager.agent import AgentError
from podkop_manager.db import DB
from podkop_manager.hub import Hub
from podkop_manager.web import create_app, hash_password, check_password


class FakeAgent:
    async def call(self, *args, **kw):
        raise AgentError("unreachable", "no router in tests")


class FakeRouter:
    id = 1
    draft = None
    agent = FakeAgent()

    def snapshot(self):
        return {"id": self.id, "draft": self.draft}


class FakeHub:
    src = None
    auto_picks = Hub.auto_picks

    def __init__(self, db=None):
        self.db = db
        self.routers = {1: FakeRouter()} if db else {}
        self.published = []

    def publish(self, msg):
        self.published.append(msg)

    def update_draft(self, rt):
        d = self.db.draft(rt.id)
        rt.draft = {"changes": 1, "base": d["base"]} if d else None

    async def start(self):
        pass

    async def stop(self):
        pass

    def subscribe(self):
        return asyncio.Queue()

    def unsubscribe(self, q):
        pass

    def get(self, rid):
        return self.routers[rid]


def client(tmp_path, with_router=False):
    db = DB(tmp_path / "m.db")
    db.set_setting("password_hash", hash_password("secret-pass"))
    if with_router:
        db.add_router("home", "192.168.1.1", 22, "ssh-ed25519 AAAA host")
    c = TestClient(create_app(db, FakeHub(db if with_router else None), "ssh-ed25519 AAAA test"))
    c.db = db
    return c


H = {"X-Podkop-Manager": "1"}


def test_password_hash():
    h = hash_password("x" * 10)
    assert check_password("x" * 10, h) and not check_password("y" * 10, h)


def test_login_required(tmp_path):
    with client(tmp_path) as c:
        assert c.get("/api/schema").status_code == 401
        assert c.get("/", follow_redirects=False).headers["location"] == "/login"
        r = c.post("/login", data={"password": "wrong"}, follow_redirects=False)
        assert r.headers["location"] == "/login?bad=1"


def test_login_and_header_check(tmp_path):
    with client(tmp_path) as c:
        c.post("/login", data={"password": "secret-pass"})
        assert c.get("/api/schema").json()["podkop"] == "0.7.24"
        assert c.get("/api/manager").json()["public_key"].startswith("ssh-ed25519")
        assert c.get("/api/routers").json() == []
        # a write without the manager's own header (e.g. from another site) is refused
        assert c.post("/api/routers", json={"host": "x"}).status_code == 403
        assert c.get("/api/routers/5/config").status_code == 404


def test_draft_api(tmp_path):
    with client(tmp_path, with_router=True) as c:
        c.post("/login", data={"password": "secret-pass"})
        assert c.get("/api/routers/1/draft").json() is None
        cfg = {"sections": [{"name": "settings", "type": "settings", "options": {}}]}
        assert c.put("/api/routers/1/draft", json={"config": {"x": 1}}, headers=H).status_code == 400
        assert c.put("/api/routers/1/draft", json={"config": cfg, "base": "fp1"}, headers=H).json()["base"] == "fp1"
        d = c.get("/api/routers/1/draft").json()
        assert d["config"] == cfg and d["changes"] == 1
        assert c.delete("/api/routers/1/draft", headers=H).json() == {"ok": True}
        assert c.get("/api/routers/1/draft").json() is None


def test_logs_filters_and_parsed_fields(tmp_path):
    with client(tmp_path, with_router=True) as c:
        c.post("/login", data={"password": "secret-pass"})
        c.db.add_log(1, "Sat Oct 17 23:18:40 2026 user.notice podkop: [info] Stopping", "podkop", "info")
        c.db.add_log(1, "Sat Oct 17 23:18:48 2026 daemon.err sing-box[1]: WARN[0000] slow", "sing-box", "warn")
        c.db.add_log(1, "Sat Oct 17 23:18:49 2026 daemon.err sing-box[1]: ERROR[0000] dead", "sing-box", "error")
        assert len(c.get("/api/routers/1/logs").json()) == 3
        rows = c.get("/api/routers/1/logs?source=sing-box&level=warn,error").json()
        assert [r["msg"] for r in rows] == ["slow", "dead"] and rows[0]["time"] == "23:18:48"
        assert [r["msg"] for r in c.get("/api/routers/1/logs?source=podkop,agent").json()] == ["Stopping"]


def test_versions_trigger_reason_and_paging(tmp_path):
    with client(tmp_path, with_router=True) as c:
        c.post("/login", data={"password": "secret-pass"})
        db = c.db
        v1 = db.add_version(1, {"sections": []}, [], "first", "fp0")
        db.update_version(v1, state="applied", details={"state": "applied", "fingerprint_after": "fp1",
                                                        "started": "2026-10-17T21:03:05Z",
                                                        "finished": "2026-10-17T21:03:21Z"})
        v2 = db.add_version(1, {"sections": []}, [], "second", "fp1", "restore")
        db.update_version(v2, state="reverted", details={"reason": "podkop did not start"})
        vs = c.get("/api/routers/1/versions").json()
        assert [v["id"] for v in vs] == [v2, v1]
        assert vs[0]["trigger"] == "restore" and vs[0]["reason"] == "podkop did not start"
        assert vs[1]["trigger"] == "web" and vs[1]["fingerprint_after"] == "fp1" and vs[1]["seconds"] == 16
        assert [v["id"] for v in c.get(f"/api/routers/1/versions?before={v2}").json()] == [v1]


def test_change_password(tmp_path):
    with client(tmp_path) as c:
        c.post("/login", data={"password": "secret-pass"})
        assert c.post("/api/password", json={"password": "short"}, headers=H).status_code == 400
        assert c.post("/api/password", json={"password": "new-password-1"}, headers=H).json() == {"ok": True}
        c.post("/logout", headers=H)
        r = c.post("/login", data={"password": "new-password-1"}, follow_redirects=False)
        assert r.headers["location"] == "/"


def test_old_database_gets_new_columns(tmp_path):
    import sqlite3
    path = tmp_path / "old.db"
    con = sqlite3.connect(path)
    con.executescript("CREATE TABLE logs (id INTEGER PRIMARY KEY, router_id INTEGER NOT NULL, t REAL NOT NULL,"
                      " line TEXT NOT NULL);"
                      "INSERT INTO logs (router_id, t, line) VALUES"
                      " (1, 1, 'Sat Oct 17 23:18:48 2026 daemon.err sing-box[1]: ERROR[0000] dead');"
                      "CREATE TABLE versions (id INTEGER PRIMARY KEY, router_id INTEGER NOT NULL, t REAL NOT NULL,"
                      " job TEXT, state TEXT NOT NULL, message TEXT, note TEXT, fingerprint_before TEXT,"
                      " config TEXT NOT NULL, diff TEXT NOT NULL, details TEXT);")
    con.close()
    db = DB(path)
    db.add_log(1, "x", "podkop", "warn")
    assert db.logs(1, levels=["warn"])[0]["source"] == "podkop"
    assert db.logs(1, sources=["sing-box"], levels=["error"])[0]["line"].endswith("dead")    # old line, filled in
    assert db.versions(1) == []


def test_auto_rules_api_and_preview_from_last_run(tmp_path):
    from test_podkop import ROWS
    with client(tmp_path, with_router=True) as c:
        c.post("/login", data={"password": "secret-pass"})
        assert c.put("/api/routers/1/auto-rules/main", json={"countries": ["PL"]}, headers=H).status_code == 400
        assert c.put("/api/routers/1/auto-rules/netflix", json={"countries": ["Poland"]}, headers=H).status_code == 400
        r = c.put("/api/routers/1/auto-rules/netflix", json={"countries": ["pl"], "protocols": ["vless"], "top": 2,
                                                             "fallback": 1}, headers=H).json()
        assert r["countries"] == ["PL"] and r["top"] == 2
        assert [x["section"] for x in c.get("/api/routers/1/auto-rules").json()] == ["netflix"]
        run = c.db.add_probe_run(1, "manual")
        c.db.finish_probe_run(run, "done", {"finished": "2026-10-17T21:00:00Z", "rows": ROWS})
        p = c.get("/api/routers/1/auto-rules/netflix/preview").json()
        assert [m["name"] for m in p["matched"]] == ["PL Fast", "PL Warsaw 5"]
        assert [m["name"] for m in p["fallback"]] == ["PL Krakow 1"] and p["has_links"]
        assert c.delete("/api/routers/1/auto-rules/netflix", headers=H).json() == {"ok": True}
        assert c.get("/api/routers/1/auto-rules/netflix").status_code == 404
