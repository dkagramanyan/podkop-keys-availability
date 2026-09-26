# podkop-probe

Finds the fastest and most reliable servers in your VPN subscriptions
("main keys"), right on your OpenWrt router, and puts the best ones into
[podkop](https://github.com/itdoginfo/podkop). It can repeat this every
night.

You need an OpenWrt router with podkop already installed.

---

## Guide 1: first run (about 5 minutes)

**1. Connect to the router.** On a Mac, Linux or Windows computer, open a
terminal (on Windows: PowerShell) and type:

```sh
ssh root@192.168.1.1
```

Use your router's address if it isn't `192.168.1.1`, and the router
password when asked.

**2. Start the script:**

```sh
sh <(wget -O - https://github.com/dkagramanyan/podkop-keys-availability-/releases/latest/download/probe.sh)
```

**3. Answer its questions:**

| It asks | You do |
|---|---|
| `What do you want to do?` | type `2`, press Enter |
| `Paste subscription URLs` | paste your keys (the links you import into Happ / Streisand / INCY), one per line, then press Enter on an empty line |
| `Which servers?` | press Enter for **Europe only** (or `2` for all countries) |

**4. Wait 2–4 minutes.** Every server is tested for lost requests, latency
and download speed. At the end you see a table. The servers marked `*` are
the proposed top 10:

```
  #   verdict            ok  fail%     min  median     p90  Mbit/s  exit IP         cc  node
* 50  GOOD            40/40    0.0   0.148   0.239   0.449   137.4  212.x.x.x       LT  🇱🇹 Литва GRPC
* 41  GOOD            40/40    0.0   0.180   0.230   0.410   122.0  213.x.x.x       FR  🇫🇷 Франция GRPC
  12  GOOD            40/40    0.0   0.161   0.209   0.431     7.8  77.x.x.x        DE  🇩🇪 Германия #2 GRPC
  22  DEAD              0/4  100.0       -       -       -       -  -               AT  🇦🇹 Австрия
```

**5. Choose.**
- Press Enter to take the proposed 10, or type the `#` numbers you prefer
  (e.g. `50 41 35`).
- Press Enter again (or `y`) to put them into podkop.
- The script sets podkop to **URLTest** with those servers and restarts it.
  Your old podkop settings are backed up first (see Guide 3).

**6. Keep the line it prints at the end.** You need it for Guide 2.

---

## Guide 2: update every night at 04:30

At the end of Guide 1 the script prints a line like this:

```
30 4 * * * wget -q -O /tmp/podkop-probe.sh https://github.com/.../probe.sh && sh /tmp/podkop-probe.sh --cron -s 'https://your-key-1' -s 'https://your-key-2' --countries 'europe' > /tmp/podkop-probe.log 2>&1
```

1. Open LuCI in the browser (`http://192.168.1.1`).
2. Go to **System → Scheduled Tasks**.
3. Paste the line on a new line and click **Save**.
4. Go to **System → Startup**. Make sure **cron** is *Enabled*, and click
   **Restart** next to it.
5. Check **System → System → Timezone**. 04:30 is the router's local time.

That's it. Every night at 04:30 the router downloads the latest version,
tests your keys again and puts the new top 10 into podkop. If the top 10 is
the same as before, podkop is not restarted. If nothing works (e.g. the
internet is down), podkop is left alone.

- **Want a different time?** The first two numbers are minutes and hours:
  `0 3 * * *` is 03:00.
- **Want to get the line again, or for other keys?** Run the script
  (Guide 1, step 2) and choose menu item `4`.
- **Did last night's run work?** SSH in and run
  `cat /tmp/podkop-probe.log`, or look in **Status → System Log** for
  `podkop-probe`.
- **Want to test it right now?** Copy the part of the line after
  `30 4 * * * ` and run it over SSH.
- **Want to stop it?** Delete the line in **System → Scheduled Tasks** and
  click Save.

> Used the nightly option of version 1.5 or older? Remove the old job once
> with:
> `sh <(wget -O - https://github.com/dkagramanyan/podkop-keys-availability-/releases/latest/download/probe.sh) --nightly-off`

---

## Guide 3: undo the change to podkop

Before changing podkop, the script saves a copy of its settings (the 3
newest are kept). To go back:

```sh
ls /etc/config/podkop.probe-backup.*
cp /etc/config/podkop.probe-backup.<date> /etc/config/podkop
/etc/init.d/podkop restart
```

---

## Reading the results

| verdict | meaning |
|---|---|
| `GOOD` | nothing lost |
| `OK` | up to 5% lost |
| `FLAKY` | up to 20% lost |
| `BAD` | more than 20% lost; never chosen |
| `DEAD` | nothing gets through |
| `SKIPPED` | can't run in podkop (e.g. the `xhttp` transport) |
| `OTHER REGION` | exits outside the countries you chose |
| `NOT VIA NODE` | traffic didn't go through the server; the result is void |
| `NO START` | the server's settings were rejected (reason under *Problems*) |

- **median / p90:** seconds per request (new connection through the server
  plus a small HTTPS request). Lower is better.
- **Mbit/s:** download speed through the server.
- **Problems:** at the end, in plain words, e.g. why a speed test failed.

## How the top 10 is chosen

1. Only servers in the countries you chose. The script checks three
   things: the flag or name, the IP you connect to, and the IP the traffic
   exits from. So relays "через 🇷🇺" (entry point in Russia) are left out
   of "Europe only".
2. Servers that lost more than 5% of requests come after the others; more
   than 20% are never chosen.
3. Then the best **latency and speed together**. 20% slower latency
   counts as much as 20% less speed.
4. At most one link per real server where possible. "Польша #2" and
   "Польша #2 GRPC" are the same machine.

Speed tests always go through the VPN server. So it doesn't matter if your
provider blocks Cloudflare directly.

## Troubleshooting

- **"subscription … gives no servers"**
  - The script tells you why.
  - To see what the key returns to each app, run this on a Mac or Linux
    computer. It prints no secrets.
    ```sh
    curl -fsSL https://raw.githubusercontent.com/dkagramanyan/podkop-keys-availability-/main/tools/sub-check.sh -o /tmp/sub-check.sh
    bash /tmp/sub-check.sh 'https://your-key'
    ```
- **A server shows `Mbit/s 0.0`:** the reason is listed under *Problems*.
- **It's too slow:** add `-q` for a quick check (fewer requests, shorter
  speed test).
