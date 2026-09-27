# podkop-probe

Tests all servers from your VPN subscriptions ("keys") on your OpenWrt
router and puts the best ones into [podkop](https://github.com/itdoginfo/podkop),
once or every night, as two lists: the 10 fastest servers for the main
section, and the 10 fastest where YouTube sees Russia (no ads) for a
separate `youtube` section.
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
4. Choose what goes into podkop (then it restarts):
   **Enter** = both lists, `1` = only main, `2` = only YouTube,
   `3` = other sections (you type their names), `n` = nothing.
   Changed your mind later? `podkop-probe --apply-saved` puts the lists
   of the last run into podkop without testing again (until a reboot).
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

- **Both lists:** servers with ping of 700 ms or more, or speed of 40 Mbit/s
  or less, are never picked (`--max-ping 500`, `--min-speed 60` to change).
- **Main list → section `main`:** fewest lost requests, lowest ping, highest
  speed.
- **YouTube list → section `youtube`:** only servers where YouTube sees
  **RU** (the small code next to the YouTube logo; Russia gets no ads),
  ranked by ping to YouTube and speed. If there are none, the section is
  left alone. `yt` = the country YouTube sees, `no` = YouTube doesn't play.
- The first time, the script creates the `youtube` section with podkop's
  **YouTube** list and puts it **above** `main`. That order matters: lists
  like "Russia inside" also contain YouTube, and the first section wins.
  You don't need to add any domains yourself.
- Nightly run: both lists by default; `--apply-to main` or
  `--apply-to youtube` (saved with `--install`). `--no-youtube` skips the
  YouTube list.

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
4. Получаются два списка: быстрые серверы для `main` и быстрые серверы,
   где YouTube видит `RU` (без рекламы), для секции `youtube` (скрипт
   сам создаёт её со списком YouTube выше `main`). Серверы с пингом от
   700 мс или скоростью до 40 Мбит/с не берутся. В конце: Enter = оба
   списка, 1 = только main, 2 = только YouTube, 3 = другие секции,
   n = ничего.
5. Лог: `/tmp/podkop-probe.log`. Удалить всё: `podkop-probe --uninstall`.
