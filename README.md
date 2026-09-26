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
   as `DE,NL,FI` (`--countries`). The country comes from the flag emoji or
   the country/city name in the server name. Servers that are clearly
   outside the choice are not even tested. After the test, the real exit
   country (from the exit IP) is checked too.
3. **Merge.** Nodes from all subscriptions are merged. The same server listed
   in several subscriptions is tested only once.
4. **Ping test.** Every node gets N requests, each over a new connection
   through the node: failures, min / median / p90 time. A node where the
   first round of requests all fail is marked DEAD at once, without waiting
   for the rest to time out.
5. **Speed test.** The 2×10 best-answering nodes download a 10 MB file
   through the node, one at a time so they don't share the router's
   bandwidth.
6. **Ranking.** Nodes with ≤5% failures come first, then ≤20%. Inside each
   group, the order is *latency rank + speed rank*, so a node has to be
   both quick to answer and fast to download to reach the top.
7. **Apply.** The top 10 (`--top N`) are shown, and the script asks before
   writing them into podkop's `main` section as `urltest` and restarting
   podkop. The old config is backed up to
   `/etc/config/podkop.probe-backup.<date>`; the 3 newest backups are kept.

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
2   GOOD            30/30    0.0   0.182   0.231   0.310    87.4  185.x.x.x       DE  Germany-1
4   OK              29/30    3.3   0.201   0.264   0.402    54.0  45.x.x.x        NL  Netherlands
1   FLAKY           26/30   13.3   0.340   0.512   1.920    12.9  91.x.x.x        FI  Finland
3   DEAD             0/30  100.0       -       -       -       -  -               -   USA

Summary: 1 good, 2 usable, 1 not working — 41s total
Best node: Germany-1 (#2, median 0.231s, 87.4 Mbit/s)

Problems:
  #3   USA: all 30 requests failed: node unreachable, blocked, or wrong credentials
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
                    europe, all (default), or codes like DE,NL,FI

Test:
  -n N              requests per node               (default 30)
  -c N              requests in flight per node     (default 5)
  -j N              nodes tested at the same time   (default: by free RAM, max 4)
  -t SEC            timeout per request, seconds    (default 10)
  -u URL            target URL                      (default https://www.gstatic.com/generate_204)
  -q                quick run:    -n 10
  -F                thorough run: -n 100 -c 10
  -p PORT           first local SOCKS port          (default 39000)
  --no-speed        skip the download speed test
  --speed-url URL   file for the speed test (default: 10 MB from Cloudflare)

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