- **Several keys at once:** paste them all in step 3. Duplicates across
  keys are tested only once.

## All options

<details>
<summary>Show</summary>

```
Sources:
  link ...          vless:// vmess:// trojan:// ss:// hysteria2:// hy2:// links
  -f FILE           file with links, one per line ('-' = stdin, base64 ok)
  -s URL            subscription URL / "main key"; repeat -s for several
  -C FILE           sing-box config.json to take the outbounds from
  --countries LIST  europe, all (default), or codes like DE,NL,FI; checked
                    by name, by the server's IP and by the exit IP
  --no-entry-check  don't look up the server's IP country

Test:
  -n N              requests per node               (default 40)
  -c N              requests in flight per node     (default 4)
  -j N              nodes latency-tested at the same time (default 4)
  -t SEC            timeout per request, seconds    (default 8)
  -u URL            target URL                      (default https://www.gstatic.com/generate_204)
  -q                quick run:    -n 12, 4 s speed test
  -F                thorough run: -n 100, 15 s speed test
  -p PORT           first local SOCKS port          (default 39000)
  --no-speed        skip the download speed test
  --speed-jobs N    speed tests at the same time (default: from the line
                    speed, 1 per ~200 Mbit/s, max 3)
  --speed-url URL   file for the speed test (default: Cloudflare, then Hetzner)

Podkop:
  --top N           how many best nodes to offer    (default 10)
  --apply           put them into podkop without asking
  --no-apply        never offer to change podkop settings
  --section NAME    podkop section to write to      (default main)

Nightly run:
  --cron-line HH:MM print the line for LuCI -> System -> Scheduled Tasks
  --cron            unattended run (used by that line)
  --nightly-off     remove the nightly job of versions <= 1.5

Output:
  -o FILE           also save results as CSV
  -v                verbose: per-request timings, sing-box errors
  -y                answer "yes" to questions
  --no-color        plain output
```

</details>

Without a terminal and without `-s`, the script tests the servers podkop
uses now.

---

## Русский: коротко

**1. Первый запуск.** Подключитесь к роутеру (`ssh root@192.168.1.1`) и
выполните:

```sh
sh <(wget -O - https://github.com/dkagramanyan/podkop-keys-availability-/releases/latest/download/probe.sh)
```

- Выберите `2`.
- Вставьте ваши ключи-подписки (по одному в строке), затем нажмите Enter
  на пустой строке.
- Нажмите Enter, чтобы оставить «только Европа».

Через 2–4 минуты появится таблица, а лучшие 10 серверов будут отмечены
`*`. Нажмите Enter, чтобы их взять, или впишите свои номера. Затем Enter
ещё раз: серверы запишутся в podkop как URLTest, и podkop перезапустится.
Старые настройки сохраняются в `/etc/config/podkop.probe-backup.*`.

**2. Каждую ночь в 04:30.** В конце скрипт печатает строку вида
`30 4 * * * wget ... --cron -s '...'`.

- Вставьте её в LuCI: **Система → Планировщик**, затем «Сохранить».
- В **Система → Загрузка** включите `cron` и перезапустите его.
- Лог последнего запуска: `/tmp/podkop-probe.log`.
- Чтобы отключить, удалите строку в планировщике.

**Откат:**

```sh
cp /etc/config/podkop.probe-backup.<дата> /etc/config/podkop && /etc/init.d/podkop restart
```
