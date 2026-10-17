"""The web interface: login, a JSON API for the browser, and a live stream
(server-sent events). The pages themselves are static/app.js."""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import hmac
import json
import secrets
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.sessions import SessionMiddleware

from . import __version__, podkop
from .agent import AgentError, install
from .db import DB
from .hub import Hub

STATIC = Path(__file__).parent / "static"


def hash_password(password: str, salt: str | None = None) -> str:
    salt = salt or secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), 300_000).hex()
    return f"pbkdf2_sha256${salt}${h}"


def check_password(password: str, stored: str) -> bool:
    try:
        _, salt, _h = stored.split("$")
    except ValueError:
        return False
    return hmac.compare_digest(hash_password(password, salt), stored)


def create_app(db: DB, hub: Hub, public_key: str) -> FastAPI:
    @contextlib.asynccontextmanager
    async def lifespan(_: FastAPI):
        await hub.start()
        yield
        await hub.stop()

    app = FastAPI(title="podkop-manager", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    secret = db.get_setting("session_secret")
    if not secret:
        secret = secrets.token_hex(32)
        db.set_setting("session_secret", secret)
    app.add_middleware(SessionMiddleware, secret_key=secret, session_cookie="podkop_manager",
                       max_age=14 * 86400, same_site="strict", https_only=False)

    @app.exception_handler(AgentError)
    async def _agent_error(_: Request, e: AgentError):
        return JSONResponse({"error": e.as_dict()}, status_code=502 if e.code in ("unreachable", "timeout") else 400)

    def user(request: Request) -> None:
        if not request.session.get("auth"):
            raise HTTPException(401, "log in first")
        # a page from another site can't add this header to its requests
        if request.method not in ("GET", "HEAD") and request.headers.get("x-podkop-manager") != "1":
            raise HTTPException(403, "missing request header")

    def router_or_404(rid: int):
        try:
            return hub.get(rid)
        except KeyError:
            raise HTTPException(404, "no such router") from None

    # --- pages ----------------------------------------------------------------------
    app.mount("/static", StaticFiles(directory=STATIC), name="static")

    @app.get("/")
    async def index(request: Request):
        if not request.session.get("auth"):
            return RedirectResponse("/login", status_code=303)
        return FileResponse(STATIC / "app.html")

    @app.get("/login")
    async def login_page():
        return FileResponse(STATIC / "login.html")

    @app.post("/login")
    async def login(request: Request):
        form = await request.form()
        stored = db.get_setting("password_hash")
        if stored and check_password(str(form.get("password", "")), stored):
            request.session["auth"] = True
            return RedirectResponse("/", status_code=303)
        await asyncio.sleep(1)
        return RedirectResponse("/login?bad=1", status_code=303)

    @app.post("/logout")
    async def logout(request: Request):
        request.session.clear()
        return RedirectResponse("/login", status_code=303)

    # --- API ------------------------------------------------------------------------
    api = Depends(user)

    @app.get("/api/manager", dependencies=[api])
    async def manager_info():
        return {"version": __version__, "public_key": public_key}

    @app.get("/api/schema", dependencies=[api])
    async def schema():
        return podkop.SCHEMA

    @app.get("/api/routers", dependencies=[api])
    async def routers():
        return [rt.snapshot() for rt in hub.routers.values()]

    @app.post("/api/routers", dependencies=[api])
    async def add_router(body: dict):
        host = str(body.get("host", "")).strip()
        if not host:
            raise HTTPException(400, "host is required")
        port = int(body.get("port") or 22)
        allow = [x.strip() for x in str(body.get("allow_clash", "")).replace(",", " ").split() if x.strip()]
        host_key = await install(host, port, str(body.get("password", "")), public_key, hub.src, allow)
        rid = db.add_router(str(body.get("name") or host), host, port, host_key)
        hub.add_router(db.router(rid))
        return {"id": rid}

    @app.post("/api/routers/{rid}/reinstall", dependencies=[api])
    async def reinstall(rid: int, body: dict):
        rt = router_or_404(rid)
        allow = [x.strip() for x in str(body.get("allow_clash", "")).replace(",", " ").split() if x.strip()]
        host_key = await install(rt.row["host"], rt.row["port"], str(body.get("password", "")), public_key,
                                 hub.src, allow)
        if host_key != rt.row["host_key"]:
            raise HTTPException(400, "the router's host key changed; remove and add the router again")
        await hub.refresh(rt)
        return {"ok": True}

    @app.patch("/api/routers/{rid}", dependencies=[api])
    async def rename_router(rid: int, body: dict):
        rt = router_or_404(rid)
        name = str(body.get("name", "")).strip()
        if name:
            db.update_router(rid, name=name)
            rt.row["name"] = name
        return rt.snapshot()

    @app.delete("/api/routers/{rid}", dependencies=[api])
    async def delete_router(rid: int, uninstall: bool = False):
        rt = router_or_404(rid)
        note = ""
        if uninstall:
            try:
                await rt.agent.call("uninstall", timeout=20)
            except AgentError as e:
                note = f"podkop-agent was not removed from the router: {e.message}"
        await hub.remove_router(rid)
        return {"ok": True, "note": note}

    @app.post("/api/routers/{rid}/refresh", dependencies=[api])
    async def refresh(rid: int):
        rt = router_or_404(rid)
        await hub.refresh(rt)
        return rt.snapshot()

    @app.get("/api/routers/{rid}/config", dependencies=[api])
    async def get_config(rid: int):
        router_or_404(rid)
        return await hub.config(rid)

    @app.post("/api/routers/{rid}/diff", dependencies=[api])
    async def diff(rid: int, body: dict):
        router_or_404(rid)
        return await hub.diff(rid, body["config"])

    @app.post("/api/routers/{rid}/validate", dependencies=[api])
    async def validate(rid: int, body: dict):
        router_or_404(rid)
        return {"problems": await hub.validate(rid, body["config"])}

    @app.post("/api/routers/{rid}/apply", dependencies=[api])
    async def apply(rid: int, body: dict):
        router_or_404(rid)
        return await hub.apply(rid, str(body.get("base", "")), body["config"], str(body.get("note", "")))

    @app.get("/api/routers/{rid}/versions", dependencies=[api])
    async def versions(rid: int):
        router_or_404(rid)
        return db.versions(rid)

    @app.get("/api/versions/{vid}", dependencies=[api])
    async def version(vid: int):
        v = db.version(vid)
        if not v:
            raise HTTPException(404, "no such version")
        return v

    @app.post("/api/routers/{rid}/pin", dependencies=[api])
    async def pin(rid: int, body: dict):
        rt = router_or_404(rid)
        r = await rt.agent.call("pin", str(body["section"]), str(body["server"]))
        rt.wake.set()
        return r

    @app.post("/api/routers/{rid}/delays", dependencies=[api])
    async def delays(rid: int, body: dict):
        rt = router_or_404(rid)
        return await rt.agent.call("delays", str(body["section"]), timeout=40)

    @app.post("/api/routers/{rid}/service", dependencies=[api])
    async def service(rid: int, body: dict):
        rt = router_or_404(rid)
        r = await rt.agent.call("service", str(body["action"]), timeout=90)
        rt.wake.set()
        return r

    @app.get("/api/routers/{rid}/events", dependencies=[api])
    async def events(rid: int, limit: int = 100):
        router_or_404(rid)
        return db.events(rid, limit)

    @app.get("/api/routers/{rid}/logs", dependencies=[api])
    async def logs(rid: int, q: str = "", limit: int = 500):
        router_or_404(rid)
        return db.logs(rid, q, min(limit, 5000))

    @app.get("/api/routers/{rid}/logs/recent", dependencies=[api])
    async def recent_logs(rid: int, lines: int = 300):
        rt = router_or_404(rid)
        return await rt.agent.call("logs", str(min(lines, 2000)))

    # --- probe ------------------------------------------------------------------------
    @app.get("/api/routers/{rid}/probe", dependencies=[api])
    async def probe(rid: int):
        rt = router_or_404(rid)
        st = None
        with contextlib.suppress(AgentError):
            st = await rt.agent.call("probe-status", timeout=30)
        return {"settings": db.probe_settings(rid), "status": st, "runs": db.probe_runs(rid)}

    @app.put("/api/routers/{rid}/probe", dependencies=[api])
    async def probe_settings(rid: int, body: dict):
        router_or_404(rid)
        fields = {}
        if "keys" in body:
            fields["keys"] = [k.strip() for k in body["keys"] if str(k).strip().startswith(("http://", "https://"))]
        if "options" in body:
            fields["options"] = [str(o) for o in body["options"]]
        if "schedule" in body:
            s = str(body["schedule"]).strip()
            if s and not _hhmm(s):
                raise HTTPException(400, "time must be HH:MM")
            fields["schedule"] = s
        if "auto_apply" in body:
            fields["auto_apply"] = 1 if body["auto_apply"] else 0
        for k in ("main_section", "youtube_section"):
            if k in body:
                fields[k] = str(body[k]).strip()
        db.set_probe_settings(rid, **fields)
        return db.probe_settings(rid)

    @app.post("/api/routers/{rid}/probe/start", dependencies=[api])
    async def probe_start(rid: int):
        router_or_404(rid)
        return {"run": await hub.start_probe(rid, "manual")}

    @app.post("/api/routers/{rid}/probe/preview", dependencies=[api])
    async def probe_preview(rid: int):
        rt = router_or_404(rid)
        st = await rt.agent.call("probe-status", timeout=30)
        lists = st.get("lists") or {}
        if not lists.get("main") and not lists.get("youtube"):
            raise HTTPException(400, "the last probe found no server to use")
        cur = await hub.config(rid)
        try:
            new = hub.probe_config(db.probe_settings(rid), cur, lists)
        except ValueError as e:
            raise HTTPException(400, str(e)) from None
        return {"fingerprint": cur["fingerprint"], "config": new, "diff": podkop.diff(cur["config"], new)}

    # --- live stream --------------------------------------------------------------------
    @app.get("/api/stream", dependencies=[api])
    async def stream(request: Request):
        q = hub.subscribe()

        async def gen():
            try:
                yield "retry: 3000\n\n"
                while not await request.is_disconnected():
                    try:
                        msg = await asyncio.wait_for(q.get(), timeout=15)
                        yield f"data: {json.dumps(msg)}\n\n"
                    except asyncio.TimeoutError:
                        yield ": ping\n\n"
            finally:
                hub.unsubscribe(q)

        return StreamingResponse(gen(), media_type="text/event-stream", headers={"Cache-Control": "no-store"})

    return app


def _hhmm(s: str) -> bool:
    try:
        h, m = s.split(":")
        return 0 <= int(h) < 24 and 0 <= int(m) < 60 and len(m) == 2
    except ValueError:
        return False
