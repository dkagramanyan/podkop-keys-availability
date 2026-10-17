# Changelog

Versions are podkop-probe's (`probe.sh`); a release also carries
podkop-agent and podkop-manager.

## 1.14.1 — 2026-10-18

- The web interface's port is `PODKOP_MANAGER_PORT` in `.env` (default 8080).

## 1.14.0 — 2026-10-18

- Manager 0.4.0: credentials come from `.env`: `PODKOP_MANAGER_PASSWORD`
  (web login) and optionally `PODKOP_MANAGER_ROUTER_PASSWORD` (used when the
  root password field is left empty). `set-password` and the password change
  in Settings are gone; a new password logs everyone out.

## 1.13.0 — 2026-10-18

- The repository is now `podkop-manager` (old links redirect).
- Manager 0.3.0 runs with Docker Compose (`compose.yaml`, host network, data
  in a volume); `install-ubuntu.sh` and the systemd unit are removed.
- New layout: the manager at the root, router files in `router/`. Release
  assets keep their names, so installed routers keep updating.
- One README for everything.

## 1.12.0 — 2026-10-18

- Manager 0.2.0: new web interface: a menu with a router switcher, Overview,
  Routing rules, Global settings, Servers, Servers probe, Logs, History,
  Settings.
- Changes to rules and settings collect in a draft kept on the server until
  **Review and apply**; the apply dialog shows each step live.
- Rules can take servers from your subscriptions: by exit country, protocol,
  exit IP or name. They are refreshed after every probe run.
- Logs filter by source (podkop, sing-box, engine, agent) and level.
- History shows what started each change (you, a restore, the probe) and
  pages back further. Restoring an old version goes through the same check.
- Password can be changed in Settings.
- Probe page shows each key's result ("device limit reached", server count).
- probe: links with the same exit IP are no longer dropped; the best links
  are kept in order.
- probe: saves each server's link next to the results (`<csv>.links`).
- Agent 0.1.1: passes those links on and returns the full probe log.

## 1.11.0 — 2026-10-17

- podkop-manager: web interface on a Linux server for podkop on one or more
  routers: all settings and sections, checked apply with history and
  restore, server pinning, delay tests, probe runs (manual or nightly),
  live logs.
- podkop-agent on the router: checks every change before podkop is touched,
  undoes it if podkop doesn't start, brings podkop back after a crash,
  keeps pinned servers after restarts.
- `agent/install.sh`: agent, probe, a key that may run only the agent,
  Clash API closed to the LAN.

## 1.10.1 — 2026-10-17

- Shorter README; download and update links use the current repo name.

## 1.10.0 — 2026-10-17

- Needs podkop 0.7.24 and podkop-engine. Servers are built by podkop's own
  parser, so they are tested exactly as podkop runs them; xhttp works.
- The next 5 servers of each list go into podkop's fallback links.
- After the restart: wait for podkop's groups, reset a hand-picked server,
  restore the old settings if podkop fails to start.
- Clear message when a key's device limit is reached.

## 1.9.1 — 2026-09-27

- "y" at the final question applies (it used to do nothing); unknown
  answers ask again.
- `--apply-saved` applies the last run's lists without testing again.

## 1.9.0 — 2026-09-27

- Separate `youtube` section (above `main`) with servers where YouTube sees
  Russia (no ads).
- Never picked: ping 700 ms or more, 40 Mbit/s or less (`--max-ping`,
  `--min-speed`).
- Choose where to apply: both, main, youtube, or other sections
  (`--apply-to`).

## 1.8.0 — 2026-09-27

- YouTube check: servers where YouTube doesn't play are never picked.
- Fix: the settings file with the keys was readable by everyone.

## 1.7.0 — 2026-09-26

- `--install` asks for keys, countries and time; menu item 4 changes them.

## 1.6.0 — 2026-09-26

- "Repeat this every night?" installs `/usr/bin/podkop-probe` with the saved
  keys; the nightly line is `podkop-probe --cron`, which also updates
  itself. Log in `/tmp/podkop-probe.log`.
- `--install`, `--update`, `--uninstall`.
- Quieter output: one progress line, a short table, one question.

## 1.5.0 — 2026-09-26

- Several speed tests at once, sized to the router's line.
- "Europe only" also checks the server's IP, so relays through Russia are
  skipped.
- Fix: the pick list always showed speed as "-".

## 1.4.0 — 2026-09-26

- Fix: the speed test showed 0 Mbit/s on every server.
- Speed test stops once the result is stable; links to the same server share
  one test.

## 1.3.0 — 2026-09-26

- Latency and speed tested in one session per server; picks ranked by
  latency and speed equally.
- Type server numbers at the end to choose your own.

## 1.2.0 — 2026-09-26

- Subscriptions fetched like Happ, Streisand, INCY and others do, so panels
  return real servers; JSON subscriptions supported.
- Country filter (`--countries`), Europe by default.
- Subscription name, traffic and expiry shown.
- `tools/sub-check.sh`: what a subscription returns to each client app.

## 1.1.0 — 2026-09-26

- Several subscriptions at once, speed test, nightly run.
- podkop isn't restarted when the picked servers didn't change.

## 1.0.0 — 2026-09-26

- First version: tests every server of a subscription on the router, picks
  the best and puts them into podkop.
