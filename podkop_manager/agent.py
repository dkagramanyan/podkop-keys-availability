"""Talking to podkop-agent on a router over SSH.

One SSH connection per router; every command runs on its own channel.
The manager's key may run only podkop-agent there, so the command line is
just "podkop-agent <command> <args>" and requests go as JSON on stdin.
"""

from __future__ import annotations

import asyncio
import json
import shlex
from pathlib import Path
from typing import AsyncIterator

import asyncssh

PROTOCOL = 1


class AgentError(Exception):
    def __init__(self, code: str, message: str, details=None):
        super().__init__(message)
        self.code, self.message, self.details = code, message, details

    def as_dict(self) -> dict:
        return {"code": self.code, "message": self.message, "details": self.details}


def known_hosts_line(host: str, port: int, host_key: str) -> str:
    target = host if port == 22 else f"[{host}]:{port}"
    return f"{target} {host_key}\n"


class Agent:
    def __init__(self, host: str, port: int, host_key: str, client_key: Path):
        self.host, self.port, self.host_key, self.client_key = host, port, host_key, client_key
        self._conn: asyncssh.SSHClientConnection | None = None
        self._lock = asyncio.Lock()

    async def connection(self) -> asyncssh.SSHClientConnection:
        async with self._lock:
            if self._conn is not None and not self._conn.is_closed():
                return self._conn
            try:
                self._conn = await asyncio.wait_for(asyncssh.connect(
                    self.host, port=self.port, username="root",
                    client_keys=[str(self.client_key)], agent_path=None, password=None,
                    known_hosts=asyncssh.import_known_hosts(known_hosts_line(self.host, self.port, self.host_key)),
                    keepalive_interval=20, keepalive_count_max=3), timeout=15)
            except (OSError, asyncssh.Error, asyncio.TimeoutError) as e:
                raise AgentError("unreachable", f"cannot connect to {self.host}: {e or type(e).__name__}") from None
            return self._conn

    def close(self) -> None:
        if self._conn is not None:
            self._conn.close()
            self._conn = None

    async def call(self, *args: str, payload: dict | None = None, timeout: float = 60):
        """Run one command; returns its data or raises AgentError."""
        conn = await self.connection()
        cmd = "podkop-agent " + " ".join(shlex.quote(a) for a in args)
        try:
            r = await asyncio.wait_for(
                conn.run(cmd, input=json.dumps(payload) if payload is not None else "", check=False),
                timeout=timeout)
        except asyncio.TimeoutError:
            raise AgentError("timeout", f"{args[0]} took longer than {timeout:.0f} s") from None
        except (OSError, asyncssh.Error) as e:
            self.close()
            raise AgentError("unreachable", f"connection to {self.host} lost: {e}") from None
        out = (r.stdout or "").strip().splitlines()
        try:
            msg = json.loads(out[-1]) if out else None
        except json.JSONDecodeError:
            msg = None
        if not isinstance(msg, dict) or "ok" not in msg:
            raise AgentError("bad_answer", f"unexpected answer from podkop-agent: {(r.stdout or r.stderr or '')[:200]}")
        if not msg["ok"]:
            e = msg.get("error") or {}
            raise AgentError(e.get("code", "error"), e.get("message", "error"), e.get("details"))
        return msg.get("data")

    async def watch(self, since: str = "") -> AsyncIterator[dict]:
        """Events and log lines as they come; ends when the connection drops."""
        conn = await self.connection()
        proc = await conn.create_process("podkop-agent watch " + shlex.quote(since))
        try:
            async for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
        finally:
            proc.stdin.write_eof()
            proc.close()


AGENT_FILES = ("router/podkop-agent", "router/podkop-agent.init", "router/install.sh", "router/probe.sh")


async def install(host: str, port: int, password: str, public_key: str, src: Path,
                  allow_clash: list[str]) -> str:
    """Log in once with the root password, copy podkop-agent and podkop-probe
    to the router and run install.sh. Returns the router's host key, which
    every later connection is checked against. The password is not kept."""
    try:
        conn = await asyncio.wait_for(asyncssh.connect(
            host, port=port, username="root", password=password, known_hosts=None,
            client_keys=None, agent_path=None, preferred_auth="password,keyboard-interactive"), timeout=20)
    except asyncssh.PermissionDenied:
        raise AgentError("auth", "wrong root password") from None
    except (OSError, asyncssh.Error, asyncio.TimeoutError) as e:
        raise AgentError("unreachable", f"cannot connect to {host}: {e or type(e).__name__}") from None
    async with conn:
        host_key = conn.get_server_host_key().export_public_key().decode().strip()
        tmp = "/tmp/podkop-agent-src"
        await conn.run(f"rm -rf {tmp} && mkdir -p {tmp}", check=True)
        for f in AGENT_FILES:
            data = (src / f).read_bytes()
            await conn.run(f"cat > {tmp}/{Path(f).name}", input=data, encoding=None, check=True)
        cmd = f"sh {tmp}/install.sh --src {tmp} --key {shlex.quote(public_key)}"
        for ip in allow_clash:
            cmd += f" --allow-clash {shlex.quote(ip)}"
        r = await conn.run(cmd, check=False)
        await conn.run(f"rm -rf {tmp}", check=False)
        if r.exit_status != 0:
            raise AgentError("install", ((r.stderr or "") + (r.stdout or "")).strip()[-500:] or "install.sh failed")
    return " ".join(host_key.split()[:2])
