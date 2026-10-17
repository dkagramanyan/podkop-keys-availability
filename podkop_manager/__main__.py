"""podkop-manager command line:

  podkop-manager serve [--listen 0.0.0.0:8080] [--data /var/lib/podkop-manager]
  podkop-manager set-password [--data DIR]
  podkop-manager public-key [--data DIR]
  podkop-manager check [--data DIR]       exit 0 when a password is set
"""

from __future__ import annotations

import argparse
import getpass
import logging
import os
import sys
from pathlib import Path

import asyncssh

from .db import DB


def data_dir(arg: str | None) -> Path:
    d = Path(arg or os.environ.get("PODKOP_MANAGER_DATA") or "/var/lib/podkop-manager")
    d.mkdir(parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    return d


def ssh_key(d: Path) -> tuple[Path, str]:
    """The manager's own SSH key; routers allow it to run only podkop-agent."""
    path = d / "id_ed25519"
    if not path.exists():
        key = asyncssh.generate_private_key("ssh-ed25519", comment="podkop-manager")
        key.write_private_key(str(path))
        os.chmod(path, 0o600)
    key = asyncssh.read_private_key(str(path))
    return path, key.export_public_key().decode().strip()


def source_dir() -> Path:
    """Where router/ (podkop-agent, install.sh, probe.sh) is: the repository
    this package lives in, or PODKOP_MANAGER_SRC."""
    env = os.environ.get("PODKOP_MANAGER_SRC")
    if env:
        return Path(env)
    return Path(__file__).resolve().parents[1]


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="podkop-manager")
    p.add_argument("command", choices=["serve", "set-password", "public-key", "check"])
    p.add_argument("--data", help="data directory (default /var/lib/podkop-manager)")
    p.add_argument("--listen", default=os.environ.get("PODKOP_MANAGER_LISTEN", "0.0.0.0:8080"))
    a = p.parse_args(argv)
    d = data_dir(a.data)
    db = DB(d / "manager.db")

    if a.command == "set-password":
        from .web import hash_password
        pw = getpass.getpass("New password: ")
        if len(pw) < 8 or pw != getpass.getpass("Again: "):
            print("passwords differ or shorter than 8 characters", file=sys.stderr)
            return 1
        db.set_setting("password_hash", hash_password(pw))
        print("password set")
        return 0

    if a.command == "check":
        ok = bool(db.get_setting("password_hash"))
        print("ok" if ok else "no password set")
        return 0 if ok else 1

    key_path, public_key = ssh_key(d)
    if a.command == "public-key":
        print(public_key)
        return 0

    import uvicorn

    from .agent import AGENT_FILES
    from .hub import Hub
    from .web import create_app

    src = source_dir()
    missing = [f for f in AGENT_FILES if not (src / f).exists()]
    if missing:
        print(f"cannot find {', '.join(missing)} in {src} (set PODKOP_MANAGER_SRC)", file=sys.stderr)
        return 1
    if not db.get_setting("password_hash"):
        print("no password yet: run 'podkop-manager set-password' first", file=sys.stderr)
        return 1
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    logging.getLogger("asyncssh").setLevel(logging.WARNING)
    host, _, port = a.listen.rpartition(":")
    app = create_app(db, Hub(db, key_path, src), public_key)
    uvicorn.run(app, host=host or "0.0.0.0", port=int(port), log_level="warning", proxy_headers=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
