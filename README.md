# podkop-probe

Check how reliable and fast each of your proxy nodes (VPN keys) really is,
right on the OpenWrt router that runs [podkop](https://github.com/itdoginfo/podkop).
The script can put the best ones into podkop as a URLTest group, once or
every night.

For every node the script starts a throwaway sing-box on a local port, checks
the exit IP through it, fires a series of requests and reports how many failed
and how fast the rest were.

## Quick start

On the router (SSH), same style as the podkop installer:

```sh
sh <(wget -O - https://github.com/dkagramanyan/podkop-keys-availability-/releases/latest/download/probe.sh)
```

Or straight from the `main` branch (no release needed):

```sh
sh <(wget -O - https://raw.githubusercontent.com/dkagramanyan/podkop-keys-availability-/main/probe.sh)
```

You get a menu:

```
What do you want to do?
  1) Test the nodes podkop uses now
  2) Enter one or more subscription URLs (main keys), test all their
     nodes and put the best 10 by ping and speed into podkop (URLTest)
  3) Paste links to test
  4) Nightly auto-update: off
  q) Quit
```

Everything else is asked or detected by the script. It checks the
dependencies and offers to install any that are missing, finds podkop's
config, and explains every problem it finds.

Options can be passed after the one-liner too:

```sh
sh <(wget -O - https://github.com/dkagramanyan/podkop-keys-availability-/releases/latest/download/probe.sh) -q
```

Or keep a copy on the router:

```sh
wget -O /usr/bin/podkop-probe https://github.com/dkagramanyan/podkop-keys-availability-/releases/latest/download/probe.sh
chmod +x /usr/bin/podkop-probe
podkop-probe -h
```

## Pick the best nodes from your subscriptions

Your provider may give you one or more "main keys": subscription URLs such
as `https://link.example.com/s/XXXX`, each with many servers inside. Choose
menu item `2` and paste them, one per line or space-separated. Or use the
command line:

```sh
podkop-probe -s 'https://link.example.com/s/AAAA' -s 'https://other.example/sub/BBBB'
```

1. **Download, like your VPN app does.** Subscription panels (Remnawave,
   Marzban, 3x-ui…) give the real server list only to apps they know.
   Anything else gets a fake "App not supported" entry. So the script asks
   the way Happ, Streisand, INCY, v2RayTun, v2rayNG, Hiddify and sing-box
   do, in that order, until real servers come back.
   - Answers can be a base64 or plain list of links, or xray / sing-box
     JSON; all three are converted to links. A plain list wins because it
     carries the provider's own server names ("🇩🇪 Германия #1"); many
     panels send Happ/Streisand/INCY an xray JSON with "Автоматический"
     balancer groups instead.
   - The profile name, traffic used and expiry date sent by the panel are
     shown.
   - Servers using the `xhttp` transport are skipped: sing-box, and so
     podkop, can't run them. Their tcp/grpc twins are tested.
   - Fake entries ("App not supported", "30 days left", 0.0.0.0 servers…)
     are dropped.
   - A subscription that still fails is skipped with the reason; the others
     are still used.
2. **Countries.** You choose "Europe only", all countries, or a list such
   as `DE,NL,FI` (`--countries`). A server is kept only if all three
   checks agree:
   - **the name:** flag emoji or country/city name;
   - **the server's IP,** i.e. where you connect to. The domain is
     resolved via public DNS and the IP looked up on ipinfo.io. This drops
     relays such as "Германия через 🇷🇺", whose entry point is in Russia.
     Servers behind a CDN like Cloudflare are left to the other two checks
     (`--no-entry-check` turns this check off);
   - **the exit IP,** after the test.

   Servers failing the first two checks are not even tested.
3. **Merge.** Nodes from all subscriptions are merged. The same server listed
   in several subscriptions is tested only once.
4. **Check every node:**
   - **Latency, 4 nodes at a time:** 40 requests (4 at a time) per node,
     each over a new connection through the node. The script records the
     failures and the min / median / p90 time. These are tiny requests, so
     nodes tested side by side don't disturb each other.
     - If the first round all fail, the node is DEAD at once.
     - A node that has lost more than 30% by half-way stops early: it's
       BAD either way.
   - **Speed, after all latency tests:** every node that lost at most 20%
     downloads through itself. First the script measures your line
     directly (5 s from Hetzner), then runs one test per ~200 Mbit/s of
     line at a time, up to 3 (`--speed-jobs N` to set it). On a 700 Mbit/s
     line that's 3 at once; on a 100 Mbit/s line, 1. The file is
     Cloudflare's speed-test file (25 MB, repeated as needed), or Hetzner's
     if Cloudflare refuses. Your provider blocking Cloudflare doesn't
     matter here: this download always goes through the VLESS node, never
     directly.
     - The running average is checked every second. The test stops once
       it has settled (changed <3% twice in a row, after at least 3 s) or
       after 8 s, which is usually 4–5 s.
     - Links to the same server, port and transport (e.g. "Германия #1"
       and "Германия #1 (для iOS)") share one speed test.
     - If the download fails, the HTTP code is shown under *Problems*.
5. **Ranking.** Nodes that lost ≤5% come first, then ≤20%. Inside each
   group:
   *score = median latency ÷ best median + best speed ÷ this speed*.
   2.0 would be best at both; lower is better. 20% more latency weighs the
   same as 20% less speed.
6. **Your choice.** The top 10 (`--top N`) are proposed, one link per
   server (exit IP) where possible: "Польша #2" and "Польша #2 GRPC" are
   the same machine and would waste a slot. The picks are marked `*` in
   the table. Press Enter to take them, or type the `#` numbers you want
   instead.
7. **Apply.** The script asks before writing them into podkop's `main`
   section as `urltest` and restarting podkop. The old config is backed up
   to `/etc/config/podkop.probe-backup.<date>`; the 3 newest backups are
   kept.

40 nodes take about 2–3 minutes on a fast line. `-q` does a quick run (12 requests,
at most 4 s of speed test).

The best links are also saved to `/tmp/podkop-probe-best.txt`.

### A subscription gives no servers?

Check what it returns to each app. This runs on a Mac or Linux, prints no
secrets (no UUIDs, keys or passwords; server addresses show only as
`ip`/`domain`), so the output is safe to share:

```sh
curl -fsSL https://raw.githubusercontent.com/dkagramanyan/podkop-keys-availability-/main/tools/sub-check.sh -o /tmp/sub-check.sh
bash /tmp/sub-check.sh 'https://your-subscription-url' 'https://another-one'
```

On the router, `podkop-probe -v -s URL` saves the raw answer to
`/tmp/podkop-probe-sub1.txt`.

## Every night, automatically

After step 6 the script asks *"Do this automatically every night?"* and the
time to run (default 04:00). Menu item `4` shows the current state and lets
you change or turn it off. From the command line:

```sh
podkop-probe -s 'https://link.example.com/s/AAAA' -s 'https://other.example/sub/BBBB' --top 10 --nightly 04:00
podkop-probe --nightly-off
```

Setting it up does four things:
- installs the script as `/usr/bin/podkop-probe`;
- saves the subscriptions and settings to `/etc/podkop-probe.conf`
  (plain shell variables, edit freely);
- adds `podkop-probe --cron` to root's crontab and enables cron;
- adds both files to `/etc/sysupgrade.conf`, so they survive a firmware
  upgrade.

Each night the job re-downloads the subscriptions, re-tests everything and
writes the new top list into podkop. Details:
- If the list is the same as what podkop already uses, nothing is restarted.
- If no node works (for example the internet is down), podkop is left alone.
- The last run is logged to `/tmp/podkop-probe.log`, and applied changes go
  to the system log (`logread -e podkop-probe`).
- Run it by hand at any time: `podkop-probe --cron`.

## Example output

```
  #   verdict            ok  fail%     min  median     p90  Mbit/s  exit IP         cc  node
* 44  GOOD            40/40    0.0   0.154   0.278   0.409    97.1  212.x.x.x       LT  🇱🇹 Литва GRPC
* 35  GOOD            40/40    0.0   0.180   0.255   0.447    74.3  213.x.x.x       FR  🇫🇷 Франция GRPC
* 2   GOOD            40/40    0.0   0.182   0.231   0.310    87.4  185.x.x.x       DE  Germany-1
  1   GOOD            40/40    0.0   0.301   0.539   2.466    68.6  185.x.x.x       DE  Germany-1 TCP
  4   OK              39/40    2.5   0.201   0.264   0.402    54.0  45.x.x.x        NL  Netherlands
  5   BAD              9/20   55.0   0.269   0.474   0.883       -  77.x.x.x        DE  Germany via RU
  3   DEAD              0/4  100.0       -       -       -       -  -               -   USA

Summary: 4 good, 1 usable, 2 not working — 95s total
Best node: Germany-1 (#2, median 0.231s, 87.4 Mbit/s)

Problems:
  #3   USA: all 4 requests failed: node unreachable, blocked, or wrong credentials
```

| verdict        | meaning                                                         |
|----------------|-----------------------------------------------------------------|
| `GOOD`         | no failed requests                                              |
| `OK`           | up to 5% failed                                                 |
| `FLAKY`        | up to 20% failed                                                |
| `BAD`          | more than 20% failed                                            |
| `DEAD`         | nothing got through                                             |
| `NOT VIA NODE` | exit IP equals the router's own IP, so the result is void       |
| `NO START`     | sing-box refused the node's config (reason under *Problems*)    |
| `SKIPPED`      | the link can't be used by sing-box (e.g. `xhttp` transport)      |

Times are seconds for one full request. Each request opens a new connection
through the node and then does HTTPS to the target. `Mbit/s` is the download
speed through the node; `-` means it was not measured, `0.0` means the
download failed.

## Options

```
Sources:
  link ...          vless:// vmess:// trojan:// ss:// hysteria2:// hy2:// links
  -f FILE           file with links, one per line ('-' = stdin, base64 ok)
  -s URL            subscription URL / "main key" (plain or base64 list of
                    links); repeat -s for several
  -C FILE           sing-box config.json to take the outbounds from
  --countries LIST  test/choose only servers in these countries:
                    europe, all (default), or codes like DE,NL,FI; checked
                    by name, by the server's IP and by the exit IP
  --no-entry-check  don't look up the server's IP country (keeps relays
                    whose entry point is elsewhere, e.g. "via RU")

Test:
  -n N              requests per node               (default 40)
  -c N              requests in flight per node     (default 4)
  -j N              nodes latency-tested at the same time (default 4, less
                    with little free RAM); speed tests always run one at a time
  -t SEC            timeout per request, seconds    (default 8)
  -u URL            target URL                      (default https://www.gstatic.com/generate_204)
  -q                quick run:    -n 12, 4 s speed test
  -F                thorough run: -n 100, 15 s speed test
  -p PORT           first local SOCKS port          (default 39000)
  --no-speed        skip the download speed test
  --speed-jobs N    speed tests at the same time (default: from the line
                    speed, 1 per ~200 Mbit/s, max 3)
  --speed-url URL   file for the speed test (default: Cloudflare, then Hetzner)

Podkop (for link sources: -s, -f, links):
  --top N           how many best nodes to offer for podkop   (default 10)
  --apply           write the best nodes to podkop as URLTest and restart it
                    without asking
  --no-apply        never offer to change podkop settings
  --section NAME    podkop section to write to                (default main)

Nightly auto-update (OpenWrt cron):
  --nightly HH:MM   every night re-test the -s subscriptions and put the best
                    --top nodes into podkop; installs /usr/bin/podkop-probe
                    and saves the settings to /etc/podkop-probe.conf
  --nightly-off     turn the nightly job off

Output:
  -o FILE           also save results as CSV
  -v                verbose: per-request timings and sing-box errors
  -y                answer "yes" to questions (install missing packages)
  --no-color        plain output
```

With no arguments and no terminal (cron, scripts), nodes are taken from podkop
automatically. The script reads podkop's generated sing-box config
(`/etc/sing-box/config.json`, which covers every protocol podkop supports),
and falls back to the links stored in `/etc/config/podkop`.

## Requirements

- OpenWrt with podkop installed (that already provides `sing-box`, `curl`
  and `jq`). Without podkop, the script offers to install the missing
  packages with `opkg` or `apk`.
- `jq` is needed only for `-C`/podkop config and `vmess://` links.
- BusyBox `ash` is enough; no bash needed.

## What changed compared with the original probe.sh

- Downloadable and runnable with one command. Interactive menu, and no
  arguments are required.
- New sources: any number of subscription URLs (merged and de-duplicated),
  and podkop's UCI settings as a fallback.
- Download speed test, and ranking by ping and speed together.
- Nightly auto-update through cron.
- New protocols: `trojan://`, `ss://` (SIP002 and legacy, plugins),
  `vmess://`, `hysteria2://`, plus ws early data and `quic` transport.
- Best nodes can be written to podkop as a URLTest group, followed by a
  podkop restart (with backup).
- Faster:
  - one `curl` process per node runs all requests in parallel (`curl -Z`),
    where the original started N curl processes;
  - the exit-IP check runs at the same time as the requests;
  - sing-box readiness is polled every 0.2s instead of 1s, and a crashed
    sing-box is noticed at once, not after a 30s wait;
  - a sliding pool of nodes (FIFO semaphore), where the original waited for
    the whole batch;
  - each link is parsed in a single `awk` pass, where the original used
    ~26 forks per link;
  - podkop's config is read with one `jq` call, where the original used 2
    per outbound.
- More reliable results:
  - `Connection: close` forces a new tunnel for every request, so the test
    measures node failures and not keep-alive reuse;
  - `--noproxy ''` makes sure `NO_PROXY` can't bypass the node;
  - `domain_resolver` and `detour` references are removed when a node is
    copied out of podkop's config, so it starts on its own;
  - `-j` is chosen from free RAM.
- Better report: verdicts, fail %, min/median/p90, exit country, sorted
  table, a *Problems* section in plain words, the best node, and CSV export.

## Making a release

Bump `VERSION=` in `probe.sh` and merge to `main`. The **release** workflow
lints the script and publishes `probe.sh` as release `v<VERSION>`. It does
this automatically whenever a push to `main` changes `probe.sh` and that
version has no release yet. It can also run from a pushed `v*` tag, or by
hand from the Actions tab. The
`releases/latest/download/probe.sh` link always points to the newest one.

## Русский (кратко)

Запуск на роутере:

```sh
sh <(wget -O - https://github.com/dkagramanyan/podkop-keys-availability-/releases/latest/download/probe.sh)
```

Выберите в меню `2` и вставьте одну или несколько ссылок‑подписок (ваши
«основные ключи»). Скрипт проверит все серверы из всех подписок и выберет 10
лучших: меньше всего ошибок, затем пинг и скорость вместе. Он предложит
записать их в podkop как URLTest и перезапустит podkop. Старый конфиг
сохраняется в `/etc/config/podkop.probe-backup.*`.

Затем скрипт спросит, повторять ли это каждую ночь, и во сколько (по
умолчанию 04:00). Состояние ночного обновления видно в пункте меню `4`, там
же его можно изменить или выключить. Из командной строки:

```sh
podkop-probe -s 'https://…/AAAA' -s 'https://…/BBBB' --nightly 04:00   # включить
podkop-probe --nightly-off                                            # выключить
```
