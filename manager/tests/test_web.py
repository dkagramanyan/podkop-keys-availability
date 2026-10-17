import asyncio

from fastapi.testclient import TestClient

from podkop_manager.db import DB
from podkop_manager.web import create_app, hash_password, check_password


class FakeHub:
    routers = {}
    src = None

    async def start(self):
        pass

    async def stop(self):
        pass

    def subscribe(self):
        return asyncio.Queue()

    def unsubscribe(self, q):
        pass

    def get(self, rid):
        raise KeyError(rid)


def client(tmp_path):
    db = DB(tmp_path / "m.db")
    db.set_setting("password_hash", hash_password("secret-pass"))
    return TestClient(create_app(db, FakeHub(), "ssh-ed25519 AAAA test"))


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
