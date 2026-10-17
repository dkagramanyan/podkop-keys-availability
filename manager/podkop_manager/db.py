"""SQLite storage: routers, their events and logs, every applied config
version, unapplied drafts, probe settings and runs, and the manager's own
settings."""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from datetime import datetime
from pathlib import Path

from .podkop import parse_log

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
  id INTEGER PRIMARY KEY, router_id INTEGER NOT NULL, t REAL NOT NULL, line TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT '', level TEXT NOT NULL DEFAULT 'info'
);
CREATE INDEX IF NOT EXISTS logs_router ON logs (router_id, id);
CREATE TABLE IF NOT EXISTS versions (
  id INTEGER PRIMARY KEY, router_id INTEGER NOT NULL, t REAL NOT NULL, job TEXT, state TEXT NOT NULL,
  message TEXT, note TEXT, fingerprint_before TEXT, config TEXT NOT NULL, diff TEXT NOT NULL,
  details TEXT, trigger TEXT NOT NULL DEFAULT 'web'
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
CREATE TABLE IF NOT EXISTS drafts (
  router_id INTEGER PRIMARY KEY, config TEXT NOT NULL, base TEXT NOT NULL, updated REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS auto_rules (
  router_id INTEGER NOT NULL, section TEXT NOT NULL, countries TEXT NOT NULL DEFAULT '[]',
  protocols TEXT NOT NULL DEFAULT '[]', exit_ips TEXT NOT NULL DEFAULT '[]', name_contains TEXT NOT NULL DEFAULT '',
  top INTEGER NOT NULL DEFAULT 5, fallback INTEGER NOT NULL DEFAULT 2, PRIMARY KEY (router_id, section)
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""

# columns added after the first release: (table, column, declaration)
COLUMNS = [
    ("logs", "source", "TEXT NOT NULL DEFAULT ''"),
    ("logs", "level", "TEXT NOT NULL DEFAULT 'info'"),
    ("versions", "trigger", "TEXT NOT NULL DEFAULT 'web'"),
]


class DB:
    def __init__(self, path: Path):
        self.conn = sqlite3.connect(str(path), check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        self.lock = threading.Lock()
        with self.lock:
            self.conn.execute("PRAGMA journal_mode=WAL")
            self.conn.executescript(SCHEMA)
            added = set()
            for table, col, decl in COLUMNS:
                if col not in [r[1] for r in self.conn.execute(f"PRAGMA table_info({table})")]:
                    self.conn.execute(f"ALTER TABLE {table} ADD COLUMN {col} {decl}")
                    added.add((table, col))
            if ("logs", "source") in added:
                rows = self.conn.execute("SELECT id, line FROM logs").fetchall()
                parsed = [(p["source"], p["level"], r[0]) for r in rows for p in [parse_log(r[1])]]
                self.conn.executemany("UPDATE logs SET source = ?, level = ? WHERE id = ?", parsed)

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
        for table in ("events", "logs", "versions", "probe_runs", "drafts", "auto_rules"):
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

    def add_log(self, rid: int, line: str, source: str = "", level: str = "info") -> None:
        self.x("INSERT INTO logs (router_id, t, line, source, level) VALUES (?, ?, ?, ?, ?)",
               rid, time.time(), line, source, level)

    def logs(self, rid: int, q: str = "", limit: int = 500, sources: list[str] | None = None,
             levels: list[str] | None = None) -> list[dict]:
        sql, args = "SELECT * FROM logs WHERE router_id = ?", [rid]
        if q:
            sql += " AND line LIKE ?"
            args.append(f"%{q}%")
        for col, values in (("source", sources), ("level", levels)):
            if values:
                sql += f" AND {col} IN ({', '.join('?' * len(values))})"
                args += values
        rows = self.q(sql + " ORDER BY id DESC LIMIT ?", *args, limit)
        return rows[::-1]

    def prune(self, log_days: int = 14, event_days: int = 180) -> None:
        now = time.time()
        self.x("DELETE FROM logs WHERE t < ?", now - log_days * 86400)
        self.x("DELETE FROM events WHERE t < ?", now - event_days * 86400)

    # --- config versions ------------------------------------------------------------
    def add_version(self, rid: int, config: dict, diff: list, note: str, base: str, trigger: str = "web") -> int:
        return self.x("INSERT INTO versions (router_id, t, state, note, fingerprint_before, config, diff, trigger) "
                      "VALUES (?, ?, 'pending', ?, ?, ?, ?, ?)",
                      rid, time.time(), note, base, json.dumps(config), json.dumps(diff), trigger)

    def update_version(self, vid: int, **fields) -> None:
        for k, v in fields.items():
            assert k in {"job", "state", "message", "details"}
            self.x(f"UPDATE versions SET {k} = ? WHERE id = ?", json.dumps(v) if k == "details" else v, vid)

    def versions(self, rid: int, limit: int = 100, before: int | None = None) -> list[dict]:
        """Newest first, with from the job's answer: the fingerprint the router
        had after it, how long it took, and why it was undone or rejected."""
        rows = self.q("SELECT id, router_id, t, job, state, message, note, diff, details, trigger FROM versions "
                      "WHERE router_id = ? AND id < ? ORDER BY id DESC LIMIT ?", rid, before or 2**62, limit)
        for r in rows:
            r["diff"] = json.loads(r["diff"])
            d = json.loads(r.pop("details") or "null") or {}
            r["fingerprint_after"] = d.get("fingerprint_after")
            r["reason"] = d.get("reason")
            r["problems"] = d.get("problems")
            r["code"] = d.get("code")
            r["seconds"] = _seconds(d.get("started"), d.get("finished"))
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
        rows = self.q("SELECT p.id, p.started, p.finished, p.state, p.trigger, p.version_id, v.state AS version_state "
                      "FROM probe_runs p LEFT JOIN versions v ON v.id = p.version_id "
                      "WHERE p.router_id = ? ORDER BY p.id DESC LIMIT ?", rid, limit)
        return rows

    def probe_result(self, run_id: int) -> dict | None:
        r = self.one("SELECT result FROM probe_runs WHERE id = ?", run_id)
        return json.loads(r["result"]) if r and r["result"] else None

    # --- drafts: unapplied changes, one per router ----------------------------------------
    def draft(self, rid: int) -> dict | None:
        r = self.one("SELECT config, base, updated FROM drafts WHERE router_id = ?", rid)
        if r:
            r["config"] = json.loads(r["config"])
        return r

    def set_draft(self, rid: int, config: dict, base: str) -> None:
        self.x("INSERT INTO drafts (router_id, config, base, updated) VALUES (?, ?, ?, ?) "
               "ON CONFLICT (router_id) DO UPDATE SET config = excluded.config, base = excluded.base, "
               "updated = excluded.updated", rid, json.dumps(config), base, time.time())

    def delete_draft(self, rid: int) -> None:
        self.x("DELETE FROM drafts WHERE router_id = ?", rid)

    # --- rules whose servers the probe picks by country ---------------------------------
    def auto_rules(self, rid: int) -> list[dict]:
        rows = self.q("SELECT * FROM auto_rules WHERE router_id = ? ORDER BY section", rid)
        for r in rows:
            for k in ("countries", "protocols", "exit_ips"):
                r[k] = json.loads(r[k])
        return rows

    def auto_rule(self, rid: int, section: str) -> dict | None:
        return next((r for r in self.auto_rules(rid) if r["section"] == section), None)

    def set_auto_rule(self, rid: int, section: str, rule: dict) -> None:
        self.x("INSERT INTO auto_rules (router_id, section, countries, protocols, exit_ips, name_contains, top, fallback) "
               "VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (router_id, section) DO UPDATE SET "
               "countries = excluded.countries, protocols = excluded.protocols, exit_ips = excluded.exit_ips, "
               "name_contains = excluded.name_contains, top = excluded.top, fallback = excluded.fallback",
               rid, section, json.dumps(rule["countries"]), json.dumps(rule["protocols"]), json.dumps(rule["exit_ips"]),
               rule["name_contains"], rule["top"], rule["fallback"])

    def delete_auto_rule(self, rid: int, section: str) -> None:
        self.x("DELETE FROM auto_rules WHERE router_id = ? AND section = ?", rid, section)


def _seconds(start: str | None, end: str | None) -> int | None:
    """Seconds between two of the agent's UTC times (2026-10-17T21:03:05Z)."""
    try:
        f = "%Y-%m-%dT%H:%M:%SZ"
        return int((datetime.strptime(end, f) - datetime.strptime(start, f)).total_seconds())
    except (TypeError, ValueError):
        return None
