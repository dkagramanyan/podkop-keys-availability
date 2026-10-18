# Changelog

Versions are podkop-probe's (`probe.sh`); a release also carries
podkop-agent and podkop-manager.

## 1.19.0 — 2026-10-18

- Manager 0.9.0: **Routing → Configs**. Save a router's running config or
  its draft, with each rule's probe parameters; download it as a JSON file;
  import such a file or podkop's own `/etc/config/podkop`; load any saved
  config into a router's draft (its probe rules get the last probe's
  servers right away).
- **Settings → Backup**: download the whole manager (database and SSH key)
  as one `.tar.gz`, and restore it, e.g. on a new server.
- **YouTube region** in a rule's probe parameters: not checked, any (video
  plays), or the country YouTube must detect (RU: no ads), instead of the
  fixed "sees Russia".
- The manager's probe runs judge servers by their exit only
  (`--no-entry-check`): relays that enter in another country, like
  whitelist bypasses entering in Russia, are no longer dropped before the
  test. A rule whose countries no tested server exits in says so.
- Stability fixes in the manager:
  - **Background work:** polling, usage, the nightly scheduler and pruning
    no longer stop for good after an unexpected error. A garbled answer
    from the router marks it offline instead.
  - **Nightly probe:** if the router is unreachable at the set time, it is
    retried within the hour.
  - **Traffic limits:**
    - A key is no longer avoided again right after its provider reset.
    - A failed move to other keys is retried every 10 minutes.
    - Keys counted on the router include the current hour.
  - **Restore:** only one runs at a time. Apply tracking stops before it,
    and the upload size is checked while it arrives.
  - **Bad input:** files, rules and requests get a clear error instead of
    a server error. The login check no longer blocks the server.
  - **Cleanup:** old versions (beyond 500 per router) and old probe results
    (beyond 30) are pruned. A removed router or key leaves no settings or
    traffic behind.
  - **UI:**
    - Probe parameters keep focus while you type, and Exit IP keeps the
      spaces between addresses.
    - A rule editor you left can no longer overwrite the draft.
    - Live updates reconnect after an error.
    - Overview reads the config once the router is back.
- **Discard** also puts back the rules' probe parameters (and what "Load
  into draft" changed) as they were before the draft.
- **Two tabs:** a draft changed in another tab, or by "Load into draft", is
  no longer overwritten. The page reloads it instead.
- **After a restart or restore:** the manager follows the changes and probe
  runs the router was still busy with.
- **Traffic per server:** with agent 0.3.0, traffic is credited to the
  server it went through, not to the position in the rule. Moving servers
  no longer mixes up their bytes.
- podkop-agent 0.3.0 (**Settings → Reinstall agent** on each router to get it):
  - **Interrupted apply:** a change cut off by a reboot or a killed process
    is undone when the agent starts again (event "apply_interrupted").
  - **Killed probe:** a probe killed for lack of memory shows as failed,
    instead of "running" forever.
  - **Failed undo:** when the old settings can't be put back, the change is
    reported as failed instead of "the old settings are back".
  - **Smaller fixes:**
    - The apply lock is no longer held by podkop's own background jobs.
    - `last-good` is written atomically.
    - A damaged traffic state is reset.
- podkop-probe:
  - **Self-update:** a cut-off download is never installed (end marker and
    `sh -n`).
  - **Server names:** names like "Безлимит" or "Для всех устройств" are no
    longer taken for placeholder entries. Control characters in names
    don't break the results.
  - **Cleanup and memory:** a closed SSH session cleans up the test
    sing-box instances. The YouTube and speed tests respect the router's
    free RAM.
  - **Nightly lock:** a stale `--cron` lock no longer blocks every run.
  - **Relays:** relays that share one entry address but differ in SNI,
    path or user get their own speed and YouTube tests instead of copying
    another one's.

## 1.18.0 — 2026-10-18

- Manager 0.8.0: the Servers and Servers probe pages are gone. **Keys and
  usage** comes right after Overview.
- A Fastest (URLTest) rule has a **Take links from probe** switch; when on,
  the probe's parameters (region, protocol, exit IP, name, ping, speed,
  YouTube, how many) and **Run probe** are shown under it.
- The probe tests the countries of the rules (all, if a rule takes any);
  the probe page's countries move into the rules once ("Europe" is one
  choice in the rule). Schedule and auto-apply are in **Global settings**.
- Overview: **Review and apply** for a new probe result, **Unpin** for a
  pinned rule.

## 1.17.0 — 2026-10-18

- Manager 0.7.0: every rule, main and youtube included, can take its servers
  from the probe, each with its own filter (countries, protocols, exit IP,
  name), how many to keep, ping and speed limits, and a YouTube requirement
  (plays, or sees Russia without ads). The probe's own main and YouTube
  lists are gone; existing ones turn into such rules with the same limits.
- Servers probe keeps what to test (countries, quick run), the schedule and
  auto-apply; the probe tests with the loosest limits of the rules.
- Keys are added and removed under **Keys and usage** (subscriptions and
  single links); Servers probe only lists them.
- Login name: `PODKOP_MANAGER_USER` in `.env` (default `admin`).

## 1.16.0 — 2026-10-18

- Manager 0.6.0: new page **Keys and usage**. For each key: used today
  against its limit, a forecast at the last 3 hours' rate, the split by rule,
  the last 14 days and today's traffic by server. The menu shows the highest
  daily limit used, Overview warns when a key will run out today.
- Limits come from the provider (subscription-userinfo, read every 10 min)
  or are set by you; single links can be added as keys with their own limit.
- At 90% (or your threshold) a key either only warns or moves its rules:
  the probe's rules that use its servers are rebuilt from the last probe
  without them, through the usual checked apply, and put back after the
  reset. History shows these changes as "traffic limit".
- Agent 0.2.0: counts traffic per server from sing-box's connections, and
  reads each key's usage through podkop-probe (same device for the
  provider). Reinstall the agent from Settings to get it.
- probe: `--sub-info` prints each key's usage header and links.
- `.env`: `TZ` sets the time zone for "today" and the nightly probe.

## 1.15.0 — 2026-10-18

- Manager 0.5.0: pages swap in when their data is loaded, with a short fade,
  instead of going blank first; quick clicks show only the last page.
- Servers probe: a key's result ("device limit reached", server count) is
  shown only next to the key that ran, not next to whatever key now sits in
  the same place in the list.
- Less text: no page subtitles, shorter hints; the probe table drops the OK
  column (hover the result instead).

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
