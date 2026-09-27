# podkop-probe

Tests all servers from your VPN subscriptions ("keys") on your OpenWrt
router and puts the best ones into [podkop](https://github.com/itdoginfo/podkop),
once or every night: the 10 fastest into the main section, and the 10 best
for YouTube (no ads when possible) into a separate `youtube` section.
Needs podkop to be installed.

## Run

On the router (`ssh root@192.168.1.1`):

```sh
sh <(wget -O - https://github.com/dkagramanyan/podkop-keys-availability-/releases/latest/download/probe.sh)
```

1. Press **Enter** (test my keys). Paste your keys, one per line, then
   press Enter on an empty line.
2. Press **Enter** for "Europe only".
3. Wait 2–7 minutes. You get two tables: **Main** (picks marked `*`)
   and **YouTube** (picks marked `y`).
4. Press **Enter** to put them into podkop and restart it (`n` = no;
   numbers = pick other servers for main).
5. At "Repeat this every night?" press **Enter**. This installs the
   `podkop-probe` command and saves your keys.

## Install only

To install without testing, run:

```sh
sh <(wget -O - https://github.com/dkagramanyan/podkop-keys-availability-/releases/latest/download/probe.sh) --install
```

It asks for your keys and countries. Later, run `podkop-probe` to open the
menu; item `4` changes the keys.

## Every night at 04:30

1. In LuCI open **System → Scheduled Tasks**, add this line and click
   **Save**:
   ```
   30 4 * * * podkop-probe --cron
   ```
2. In **System → Startup**, make sure **cron** is *Enabled*.

`podkop-probe` itself does not appear in Startup; cron runs it.

Each night it updates itself, tests the saved keys, puts the new top 10
into podkop and restarts podkop. If nothing works, podkop is left alone.

- **Log:** `cat /tmp/podkop-probe.log`
- **Run it now:** `podkop-probe --cron`
- **Remove everything:** `podkop-probe --uninstall`

## What gets picked

- **Main section** (`main`, all your lists): fewest lost requests, lowest
  ping, highest speed. Servers with ping of 700 ms or more, or speed under
  30 Mbit/s, are never picked (`--max-ping 500`, `--min-speed 50` to change).
- **YouTube section** (`youtube`): the fast servers are also checked with
  YouTube, and ranked by ping to YouTube and speed.
  - The `yt` column shows the country YouTube thinks you are in (the small
    code next to the YouTube logo). `no` means YouTube doesn't play there
    ("video unavailable" or "confirm you're not a bot"), so it isn't picked.
  - YouTube shows no ads in Russia, so if at least 2 servers show `RU`,
    only those are used.
  - On the first run the script creates this section with podkop's
    **YouTube** list and puts it **above** `main`. That order matters: lists
    like "Russia inside" also contain YouTube, and the first section wins.
    You don't need to add any domains yourself.
  - `--no-youtube` leaves the YouTube section alone.

## Undo

Your previous podkop settings are backed up before every change:

```sh
cp /etc/config/podkop.probe-backup.<date> /etc/config/podkop && /etc/init.d/podkop restart
```

## Good to know

- **Countries.** "Europe only" checks the server name, the IP you connect
  to and the IP your traffic exits from. So relays "через 🇷🇺" are
  skipped.
- **xhttp servers** are skipped: podkop (sing-box) can't run them.
- **Speed tests** go through the VPN server, so a provider blocking
  Cloudflare doesn't matter. On fast lines up to 3 run at once.
- **More detail:** `-v` shows every server and why the others failed.
- **Faster check:** `-q`.
- **A key gives no servers?** Check what it returns (Mac/Linux, prints no
  secrets):
  `bash <(curl -fsSL https://raw.githubusercontent.com/dkagramanyan/podkop-keys-availability-/main/tools/sub-check.sh) 'https://your-key'`
- **All options:** `podkop-probe -h`

## Коротко по-русски

1. На роутере выполните команду из раздела **Run**, затем:
   - нажмите Enter;
   - вставьте ключи и нажмите Enter на пустой строке;
   - нажмите Enter («только Европа»);
   - через несколько минут нажмите Enter: лучшие 10 серверов попадут в
     podkop;
   - на вопрос «Repeat this every night?» тоже нажмите Enter.
2. Только установка: та же команда с `--install` в конце.
3. Каждую ночь: в LuCI откройте **Система → Планировщик**, добавьте
   строку `30 4 * * * podkop-probe --cron` и нажмите «Сохранить». `cron`
   должен быть включён (**Система → Загрузка**).
4. Серверы с пингом от 700 мс или скоростью меньше 30 Мбит/с не
   выбираются. Для YouTube скрипт сам создаёт в podkop секцию `youtube`
   (список YouTube, выше `main`) и кладёт туда серверы, где YouTube
   работает; если есть хотя бы 2 сервера, где YouTube видит `RU`
   (без рекламы), только их.
5. Лог: `/tmp/podkop-probe.log`. Удалить всё: `podkop-probe --uninstall`.
