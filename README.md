# podkop-probe

Check how reliable each of your proxy nodes (VPN keys) really is, right on the
OpenWrt router that runs [podkop](https://github.com/itdoginfo/podkop), and
optionally put the best ones into podkop as a URLTest group.

For every node the script starts a throwaway sing-box on a local port, checks
the exit IP through it, fires a series of requests and reports how many failed
and how fast the rest were.

## Quick start

On the router (SSH), same style as the podkop installer:

```sh
sh <(wget -O - https://github.com/dkagramanyan/podkop-keys-availability-/releases/latest/download/probe.sh)
```

You get a menu:

```
What do you want to do?
  1) Test the nodes podkop uses now
  2) Enter a subscription URL (main key), test all its nodes and
     put the best 10 into podkop as URLTest
  3) Paste links to test
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

## Pick the best nodes from a subscription

If your provider gives you one "main key" (a subscription URL such as
`https://link.example.com/s/XXXX`) with many servers in it:

```sh
podkop-probe -s 'https://link.example.com/s/XXXX'
```

1. The script downloads the subscription (plain or base64). It sends a
   v2ray client User-Agent, so providers return the link list and not a web
   page.
2. It tests every node in it.
3. It ranks them: fewest failures first, then lowest median latency.
4. It shows the best 10 and asks whether to write them into podkop.
   If you say yes, it sets `proxy_config_type=urltest` with those links in
   the `main` section, then restarts podkop. The old config is backed up to
   `/etc/config/podkop.probe-backup.<date>`.

The best links are also saved to `/tmp/podkop-probe-best.txt`.

Fully unattended (e.g. from cron):

```sh
podkop-probe -s 'https://link.example.com/s/XXXX' --top 10 --apply -y
```

## Example output

```
#   verdict            ok  fail%     min  median     p90  exit IP         cc  node
2   GOOD            30/30    0.0   0.182   0.231   0.310  185.x.x.x       DE  Germany-1
4   OK              29/30    3.3   0.201   0.264   0.402  45.x.x.x        NL  Netherlands
1   FLAKY           26/30   13.3   0.340   0.512   1.920  91.x.x.x        FI  Finland
3   DEAD             0/30  100.0       -       -       -  -               -   USA

Summary: 1 good, 2 usable, 1 not working — 14s total
Best node: Germany-1 (#2, median 0.231s)

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
through the node and then does HTTPS to the target.

## Options

```
Sources:
  link ...          vless:// vmess:// trojan:// ss:// hysteria2:// hy2:// links
  -f FILE           file with links, one per line ('-' = stdin, base64 ok)
  -s URL            subscription URL / "main key" (plain or base64 list of links)
  -C FILE           sing-box config.json to take the outbounds from

Test:
  -n N              requests per node               (default 30)
  -c N              requests in flight per node     (default 5)
  -j N              nodes tested at the same time   (default: by free RAM, max 4)
  -t SEC            timeout per request, seconds    (default 10)
  -u URL            target URL                      (default https://www.gstatic.com/generate_204)
  -q                quick run:    -n 10
  -F                thorough run: -n 100 -c 10
  -p PORT           first local SOCKS port          (default 39000)

Podkop (for link sources: -s, -f, links):
  --top N           how many best nodes to offer for podkop   (default 10)
  --apply           write the best nodes to podkop as URLTest and restart it
                    without asking
  --no-apply        never offer to change podkop settings
  --section NAME    podkop section to write to                (default main)

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
- New sources: subscription URLs, and podkop's UCI settings as a fallback.
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

## Русский (кратко)

Запуск на роутере:

```sh
sh <(wget -O - https://github.com/dkagramanyan/podkop-keys-availability-/releases/latest/download/probe.sh)
```

Выберите в меню `2`, вставьте ссылку‑подписку (ваш «основной ключ»). Скрипт
проверит все серверы из подписки и выберет 10 лучших: меньше всего ошибок,
самый низкий пинг. Затем он предложит записать их в podkop как URLTest и
перезапустит podkop. Старый конфиг сохраняется в
`/etc/config/podkop.probe-backup.*`.
