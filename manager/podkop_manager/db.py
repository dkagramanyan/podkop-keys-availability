"""SQLite storage: routers, their events and logs, every applied config
version, probe settings and runs, and the manager's own settings."""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS routers (
  id INTEGER PRIMARY KEY, name TEXT NOT NULL, host TEXT NOT NULL, port INTEGER NOT NULL DEFAULT 22,
  host_key TEXT NOT NULL, added REAL NOT NULL, last_event TEXT
);
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY, router_id INTEGER NOT NULL, t REAL NOT NULL, type TEXT NOT NULL, data TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS events_router ON events (router_id, id);
CREATE TABLE IF NOT EXISTS logs (
  id INTEGER PRIMARY KEY, router_id INTEGER NOT NULL, t REAL NOT NULL, line TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS logs_router ON logs (router_id, id);
CREATE TABLE IF NOT EXISTS versions (
  id INTEGER PRIMARY KEY, router_id INTEGER NOT NULL, t REAL NOT NULL, job TEXT, state TEXT NOT NULL,
  message TEXT, note TEXT, fingerprint_before TEXT, config TEXT NOT NULL, diff TEXT NOT NULL,
  details TEXT
);
CREATE INDEX IF NOT EXISTS versions_router ON versions (router_id, id);
CREATE TABLE IF NOT EXISTS probe_settings (
  router_id INTEGER PRIMARY KEY, keys TEXT NOT NULL DEFAULT '[]', options TEXT NOT NULL DEFAULT '[]',
  schedule TEXT NOT NULL DEFAULT '', auto_apply INTEGER NOT NULL DEFAULT 0,
  main_section TEXT NOT NULL DEFAULT 'main', youtube_section TEXT NOT NULL DEFAULT 'youtube',
  last_run_day TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS probe_runs (
  id INTEGER PRIMARY KEY, router_id INTEGER NOT NULL, started REAL NOT NULL, finished REAL,
  state TEXT NOT NULL, trigger TEXT NOT NULL, result TEXT, version_id INTEGER
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


class DB:
    def __init__(self, path: Path):
        self.conn = sqlite3.connect(str(path), check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        self.lock = threading.Lock()
        with self.lock:
            self.conn.execute("PRAGMA journal_mode=WAL")
            self.conn.executescript(SCHEMA)

    def q(self, sql: str, *args) -> list[dict]:
        with self.lock:
            return [dict(r) for r in self.conn.execute(sql, args).fetchall()]

    def one(self, sql: str, *args) -> dict | None:
        rows = self.q(sql, *args)
        return rows[0] if rows else None

    def x(self, sql: str, *args) -> int:
        with self.lock:
            return self.conn.execute(sql, args).lastrowid

    # --- settings ---------------------------------------------------------------
    def get_setting(self, key: str, default=None):
        r = self.one("SELECT value FROM settings WHERE key = ?", key)
        return json.loads(r["value"]) if r else default

    def set_setting(self, key: str, value) -> None:
        self.x("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
               key, json.dumps(value))

    # --- routers ----------------------------------------------------------------
    def routers(self) -> list[dict]:
        return self.q("SELECT * FROM routers ORDER BY id")

    def router(self, rid: int) -> dict | None:
        return self.one("SELECT * FROM routers WHERE id = ?", rid)

    def add_router(self, name: str, host: str, port: int, host_key: str) -> int:
        rid = self.x("INSERT INTO routers (name, host, port, host_key, added) VALUES (?, ?, ?, ?, ?)",
                     name, host, port, host_key, time.time())
        self.x("INSERT OR IGNORE INTO probe_settings (router_id, options) VALUES (?, ?)",
               rid, json.dumps(["--countries", "europe"]))
        return rid

    def update_router(self, rid: int, **fields) -> None:
        for k, v in fields.items():
            assert k in {"name", "host", "port", "host_key", "last_event"}
            self.x(f"UPDATE routers SET {k} = ? WHERE id = ?", v, rid)

    def delete_router(self, rid: int) -> None:
        for table in ("events", "logs", "versions", "probe_runs"):
            self.x(f"DELETE FROM {table} WHERE router_id = ?", rid)
        self.x("DELETE FROM probe_settings WHERE router_id = ?", rid)
        self.x("DELETE FROM routers WHERE id = ?", rid)

    # --- events and logs ----------------------------------------------------------
    def add_event(self, rid: int, etype: str, data: dict, t: float | None = None) -> int:
        return self.x("INSERT INTO events (router_id, t, type, data) VALUES (?, ?, ?, ?)",
                      rid, t or time.time(), etype, json.dumps(data))

    def events(self, rid: int, limit: int = 100) -> list[dict]:
        rows = self.q("SELECT * FROM events WHERE router_id = ? ORDER BY id DESC LIMIT ?", rid, limit)
        for r in rows:
            r["data"] = json.loads(r["data"])
        return rows

    def add_log(self, rid: int, line: str) -> None:
        self.x("INSERT INTO logs (router_id, t, line) VALUES (?, ?, ?)", rid, time.time(), line)

    def logs(self, rid: int, q: str = "", limit: int = 500) -> list[dict]:
        if q:
            rows = self.q("SELECT * FROM logs WHERE router_id = ? AND line LIKE ? ORDER BY id DESC LIMIT ?",
                          rid, f"%{q}%", limit)
        else:
            rows = self.q("SELECT * FROM logs WHERE router_id = ? ORDER BY id DESC LIMIT ?", rid, limit)
        return rows[::-1]

    def prune(self, log_days: int = 14, event_days: int = 180) -> None:
        now = time.time()
        self.x("DELETE FROM logs WHERE t < ?", now - log_days * 86400)
        self.x("DELETE FROM events WHERE t < ?", now - event_days * 86400)

    # --- config versions ------------------------------------------------------------
    def add_version(self, rid: int, config: dict, diff: list, note: str, base: str) -> int:
        return self.x("INSERT INTO versions (router_id, t, state, note, fingerprint_before, config, diff) "
                      "VALUES (?, ?, 'pending', ?, ?, ?, ?)",
                      rid, time.time(), note, base, json.dumps(config), json.dumps(diff))

    def update_version(self, vid: int, **fields) -> None:
        for k, v in fields.items():
            assert k in {"job", "state", "message", "details"}
            self.x(f"UPDATE versions SET {k} = ? WHERE id = ?", json.dumps(v) if k == "details" else v, vid)

    def versions(self, rid: int, limit: int = 100) -> list[dict]:
        rows = self.q("SELECT id, router_id, t, job, state, message, note, diff FROM versions "
                      "WHERE router_id = ? ORDER BY id DESC LIMIT ?", rid, limit)
        for r in rows:
            r["diff"] = json.loads(r["diff"])
        return rows

    def version(self, vid: int) -> dict | None:
        r = self.one("SELECT * FROM versions WHERE id = ?", vid)
        if r:
            for k in ("config", "diff", "details"):
                r[k] = json.loads(r[k]) if r[k] else None
        return r

    # --- probe ------------------------------------------------------------------------
    def probe_settings(self, rid: int) -> dict:
        r = self.one("SELECT * FROM probe_settings WHERE router_id = ?", rid) or {}
        for k in ("keys", "options"):
            r[k] = json.loads(r.get(k) or "[]")
        return r

    def set_probe_settings(self, rid: int, **fields) -> None:
        self.x("INSERT OR IGNORE INTO probe_settings (router_id) VALUES (?)", rid)
        for k, v in fields.items():
            assert k in {"keys", "options", "schedule", "auto_apply", "main_section", "youtube_section",
                         "last_run_day"}
            self.x(f"UPDATE probe_settings SET {k} = ? WHERE router_id = ?",
                   json.dumps(v) if k in ("keys", "options") else v, rid)

    def add_probe_run(self, rid: int, trigger: str) -> int:
        return self.x("INSERT INTO probe_runs (router_id, started, state, trigger) VALUES (?, ?, 'running', ?)",
                      rid, time.time(), trigger)

    def finish_probe_run(self, run_id: int, state: str, result: dict | None, version_id: int | None = None):
        self.x("UPDATE probe_runs SET finished = ?, state = ?, result = ?, version_id = ? WHERE id = ?",
               time.time(), state, json.dumps(result) if result is not None else None, version_id, run_id)

    def probe_runs(self, rid: int, limit: int = 20) -> list[dict]:
        rows = self.q("SELECT id, started, finished, state, trigger, version_id FROM probe_runs "
                      "WHERE router_id = ? ORDER BY id DESC LIMIT ?", rid, limit)
        return rows
