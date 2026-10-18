"""The whole manager in one file (.tar.gz): the database (routers, keys,
rules, saved configs, history) and the SSH keys the routers trust."""

from __future__ import annotations

import io
import json
import os
import tarfile
import tempfile
import time
from pathlib import Path

import asyncssh

from . import __version__
from .db import DB

MAX_SIZE = 256 * 1024 ** 2
NAMES = {"backup.json", "manager.db", "id_ed25519"}
OPTIONAL = {"id_forward"}     # the forwarding key (1.22.0 on)


def make(db: DB, key: Path) -> bytes:
    with tempfile.TemporaryDirectory(dir=key.parent) as tmp:
        dbfile = Path(tmp) / "manager.db"
        db.copy_to(dbfile)
        meta = json.dumps({"format": "podkop-manager-backup", "version": 1, "manager": __version__,
                           "saved": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}).encode()
        out = io.BytesIO()
        with tarfile.open(fileobj=out, mode="w:gz") as tar:
            info = tarfile.TarInfo("backup.json")
            info.size, info.mtime, info.mode = len(meta), int(time.time()), 0o600
            tar.addfile(info, io.BytesIO(meta))
            tar.add(dbfile, "manager.db")
            tar.add(key, "id_ed25519")
            if (key.parent / "id_forward").exists():
                tar.add(key.parent / "id_forward", "id_forward")
        return out.getvalue()


def restore(db: DB, key: Path, data: bytes) -> str:
    """Replaces the database and the SSH key with the backup's; returns the
    new public key. Raises ValueError for a file that is not a backup."""
    with tempfile.TemporaryDirectory(dir=key.parent) as tmp:
        files = {}
        try:
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
                for m in tar:       # member by member: stop at the first one that doesn't belong
                    if m.name not in NAMES | OPTIONAL or m.name in files or not m.isfile() or m.size > MAX_SIZE:
                        raise ValueError(f"unexpected {m.name} in the backup")
                    files[m.name] = tar.extractfile(m).read()
        except (tarfile.TarError, OSError, EOFError):
            raise ValueError("not a podkop-manager backup (.tar.gz)") from None
        try:
            meta = json.loads(files.get("backup.json") or b"null")
        except ValueError:
            meta = None
        if set(files) - OPTIONAL != NAMES or not isinstance(meta, dict) or meta.get("format") != "podkop-manager-backup":
            raise ValueError("not a podkop-manager backup")
        try:
            new_key = asyncssh.import_private_key(files["id_ed25519"])
            if "id_forward" in files:
                asyncssh.import_private_key(files["id_forward"])
        except (asyncssh.KeyImportError, ValueError):
            raise ValueError("the backup's SSH key is damaged") from None
        # everything written next to the data first, so after the database swap only a rename is left
        tmp_keys = {}
        for name, dest in (("id_ed25519", key), ("id_forward", key.parent / "id_forward")):
            if name in files:
                tmp_keys[Path(tmp) / name] = dest
                (Path(tmp) / name).write_bytes(files[name])
                os.chmod(Path(tmp) / name, 0o600)
        dbfile = Path(tmp) / "manager.db"
        dbfile.write_bytes(files["manager.db"])
        db.restore_from(dbfile)
        for src, dest in tmp_keys.items():
            os.replace(src, dest)
    return new_key.export_public_key().decode().strip()
