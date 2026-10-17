# podkop-probe

Tests every server from your VPN subscriptions ("keys") on your OpenWrt
router and puts the best into [podkop](https://github.com/itdoginfo/podkop):
10 fastest servers into section `main`, 10 fastest where YouTube sees Russia
(no ads) into section `youtube`, each with 5 fallback servers.
Needs podkop and [podkop-engine](https://github.com/FiyeroT/podkop-engine).

## Run

On the router:

```sh
sh <(wget -O - https://github.com/dkagramanyan/podkop-keys-availability/releases/latest/download/probe.sh)
```

1. **Enter**, paste your keys (one per line), then an empty line.
2. **Enter** for "Europe only". Wait 2–7 minutes.
3. Tables: `*` = main, `y` = YouTube, `f` = fallback.
   **Enter** puts both lists into podkop and restarts it
   (`1` only main, `2` only YouTube, `3` other sections, `n` nothing).
4. "Repeat this every night?" **Enter** installs `podkop-probe` and saves
   your keys. Add `--install` to the command above to install without testing.

## Every night

LuCI → **System → Scheduled Tasks**, add and **Save**:

```
30 4 * * * podkop-probe --cron
```

Each night it updates itself, tests the saved keys and updates podkop. If
nothing works, or podkop does not start with the new lists, your old
settings stay. Log: `/tmp/podkop-probe.log`. Remove: `podkop-probe --uninstall`.

## Manage from a server

[podkop-manager](manager/README.md) is a web interface on an Ubuntu server for
all podkop settings on one or more routers: changes are checked first and
undone automatically if podkop doesn't start, plus server pinning, the
nightly probe, live logs and a history of changes.

## Good to know

- Never picked: ping 700 ms or more, or 40 Mbit/s or less
  (`--max-ping`, `--min-speed`).
- The `youtube` section is created above `main` with podkop's YouTube list:
  the first matching section wins.
- Servers are built by podkop itself: vless, trojan, ss, hysteria2 and socks
  over tcp, ws, grpc or xhttp. Others (vmess, ...) are skipped.
- "Europe only" checks the name, the server IP and the exit IP, so relays
  "через 🇷🇺" are skipped.
- "Device limit reached": free a device in your provider's bot.
- Backup before every change: `/etc/config/podkop.probe-backup.<date>`.
- `-v` shows every server and why it failed; `-h` lists all options.

## Коротко по-русски

Выполните команду из **Run** на роутере: Enter, вставьте ключи, пустая
строка, Enter («только Европа»), через несколько минут Enter — серверы
попадут в podkop (`main`, `youtube` и по 5 резервных). На «Repeat this every
night?» Enter. Каждую ночь: **Система → Планировщик**, строка
`30 4 * * * podkop-probe --cron`. Не берутся серверы с пингом от 700 мс или
скоростью до 40 Мбит/с. Лог: `/tmp/podkop-probe.log`. Веб-интерфейс для
управления podkop с сервера: [podkop-manager](manager/README.md).
