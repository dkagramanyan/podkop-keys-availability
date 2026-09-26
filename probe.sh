#!/bin/sh
# shellcheck shell=dash disable=SC1090,SC2012,SC2016,SC2018,SC2019,SC2046,SC2154,SC2317
#
# podkop-probe — measure how reliable every proxy node is, right on the
# OpenWrt router that runs podkop (https://github.com/itdoginfo/podkop).
#
# For each node: start a throwaway sing-box on a local SOCKS port, confirm the
# exit IP through the node, fire N requests, count failures, report latency.
#
# One-liner (on the router):
#   sh <(wget -O - https://github.com/dkagramanyan/podkop-keys-availability-/releases/latest/download/probe.sh)
#
# https://github.com/dkagramanyan/podkop-keys-availability-

VERSION="1.5.0"
REPO_URL="https://github.com/dkagramanyan/podkop-keys-availability-"
SELF_URLS="$REPO_URL/releases/latest/download/probe.sh
https://raw.githubusercontent.com/dkagramanyan/podkop-keys-availability-/main/probe.sh"
BIN=/usr/bin/podkop-probe
CONF=/etc/podkop-probe.conf
CRONTAB=/etc/crontabs/root
PODKOP_INSTALL="sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh)"

set -u
export LC_ALL=C

N=40; C=4; J=""; T=8
URL="https://www.gstatic.com/generate_204"
BASEPORT=39000
FILE=""; SUBS=""; CONFIG=""; CSV=""
VERBOSE=0; ASSUME_YES=0; COLOR=auto; SOURCE=""
TOP=10; APPLY=ask; SECTION=main
SPEED=1; SPEED_URL=""; SPEED_T=8; SPEED_J=""; ENTRY_CHECK=1
# direct download used to measure the router's own line (not Cloudflare,
# which some providers block without a VPN)
LINE_URL="https://fsn1-speed.hetzner.com/100MB.bin"
# speed test files, tried in order; a file that ends early is fetched again
# until SPEED_T is used up (Cloudflare refuses single requests of 100 MB)
SPEED_URLS="https://speed.cloudflare.com/__down?bytes=25000000
https://fsn1-speed.hetzner.com/100MB.bin"
NIGHTLY=""; NIGHTLY_OFF=0; CRON=0
COUNTRIES=all
# Subscription panels (Remnawave, Marzban, 3x-ui...) only hand the real server
# list to client apps they know, so we introduce ourselves like those apps.
UA="Happ/3.9.0"
SUB_UAS="Happ/3.9.0
Streisand/2.3.1
INCY/1.2.0
v2RayTun/5.12.0
Hiddify/2.5.7
sing-box/1.12.0
v2rayNG/1.10.2"
EUROPE="EU AD AL AT BA BE BG CH CY CZ DE DK EE ES FI FR GB GR HR HU IE IS IT LI LT LU LV MC MD ME MK MT NL NO PL PT RO RS SE SI SK SM UA VA XK"
ARGLINKS=""
WORK="/tmp/podkop-probe.$$"
TAB=$(printf '\t')
LINK_RE='(vless|vmess|trojan|ss|hysteria2|hy2)://[^[:space:]"<>'"'"']+'

usage() {
  cat <<EOF
podkop-probe $VERSION — per-node reliability test for podkop / sing-box

Usage: sh probe.sh [options] [link ...]

With no arguments you get a menu: test podkop's current nodes, or enter
one or more subscription URLs ("main keys"), test every node in them, pick
the best by ping and speed and put them into podkop as a URLTest group,
optionally every night. Without a terminal the nodes are taken from podkop
automatically (its sing-box config or /etc/config/podkop).

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
  -n N              requests per node               (default $N)
  -c N              requests in flight per node     (default $C)
  -j N              nodes tested at the same time   (default 1: one at a time,
                    so tests don't share the line; speed tests always are)
  -t SEC            timeout per request, seconds    (default $T)
  -u URL            target URL                      (default $URL)
  -q                quick run:    -n 12, 4 s speed test
  -F                thorough run: -n 100, 15 s speed test
  -p PORT           first local SOCKS port          (default $BASEPORT)
  --no-speed        skip the download speed test
  --speed-jobs N    speed tests at the same time (default: from the line
                    speed, 1 per ~200 Mbit/s, max 3)
  --speed-url URL   file for the speed test (default: Cloudflare, then Hetzner)

Podkop (for link sources: -s, -f, links):
  --top N           how many best nodes to offer for podkop   (default $TOP)
  --apply           write the best nodes to podkop as URLTest and restart it
                    without asking
  --no-apply        never offer to change podkop settings
  --section NAME    podkop section to write to                (default $SECTION)

Nightly auto-update (OpenWrt cron):
  --nightly HH:MM   every night re-test the -s subscriptions and put the best
                    --top nodes into podkop; installs $BIN
                    and saves the settings to $CONF
  --nightly-off     turn the nightly job off

Output:
  -o FILE           also save results as CSV
  -v                verbose: per-request timings and sing-box errors
  -y                answer "yes" to questions (install missing packages)
  --no-color        plain output
  -V, --version     print version
  -h, --help        this help

Examples:
  sh probe.sh                              # test podkop's own nodes
  sh probe.sh -q                           # fast check, 10 requests per node
  sh probe.sh -s https://example.com/sub   # test a subscription, offer best 10
  sh probe.sh -s https://a.example/sub -s https://b.example/sub --top 5 --apply -y
  sh probe.sh -s https://a.example/sub -s https://b.example/sub --nightly 04:00
  sh probe.sh 'vless://...#de' 'trojan://...#nl'
EOF
  exit "${1:-0}"
}

# --- output helpers ----------------------------------------------------------

setup_color() {
  if [ "$COLOR" = auto ]; then [ -t 1 ] && COLOR=1 || COLOR=0; fi
  if [ "$COLOR" = 1 ]; then
    E=$(printf '\033'); R0="${E}[0m"; BD="${E}[1m"; DM="${E}[2m"
    RD="${E}[31m"; GR="${E}[32m"; YL="${E}[33m"; CY="${E}[36m"
  else
    R0=""; BD=""; DM=""; RD=""; GR=""; YL=""; CY=""
  fi
}
R0=""; BD=""; DM=""; RD=""; GR=""; YL=""; CY=""

info() { printf '%s==>%s %s\n' "$CY$BD" "$R0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YL$BD" "$R0" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RD$BD" "$R0" "$*" >&2; exit 1; }

TTY=""
if (exec </dev/tty) 2>/dev/null; then TTY=/dev/tty; fi

ask_yn() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -n "$TTY" ] || return 1
  printf '%s?%s %s [Y/n] ' "$YL$BD" "$R0" "$1" >&2
  read -r _a < "$TTY" || return 1
  case "$_a" in ""|y|Y|yes|Yes|д|Д|да) return 0 ;; *) return 1 ;; esac
}

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -gt 0 ]; }

# --- arguments ---------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    -f|-s|-C|--config|-n|-c|-j|-t|-u|-p|-o|--top|--section|--speed-url|--nightly|--countries|--speed-jobs)
      [ $# -ge 2 ] || { echo "option $1 needs a value" >&2; usage 1; }
      case "$1" in
        -f) FILE="$2" ;; -s) SUBS="$SUBS$2
" ;; -C|--config) CONFIG="$2" ;;
        -n) N="$2" ;; -c) C="$2" ;; -j) J="$2" ;; -t) T="$2" ;;
        -u) URL="$2" ;; -p) BASEPORT="$2" ;; -o) CSV="$2" ;;
        --top) TOP="$2" ;; --section) SECTION="$2" ;;
        --speed-url) SPEED_URL="$2" ;; --nightly) NIGHTLY="$2" ;;
        --speed-jobs) SPEED_J="$2" ;;
        --countries) COUNTRIES="$2" ;;
      esac
      shift 2 ;;
    -q) N=12; SPEED_T=4; shift ;;
    -F) N=100; SPEED_T=15; shift ;;
    -v) VERBOSE=1; shift ;;
    -y) ASSUME_YES=1; shift ;;
    --apply) APPLY=yes; shift ;;
    --no-apply) APPLY=no; shift ;;
    --no-speed) SPEED=0; shift ;;
    --no-entry-check) ENTRY_CHECK=0; shift ;;
    --nightly-off) NIGHTLY_OFF=1; shift ;;
    --cron) CRON=1; shift ;;
    --no-color) COLOR=0; shift ;;
    -V|--version) echo "podkop-probe $VERSION"; exit 0 ;;
    -h|--help) usage 0 ;;
    *://*) ARGLINKS="$ARGLINKS$1
"; shift ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
done

# nightly run from cron: settings come from the saved config
if [ "$CRON" = 1 ]; then
  [ -f "$CONF" ] || { echo "no $CONF, nothing to do" >&2; exit 1; }
  . "$CONF"
  ASSUME_YES=1; APPLY=yes; COLOR=0; TTY=""
  case "$SPEED_URL" in *speed.cloudflare.com/__down*) SPEED_URL="" ;; esac   # old defaults
fi

for _v in N C T BASEPORT TOP; do
  eval "_x=\$$_v"; is_uint "$_x" || die "$_v must be a positive number, got '$_x'"
done
[ -z "$J" ] || is_uint "$J" || die "-j must be a positive number"
[ -z "$SPEED_J" ] || is_uint "$SPEED_J" || die "--speed-jobs must be a positive number"
[ "$C" -le "$N" ] || C=$N

setup_color

# --- dependencies ------------------------------------------------------------

pkg_install() {
  if command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1; apk add "$@"
  elif command -v opkg >/dev/null 2>&1; then
    opkg update >/dev/null 2>&1; opkg install "$@"
  else
    return 1
  fi
}

# need_tool <cmd> <package> <why>
need_tool() {
  command -v "$1" >/dev/null 2>&1 && return 0
  if ask_yn "'$1' is not installed ($3). Install package '$2' now"; then
    info "installing $2 ..."
    pkg_install "$2" >&2
    command -v "$1" >/dev/null 2>&1 && return 0
    warn "could not install $2"
  fi
  return 1
}

# --- small utilities ---------------------------------------------------------

# base64 decode from stdin; url-safe alphabet and missing padding are fine
b64d() {
  tr -d ' \r\n\t' | tr '_-' '/+' |
    awk '{ n = length($0) % 4; if (n == 2) $0 = $0 "=="; else if (n == 3) $0 = $0 "="; printf "%s", $0 }' |
    { base64 -d 2>/dev/null || openssl base64 -d -A 2>/dev/null; }
}

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 30 -A "$UA" "$1"
  else
    wget -q -U "$UA" -O - "$1"
  fi
}

# --- subscriptions -----------------------------------------------------------

# xray / sing-box JSON subscription -> share links (needs jq)
JSON2LINKS='
def enc: tostring | @uri;
def kv(k; v): if (v // "" | tostring) == "" then empty else "\(k)=\(v | enc)" end;
def hp(a; p): (if (a | tostring | test(":")) then "[\(a)]" else "\(a)" end) + ":\(p)";
def xq(s): [kv("type"; s.network // "tcp"), kv("security"; s.security // "none"),
  kv("sni"; s.realitySettings.serverName // s.tlsSettings.serverName),
  kv("fp"; s.realitySettings.fingerprint // s.tlsSettings.fingerprint),
  kv("pbk"; s.realitySettings.publicKey), kv("sid"; s.realitySettings.shortId),
  kv("alpn"; (s.tlsSettings.alpn // []) | join(",")),
  kv("path"; s.wsSettings.path // s.httpupgradeSettings.path // s.xhttpSettings.path),
  kv("host"; s.wsSettings.headers.Host // s.wsSettings.host // s.httpupgradeSettings.host // s.xhttpSettings.host),
  kv("serviceName"; s.grpcSettings.serviceName)];
def sq(o): [kv("type"; o.transport.type // "tcp"),
  kv("security"; if o.tls.reality.enabled then "reality" elif o.tls.enabled then "tls" else "none" end),
  kv("sni"; o.tls.server_name), kv("fp"; o.tls.utls.fingerprint),
  kv("pbk"; o.tls.reality.public_key), kv("sid"; o.tls.reality.short_id),
  kv("alpn"; (o.tls.alpn // []) | join(",")),
  kv("path"; o.transport.path), kv("host"; o.transport.headers.Host // o.transport.host),
  kv("serviceName"; o.transport.service_name)];
(if type == "array" then .[] else . end) | select(type == "object") | (.remarks // "") as $rem
| ([.outbounds[]? | select(type == "object" and ((.protocol // .type) | tostring | test("^(vless|trojan|shadowsocks|hysteria2)$")))] | length) as $np
| .outbounds[]? | select(type == "object")
| ($rem + (if $np > 1 and ((.tag // "proxy") | test("^proxy$") | not) then " [\(.tag)]" else "" end)) as $name
| if .protocol == "vless" then .settings.vnext[0] as $v | $v.users[0] as $u
    | "vless://\($u.id)@\(hp($v.address; $v.port))?" + (xq(.streamSettings // {}) + [kv("flow"; $u.flow), "encryption=none"] | join("&")) + "#" + ($name | enc)
  elif .protocol == "trojan" then .settings.servers[0] as $v
    | "trojan://\($v.password | enc)@\(hp($v.address; $v.port))?" + (xq(.streamSettings // {}) | join("&")) + "#" + ($name | enc)
  elif .protocol == "shadowsocks" then .settings.servers[0] as $v
    | "ss://" + ("\($v.method):\($v.password)" | @base64) + "@\(hp($v.address; $v.port))#" + ($name | enc)
  elif .type == "vless" then
    "vless://\(.uuid)@\(hp(.server; .server_port))?" + (sq(.) + [kv("flow"; .flow), "encryption=none"] | join("&")) + "#" + ((.tag // "") | enc)
  elif .type == "trojan" then
    "trojan://\(.password | enc)@\(hp(.server; .server_port))?" + (sq(.) | join("&")) + "#" + ((.tag // "") | enc)
  elif .type == "shadowsocks" then
    "ss://" + ("\(.method):\(.password)" | @base64) + "@\(hp(.server; .server_port))#" + ((.tag // "") | enc)
  elif .type == "hysteria2" then
    "hysteria2://\(.password | enc)@\(hp(.server; .server_port))?" + ([kv("sni"; .tls.server_name), kv("obfs"; .obfs.type), kv("obfs-password"; .obfs.password)] | join("&")) + "#" + ((.tag // "") | enc)
  else empty end'

URLDEC_AWK='
function hv(c) { return index("0123456789abcdef", tolower(c)) - 1 }
function dec(s,   o, i, c, a, b) {
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "%" && i + 2 <= length(s)) {
      a = hv(substr(s, i + 1, 1)); b = hv(substr(s, i + 2, 1))
      if (a >= 0 && b >= 0) { o = o sprintf("%c", a * 16 + b); i += 2; continue }
    }
    o = o (c == "+" ? " " : c)
  }
  return o
}'

# drop the fake entries panels put into subscriptions ("App not supported",
# traffic left, expiry date, device limit...). stdin/stdout: links
REAL_AWK="$URLDEC_AWK"'
{
  l = $0; name = ""; p = index(l, "#"); if (p) { name = tolower(dec(substr(l, p + 1))); l = substr(l, 1, p - 1) }
  sub(/\?.*/, "", l); sub(/^[a-z0-9]+:\/\//, "", l); sub(/^.*@/, "", l); sub(/\/.*$/, "", l)
  host = l; sub(/:[0-9]+$/, "", host); gsub(/[][]/, "", host)
  if (host == "" || host ~ /^(0\.0\.0\.0|127\.|localhost$|::1?$|example\.)/) next
  if ($0 ~ /00000000-0000-0000-0000-000000000000/) next
  if (name ~ /not supported|unsupported|please update|update (the |your )?app|expired|traffic limit|device limit|hwid|renew/) next
  if (name ~ /не поддерж|обнови|истек|истёк|лимит|устройств|продли|осталось/) next
  print
}'

HWID=""
ROUTER_MODEL=$( { tr -d '\n' < /tmp/sysinfo/model; } 2>/dev/null)

# sub_fetch <url> <user-agent> <out>: download the way the client app would.
# Panels with a device limit want a stable x-hwid; the router gets one.
sub_fetch() {
  if [ -z "$HWID" ]; then
    HWID=$( { cat /sys/class/net/br-lan/address /sys/class/net/eth0/address 2>/dev/null
              cat /proc/sys/kernel/hostname 2>/dev/null; } | md5sum 2>/dev/null | cut -c 1-16)
    [ -n "$HWID" ] || HWID=0000000000000000
  fi
  curl -sL --max-time 20 -A "$2" -H "Accept: */*" -H "x-hwid: $HWID" -H "x-device-os: Linux" \
    -H "x-ver-os: OpenWrt" -H "x-device-model: ${ROUTER_MODEL:-OpenWrt}" -D "$3.h" "$1" > "$3" 2>/dev/null
}

# sub_info <headers>: "title, used X of Y GB, expires DATE" from the panel's headers
sub_info() {
  _t=$(sed -n 's/^[Pp]rofile-[Tt]itle: *//p' "$1" | tr -d '\r' | tail -n 1)
  case "$_t" in base64:*) _t=$(printf '%s' "${_t#base64:}" | b64d) ;; esac
  _ui=$(sed -n 's/^[Ss]ubscription-[Uu]serinfo: *//p' "$1" | tr -d '\r' | tail -n 1)
  _uiv() { printf '%s' "$_ui" | tr ';' '\n' | sed -n "s/^ *$1=\([0-9]*\).*/\1/p"; }
  _up=$(_uiv upload); _dn=$(_uiv download); _tot=$(_uiv total); _exp=$(_uiv expire)
  _out=${_t:+$_t}
  if [ -n "$_dn$_up" ]; then
    _out="${_out:+$_out, }$(awk -v u="${_up:-0}" -v d="${_dn:-0}" -v t="${_tot:-0}" 'BEGIN {
      printf "used %.1f GB", (u + d) / 1073741824; if (t > 0) printf " of %.0f GB", t / 1073741824 }')"
  fi
  if [ -n "$_exp" ] && [ "$_exp" -gt 0 ] 2>/dev/null; then
    _out="${_out:+$_out, }expires $(date -d "@$_exp" +%Y-%m-%d 2>/dev/null || echo "$_exp")"
  fi
  printf '%s' "$_out"
}

# sub_parse <raw> -> links on stdout (base64 / plain list / xray or sing-box JSON)
sub_parse() {
  case "$(tr -d ' \r\n\t' < "$1" | cut -c 1)" in
    "{"|"[") command -v jq >/dev/null 2>&1 && jq -r "$JSON2LINKS" "$1" 2>/dev/null | grep -oE "$LINK_RE" ;;
    *) extract_links < "$1" ;;
  esac
}

# sub_why <raw>: short human reason why nothing usable came back
sub_why() {
  if [ ! -s "$1" ]; then echo "empty answer (wrong URL, expired key, or the site is blocked)"; return; fi
  _h=$(head -c 400 "$1" | tr 'A-Z' 'a-z')
  case "$_h" in
    *"<html"*|*"<!doctype"*) echo "got a web page instead of a server list" ;;
    *happ://crypt*) echo "only encrypted happ://crypt links (Happ-only format, can't be decoded)" ;;
    *"proxies:"*|*"proxy-groups"*) echo "got a Clash config (not supported)" ;;
    *) if [ -s "$1.links" ]; then
         echo "only placeholder entries: $(sed -n 's/.*#//p' "$1.links" | head -n 2 | awk "$URLDEC_AWK"'{ print dec($0) }' | tr '\n' ';')"
       else
         echo "no vless/vmess/trojan/ss/hysteria2 links inside"
       fi ;;
  esac
}

# --- countries ---------------------------------------------------------------

# node name -> ISO country code from its flag emoji or a country/city name
CC_AWK='
BEGIN {
  pre = sprintf("%c%c%c", 240, 159, 135)
  for (i = 0; i < 26; i++) RI[sprintf("%c", 166 + i)] = sprintf("%c", 65 + i)
  n = split("Germany=DE Германия=DE Frankfurt=DE Франкфурт=DE Netherlands=NL Нидерланды=NL Holland=NL Голландия=NL Amsterdam=NL Амстердам=NL Finland=FI Финляндия=FI Helsinki=FI Хельсинки=FI France=FR Франция=FR Paris=FR Париж=FR Poland=PL Польша=PL Warsaw=PL Варшава=PL Sweden=SE Швеция=SE Stockholm=SE Стокгольм=SE Britain=GB Британия=GB Великобритания=GB Англия=GB London=GB Лондон=GB Latvia=LV Латвия=LV Riga=LV Рига=LV Estonia=EE Эстония=EE Tallinn=EE Таллин=EE Lithuania=LT Литва=LT Austria=AT Австрия=AT Vienna=AT Вена=AT Switzerland=CH Швейцария=CH Italy=IT Италия=IT Milan=IT Милан=IT Spain=ES Испания=ES Madrid=ES Мадрид=ES Norway=NO Норвегия=NO Czech=CZ Чехия=CZ Prague=CZ Прага=CZ Romania=RO Румыния=RO Bulgaria=BG Болгария=BG Moldova=MD Молдова=MD Serbia=RS Сербия=RS Hungary=HU Венгрия=HU Portugal=PT Португалия=PT Ireland=IE Ирландия=IE Denmark=DK Дания=DK Belgium=BE Бельгия=BE Greece=GR Греция=GR Slovakia=SK Словакия=SK Slovenia=SI Словения=SI Croatia=HR Хорватия=HR Luxembourg=LU Люксембург=LU Iceland=IS Исландия=IS Cyprus=CY Кипр=CY Ukraine=UA Украина=UA Russia=RU Россия=RU Moscow=RU Москва=RU Belarus=BY Беларусь=BY Turkey=TR Турция=TR Istanbul=TR Стамбул=TR Kazakhstan=KZ Казахстан=KZ USA=US США=US America=US Америка=US Canada=CA Канада=CA Japan=JP Япония=JP Singapore=SG Сингапур=SG Kong=HK Гонконг=HK Israel=IL Израиль=IL UAE=AE ОАЭ=AE Dubai=AE Дубай=AE Armenia=AM Армения=AM Georgia=GE Грузия=GE India=IN Индия=IN", W, " ")
  for (i = 1; i <= n; i++) { p = index(W[i], "="); K[i] = substr(W[i], 1, p - 1); V[i] = substr(W[i], p + 1) }
}
{
  s = $0; cc = "-"; p = index(s, pre)
  while (p) {
    a = substr(s, p + 3, 1); b = substr(s, p + 7, 1)
    if (substr(s, p + 4, 3) == pre && (a in RI) && (b in RI)) { cc = RI[a] RI[b]; break }
    s = substr(s, p + 4); p = index(s, pre)
  }
  if (cc == "-") for (i = 1; i <= n; i++) if (index($0, K[i])) { cc = V[i]; break }
  if (cc == "-") {
    s = $0; gsub(/[^A-Za-z]+/, " ", s); m = split(s, T, " ")
    for (i = 1; i <= m; i++) if (T[i] ~ /^[A-Z][A-Z]$/ && index(" " cl " ", " " T[i] " ")) { cc = T[i]; break }
  }
  print cc
}'
KNOWN_CC="$EUROPE RU BY TR KZ US CA JP SG HK IL AE AM GE IN"

name_cc() { printf '%s\n' "$1" | awk -v cl="$KNOWN_CC" "$CC_AWK"; }

# cc_allowed <cc>: unknown ("-") passes; the exit IP check decides later
cc_allowed() {
  [ "$1" = "-" ] && return 0
  case "$COUNTRIES" in
    all|"") return 0 ;;
    europe|Europe|EU|eu) case " $EUROPE " in *" $1 "*) return 0 ;; esac; return 1 ;;
    *) case ",$(echo "$COUNTRIES" | tr 'a-z ' 'A-Z,')," in *",$1,"*) return 0 ;; esac; return 1 ;;
  esac
}

countries_label() {
  case "$COUNTRIES" in all|"") echo "all countries" ;; europe|Europe|EU|eu) echo "Europe only" ;; *) echo "$COUNTRIES" ;; esac
}

# stdin: any text (plain or base64) -> supported links, one per line
extract_links() {
  _t=$(cat)
  case "$_t" in *://*) ;; *) _t=$(printf '%s' "$_t" | b64d) ;; esac
  printf '%s\n' "$_t" | tr -d '\r' | grep -oE "$LINK_RE"
}

# JSON string literal
js() {
  case "$1" in
    *[\"\\]*) printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')" ;;
    *) printf '"%s"' "$1" ;;
  esac
}

# one awk pass: split a link into shell assignments L_* and q_<param>, all
# percent-decoded. Values are single-quoted, so eval of the output is safe.
PARSE_AWK='
function hv(c) { return index("0123456789abcdef", tolower(c)) - 1 }
function dec(s, plus,   o, i, c, a, b) {
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "%" && i + 2 <= length(s)) {
      a = hv(substr(s, i + 1, 1)); b = hv(substr(s, i + 2, 1))
      if (a >= 0 && b >= 0 && a * 16 + b > 0) { o = o sprintf("%c", a * 16 + b); i += 2; continue }
    }
    if (c == "+" && plus) c = " "
    o = o c
  }
  return o
}
function emit(k, v) { gsub(/[^A-Za-z0-9_]/, "_", k); gsub(/\047/, "\047\\\047\047", v); print k "=\047" v "\047" }
{
  s = $0; p = index(s, "://"); emit("L_scheme", tolower(substr(s, 1, p - 1))); s = substr(s, p + 3)
  fr = ""; p = index(s, "#"); if (p) { fr = substr(s, p + 1); s = substr(s, 1, p - 1) }
  q = "";  p = index(s, "?"); if (p) { q = substr(s, p + 1); s = substr(s, 1, p - 1) }
  sub(/\/+$/, "", s)
  u = ""; p = 0; for (i = length(s); i > 0; i--) if (substr(s, i, 1) == "@") { p = i; break }
  if (p) { u = substr(s, 1, p - 1); s = substr(s, p + 1) }
  h = s; port = ""
  if (s ~ /^\[/) { p = index(s, "]"); h = substr(s, 2, p - 2); r = substr(s, p + 1); if (r ~ /^:/) port = substr(r, 2) }
  else { for (i = length(s); i > 0; i--) if (substr(s, i, 1) == ":") { h = substr(s, 1, i - 1); port = substr(s, i + 1); break } }
  sub(/[,-].*/, "", port)
  emit("L_user", dec(u, 0)); emit("L_host", h); emit("L_port", port); emit("L_name", dec(fr, 1))
  n = split(q, a, "&")
  for (i = 1; i <= n; i++) {
    p = index(a[i], "=")
    if (p) emit("q_" substr(a[i], 1, p - 1), dec(substr(a[i], p + 1), 0))
    else if (a[i] != "") emit("q_" a[i], "")
  }
}'

parse_link() { eval "$(printf '%s\n' "$1" | awk "$PARSE_AWK")"; }

# tls_json <security> <sni> <fp> <alpn> <insecure 0/1> <pbk> <sid>
tls_json() {
  _t="\"tls\":{\"enabled\":true"
  [ -n "$2" ] && _t="$_t,\"server_name\":$(js "$2")"
  [ "$5" = 1 ] && _t="$_t,\"insecure\":true"
  [ -n "$4" ] && _t="$_t,\"alpn\":[$(printf '%s' "$4" | awk -F, '{for(i=1;i<=NF;i++)printf "%s\"%s\"",(i>1?",":""),$i}')]"
  _fp=$3; [ "$1" = reality ] && [ -z "$_fp" ] && _fp=chrome
  [ -n "$_fp" ] && _t="$_t,\"utls\":{\"enabled\":true,\"fingerprint\":$(js "$_fp")}"
  [ "$1" = reality ] && _t="$_t,\"reality\":{\"enabled\":true,\"public_key\":$(js "$6"),\"short_id\":$(js "$7")}"
  printf '%s},' "$_t"
}

# transport_json <type> <host> <path> <serviceName>; fails on unsupported
transport_json() {
  _p=${3:-/}
  case "$1" in
    ""|tcp|raw|none) ;;
    ws)
      _ed=""
      case "$_p" in *\?ed=*)
        _e=${_p##*\?ed=}; _e=${_e%%&*}; _p=${_p%%\?*}
        is_uint "$_e" && _ed=",\"max_early_data\":$_e,\"early_data_header_name\":\"Sec-WebSocket-Protocol\"" ;;
      esac
      printf '"transport":{"type":"ws","path":%s,"headers":{"Host":%s}%s},' "$(js "$_p")" "$(js "$2")" "$_ed" ;;
    grpc)        printf '"transport":{"type":"grpc","service_name":%s},' "$(js "$4")" ;;
    httpupgrade) printf '"transport":{"type":"httpupgrade","host":%s,"path":%s},' "$(js "$2")" "$(js "$_p")" ;;
    h2|http)     printf '"transport":{"type":"http","host":[%s],"path":%s},' "$(js "$2")" "$(js "$_p")" ;;
    quic)        printf '"transport":{"type":"quic"},' ;;
    *) return 1 ;;
  esac
}

truthy() { case "$1" in 1|true|True|yes) echo 1 ;; *) echo 0 ;; esac; }

# build_link <link> <dir>: writes <dir>/ob.json + <dir>/name, or <dir>/skip
build_link() {
  _d=$2
  printf '%s\n' "$1" > "$_d/link"
  parse_link "$1"
  skip() { printf '%s\n' "$*" > "$_d/skip"; printf '%s\n' "${L_name:-$1}" > "$_d/name"; }

  case "$L_scheme" in
    vmess)
      command -v jq >/dev/null 2>&1 || { skip "vmess:// needs jq"; return; }
      _raw=${1#*://}; _raw=${_raw%%#*}
      eval "$(printf '%s' "$_raw" | b64d |
        jq -r 'to_entries[] | "v_\(.key | gsub("[^A-Za-z0-9_]"; "_"))=\(.value | tostring | @sh)"' 2>/dev/null)"
      L_host=${v_add:-}; L_port=${v_port:-}; L_name=${v_ps:-}
      ;;
    ss)
      if [ -z "$L_user" ]; then          # legacy ss://base64(method:pass@host:port)#name
        _nm=$L_name; _dec=$(printf '%s' "$L_host" | b64d)
        parse_link "ss://$_dec"; L_name=$_nm
      fi
      ;;
  esac

  [ -n "${L_host:-}" ] || { skip "cannot parse link"; return; }
  is_uint "${L_port:-}" || L_port=443
  [ -n "$L_name" ] || L_name="$L_host:$L_port"
  printf '%s\n' "$L_name" > "$_d/name"

  _srv="\"server\":$(js "$L_host"),\"server_port\":$L_port"
  _sni=${q_sni:-${q_peer:-}}
  _hh=${q_host:-}
  _ins=$(truthy "${q_allowInsecure:-${q_insecure:-0}}")

  case "$L_scheme" in
    vless|trojan)
      if [ "$L_scheme" = trojan ]; then _sec=${q_security:-tls}; else _sec=${q_security:-none}; fi
      [ -n "$_sni" ] || _sni=${_hh:-$L_host}
      [ -n "$_hh" ] || _hh=$_sni
      _tr=$(transport_json "${q_type:-tcp}" "$_hh" "${q_path:-}" "${q_serviceName:-}") ||
        { skip "transport '${q_type:-}' is not supported by podkop (sing-box)"; return; }
      _tls=""
      case "$_sec" in tls|reality|xtls)
        _tls=$(tls_json "$_sec" "$_sni" "${q_fp:-}" "${q_alpn:-}" "$_ins" "${q_pbk:-}" "${q_sid:-}") ;;
      esac
      if [ "$L_scheme" = vless ]; then
        _fl=""; [ -n "${q_flow:-}" ] && _fl="\"flow\":$(js "$q_flow"),"
        printf '{"type":"vless","tag":"node",%s,"uuid":%s,%s%s%s"packet_encoding":"xudp"}\n' \
          "$_srv" "$(js "$L_user")" "$_fl" "$_tls" "$_tr" > "$_d/ob.json"
      else
        printf '{"type":"trojan","tag":"node",%s,%s%s"password":%s}\n' \
          "$_srv" "$_tls" "$_tr" "$(js "$L_user")" > "$_d/ob.json"
      fi
      ;;
    vmess)
      _sni=${v_sni:-${v_host:-$L_host}}; _hh=${v_host:-$_sni}
      _tr=$(transport_json "${v_net:-tcp}" "$_hh" "${v_path:-}" "${v_path:-}") ||
        { skip "transport '${v_net:-}' is not supported by podkop (sing-box)"; return; }
      _tls=""
      [ "${v_tls:-}" = tls ] && _tls=$(tls_json tls "$_sni" "${v_fp:-}" "${v_alpn:-}" 0 "" "")
      printf '{"type":"vmess","tag":"node",%s,"uuid":%s,"security":%s,"alter_id":%s,%s%s"packet_encoding":"xudp"}\n' \
        "$_srv" "$(js "${v_id:-}")" "$(js "${v_scy:-auto}")" "$(is_uint "${v_aid:-0}" && echo "$v_aid" || echo 0)" \
        "$_tls" "$_tr" > "$_d/ob.json"
      ;;
    ss)
      case "$L_user" in *:*) _ui=$L_user ;; *) _ui=$(printf '%s' "$L_user" | b64d) ;; esac
      _m=${_ui%%:*}; _pw=${_ui#*:}
      _pl=""
      if [ -n "${q_plugin:-}" ]; then
        _pn=${q_plugin%%;*}; _po=""; case "$q_plugin" in *\;*) _po=${q_plugin#*;} ;; esac
        [ "$_pn" = simple-obfs ] && _pn=obfs-local
        _pl="\"plugin\":$(js "$_pn"),\"plugin_opts\":$(js "$_po"),"
      fi
      printf '{"type":"shadowsocks","tag":"node",%s,%s"method":%s,"password":%s}\n' \
        "$_srv" "$_pl" "$(js "$_m")" "$(js "$_pw")" > "$_d/ob.json"
      ;;
    hysteria2|hy2)
      _ob=""
      [ -n "${q_obfs:-}" ] && _ob="\"obfs\":{\"type\":$(js "$q_obfs"),\"password\":$(js "${q_obfs_password:-}")},"
      _tls=$(tls_json tls "${_sni:-$L_host}" "" "${q_alpn:-h3}" "$_ins" "" "")
      printf '{"type":"hysteria2","tag":"node",%s,%s%s"password":%s}\n' \
        "$_srv" "$_ob" "$_tls" "$(js "$L_user")" > "$_d/ob.json"
      ;;
    *) skip "unsupported scheme $L_scheme://" ;;
  esac
}

# --- node sources ------------------------------------------------------------

NODES="$WORK/nodes"        # lines: "L<TAB>link" or "O<TAB>name<TAB>outbound-json"

add_links() { extract_links | awk -v t="$TAB" '{print "L" t $0}' >> "$NODES"; }

from_config() {
  [ -f "$1" ] || die "config not found: $1"
  need_tool jq jq "needed to read $1" || die "jq is required to read a sing-box config"
  jq -r '.outbounds[]? | select(type == "object" and .server != null and .type != "direct")
         | ((.tag // "node") + " (" + (.server | tostring) + ")") + "\t"
           + (del(.detour, .domain_resolver) | .tag = "node" | tojson)' "$1" 2>/dev/null |
    awk -v t="$TAB" '{print "O" t $0}' >> "$NODES"
}

podkop_config_path() {
  _p=$(uci -q get podkop.settings.config_path 2>/dev/null)
  for _c in "$_p" /etc/sing-box/config.json /tmp/sing-box/config.json \
            /tmp/etc/sing-box/config.json /var/etc/sing-box/config.json; do
    [ -n "$_c" ] && [ -f "$_c" ] && { echo "$_c"; return 0; }
  done
  return 1
}

from_uci() {
  command -v uci >/dev/null 2>&1 || return 1
  uci -q show podkop 2>/dev/null | grep -E '\.(proxy_string|[a-z_]*proxy_links)=' | add_links
}

ask_links() {
  [ -n "$TTY" ] || return 1
  echo
  info "No nodes found. Paste links (vless://, trojan://, ss://, ...) or a subscription URL."
  info "One per line, finish with an empty line:"
  while IFS= read -r _l < "$TTY"; do
    [ -z "$_l" ] && break
    case "$_l" in
      http://*|https://*) fetch "$_l" | add_links || warn "could not fetch $_l" ;;
      *) printf '%s\n' "$_l" | add_links ;;
    esac
  done
  SOURCE="pasted links"
}

# from_sub <url> <label>: try the client apps one by one until the panel gives
# real servers, the same thing Happ/Streisand/INCY do when a key is imported
from_sub() {
  _host=${1#*://}; _host=${_host%%/*}
  _raw="$WORK/sub.$_k"; _why=""; _app=""; _japp=""
  : > "$_raw.real"; rm -f "$_raw.json" "/tmp/podkop-probe-sub$_k.txt"
  _uas=$(printf '%s\n' "$SUB_UAS" | tr ' ' '~')
  set -f
  for _ua in $_uas; do
    _ua=$(printf '%s' "$_ua" | tr '~' ' ')
    sub_fetch "$1" "$_ua" "$_raw.try"
    sub_parse "$_raw.try" > "$_raw.try.links"
    awk "$REAL_AWK" "$_raw.try.links" > "$_raw.try.real"
    # keep the most telling reason: placeholder entries beat "web page" etc.
    if [ -z "$_why" ] || { [ -s "$_raw.try.links" ] && case "$_why" in "only placeholder"*) false ;; *) true ;; esac; }; then
      _why=$(sub_why "$_raw.try")
    fi
    [ "$VERBOSE" = 1 ] && [ ! -f "/tmp/podkop-probe-sub$_k.txt" ] && cp "$_raw.try" "/tmp/podkop-probe-sub$_k.txt"
    [ -s "$_raw.try.real" ] || continue
    # a plain list of links carries the provider's own server names; a JSON
    # answer (xray config for Happ & co.) is only kept as a fallback
    case "$(tr -d ' \r\n\t' < "$_raw.try" | cut -c 1)" in
      "{"|"[")
        [ -s "$_raw.json" ] || { mv "$_raw.try.real" "$_raw.json"; cp "$_raw.try.h" "$_raw.json.h" 2>/dev/null; _japp=${_ua%%/*}; }
        continue ;;
    esac
    _app=${_ua%%/*}; mv "$_raw.try.real" "$_raw.real"; cp "$_raw.try.h" "$_raw.h" 2>/dev/null
    break
  done
  set +f
  if [ ! -s "$_raw.real" ] && [ -s "$_raw.json" ]; then
    mv "$_raw.json" "$_raw.real"; mv "$_raw.json.h" "$_raw.h" 2>/dev/null; _app="$_japp, xray JSON"
  fi
  if [ ! -s "$_raw.real" ]; then
    warn "$2 ($_host): $_why"
    [ "$VERBOSE" = 1 ] && info "first answer saved to /tmp/podkop-probe-sub$_k.txt"
    return 1
  fi
  awk -v t="$TAB" '{print "L" t $0}' "$_raw.real" >> "$NODES"
  info "$2 ($_host): $(wc -l < "$_raw.real" | tr -d ' ') server(s) (fetched as $_app)"
  _si=$(sub_info "$_raw.h" 2>/dev/null); [ -n "$_si" ] && info "    $_si"
  return 0
}

from_subs() {
  _total=$(printf '%s' "$SUBS" | grep -c .); _k=0; _oks=0
  set -f
  for _u in $SUBS; do
    _k=$((_k + 1))
    _u=$(printf '%s' "$_u" | sed 's/^\[//; s/[])]*$//')
    from_sub "$_u" "subscription $_k/$_total" && _oks=$((_oks + 1))
  done
  set +f
  [ "$_oks" -gt 0 ] || die "none of the subscriptions gave any links"
  SOURCE="${SOURCE:+$SOURCE + }$_oks subscription(s)"
}

# read one or more subscription URLs from the terminal into SUBS
ask_subs() {
  echo "Paste subscription URLs (main keys), one per line or space separated."
  echo "Finish with an empty line:"
  _got=""
  while IFS= read -r _l < "$TTY"; do
    [ -n "$(printf '%s' "$_l" | tr -d ' \r\t')" ] || break
    _u=$(printf '%s\n' "$_l" | grep -oE 'https?://[^[:space:]]+')
    [ -n "$_u" ] || { warn "not a URL, skipped: $_l"; continue; }
    _got="$_got$_u
"
  done
  [ -n "$_got" ] || return 1
  SUBS=$_got
}

ask_countries() {
  echo "Which servers should be tested and chosen?"
  echo "  1) Europe only   2) all countries   3) let me list country codes (e.g. DE,NL,FI)"
  printf '> [1] '
  read -r _c < "$TTY" || return
  case "$_c" in
    ""|1) COUNTRIES=europe ;;
    2) COUNTRIES=all ;;
    3) printf 'Country codes, comma separated: '; read -r _c < "$TTY"; COUNTRIES=${_c:-europe} ;;
    *) COUNTRIES=$_c ;;
  esac
}

menu() {
  echo
  printf '%sWhat do you want to do?%s\n' "$BD" "$R0"
  echo "  1) Test the nodes podkop uses now"
  echo "  2) Enter one or more subscription URLs (main keys), test all their"
  echo "     nodes and put the best $TOP by ping and speed into podkop (URLTest)"
  echo "  3) Paste links to test"
  echo "  4) Nightly auto-update: $(nightly_status)"
  echo "  q) Quit"
  printf '> '
  read -r _m < "$TTY" || exit 1
  case "$_m" in
    1|"") MODE=podkop ;;
    2) ask_subs || die "no subscription URL given"; ask_countries; MODE=sub ;;
    3) MODE="paste" ;;
    4) nightly_menu; exit 0 ;;
    *) exit 0 ;;
  esac
}

count_nodes() { [ -s "$NODES" ] && wc -l < "$NODES" | tr -d ' ' || echo 0; }

# --- server IP country ------------------------------------------------------

# resolve <host> -> first IPv4 address (public resolvers first: the router's
# own DNS may answer podkop's fake IPs)
resolve() {
  case "$1" in *[!0-9.]*) ;; *) echo "$1"; return ;; esac
  for _ns in 77.88.8.8 8.8.8.8 ""; do
    _a=$(nslookup "$1" $_ns 2>/dev/null | awk '/^Name:/ { n = 1; next } n && /^Address/ { sub(/^Address[^:]*: */, ""); sub(/ .*/, ""); if ($0 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print; exit } }')
    case "$_a" in ""|198.18.*|198.19.*) ;; *) echo "$_a"; return ;; esac
  done
}

# entry_countries: <dir>/ecc = country of each node's server IP ("-" when
# unknown or behind a CDN such as Cloudflare, where the IP says nothing)
entry_countries() {
  mkdir -p "$WORK/geo"; : > "$WORK/geo/hosts"
  _i=0
  while [ "$_i" -lt "$COUNT" ]; do
    _i=$((_i + 1)); _d="$WORK/n/$_i"; echo "-" > "$_d/ecc"
    [ -f "$_d/ob.json" ] || continue
    _h=$(sed -n 's/.*"server":"\([^"]*\)".*/\1/p' "$_d/ob.json" | head -n 1)
    [ -n "$_h" ] && printf '%s\t%s\n' "$_i" "$_h" >> "$WORK/geo/hosts"
  done
  [ -s "$WORK/geo/hosts" ] || return 0
  : > "$WORK/geo/ips"
  cut -f 2 "$WORK/geo/hosts" | sort -u | while IFS= read -r _h; do
    _ip=$(resolve "$_h"); [ -n "$_ip" ] && printf '%s\t%s\n' "$_h" "$_ip" >> "$WORK/geo/ips"
  done
  [ -s "$WORK/geo/ips" ] || return 0
  cut -f 2 "$WORK/geo/ips" | sort -u | while IFS= read -r _ip; do
    printf 'url = "https://ipinfo.io/%s/json"\noutput = "%s"\n' "$_ip" "$WORK/geo/$_ip"
  done > "$WORK/geo/req.cfg"
  if [ "$HAS_PARALLEL" = 1 ]; then
    curl -s -Z --parallel-max 8 --max-time 8 -K "$WORK/geo/req.cfg" 2>/dev/null
  else
    curl -s --max-time 8 -K "$WORK/geo/req.cfg" 2>/dev/null
  fi
  while IFS="$TAB" read -r _n _h; do
    _ip=$(awk -F "$TAB" -v h="$_h" '$1 == h { print $2; exit }' "$WORK/geo/ips")
    [ -n "$_ip" ] || continue
    [ -f "$WORK/geo/$_ip" ] || continue
    _org=$(sed -n 's/.*"org": *"\([^"]*\)".*/\1/p' "$WORK/geo/$_ip" | head -n 1)
    case "$_org" in *[Cc]loudflare*|*Fastly*|*Akamai*|*G-Core*|*Gcore*|*CDN77*|*CloudFront*) continue ;; esac
    _c=$(sed -n 's/.*"country": *"\([A-Z][A-Z]\)".*/\1/p' "$WORK/geo/$_ip" | head -n 1)
    [ -n "$_c" ] && echo "$_c" > "$WORK/n/$_n/ecc"
  done < "$WORK/geo/hosts"
}

# --- per-node worker ---------------------------------------------------------

port_busy() { grep -q ":$(printf '%04X' "$1") 00000000:0000 0A" /proc/net/tcp 2>/dev/null; }

# sb_start <idx>: run sing-box for node idx on a free local port.
# Sets _pid and _port; fails if sing-box did not come up.
sb_start() {
  _sd="$WORK/n/$1"; _port=$((BASEPORT + $1)); _try=0
  while :; do
    while port_busy "$_port"; do _port=$((_port + 500)); done
    printf '{"log":{"level":"error"},%s"inbounds":[{"type":"mixed","tag":"in","listen":"127.0.0.1","listen_port":%s}],"outbounds":[%s,{"type":"direct","tag":"direct"}],"route":{"final":"node"%s}}\n' \
      "$SB_DNS" "$_port" "$(cat "$_sd/ob.json")" "$SB_RES" > "$_sd/config.json"
    sing-box run -c "$_sd/config.json" > "$_sd/sb.log" 2>&1 &
    _pid=$!; echo "$_pid" > "$WORK/pids/$1"
    _sk=0
    while :; do
      if ! kill -0 "$_pid" 2>/dev/null; then
        # port taken between our check and sing-box's bind (another run?)
        _try=$((_try + 1))
        grep -q 'address already in use' "$_sd/sb.log" && [ "$_try" -lt 4 ] && break
        return 1
      fi
      port_busy "$_port" && return 0
      _sk=$((_sk + 1)); [ "$_sk" -ge "$WAIT_TICKS" ] && return 1
      sleep "$NAP"
    done
    _port=$((_port + 500))
  done
}

sb_stop() { kill "$_pid" 2>/dev/null; rm -f "$WORK/pids/$1"; }

# speed_fetch <url>: download <url> through the node (again, if it ends
# early) and watch curl's progress every second. Stops when the running
# average has settled (changed <3% twice in a row, after 3 s) or after
# SPEED_T seconds -> Mbit/s on stdout; on failure the reason and exit 1.
SPEED_AWK='
function b(x, m) { m = 1; if (x ~ /k$/) m = 1024; else if (x ~ /M$/) m = 1048576; else if (x ~ /G$/) m = 1073741824
  sub(/[kMG]$/, "", x); return x * m }
# progress meter records: % Total % Received % Xferd AvgDload AvgUpload ...
NF >= 12 && $1 ~ /^[0-9]+$/ { r = b($4); a = b($7) }
END { printf "%.0f %.0f\n", r, a }'
speed_fetch() {
  _u=$1; _B=0; _T=0; _prev=0; _stab=0; _done=0
  while [ "$_done" = 0 ]; do
    _rem=$(awk -v a="$SPEED_T" -v t="$_T" 'BEGIN { r = a - t; if (r < 0.5) exit 1; printf "%.1f", r }') || break
    curl -o /dev/null --noproxy '' -x "$_px" --max-time "$_rem" \
      -w '%{http_code} %{size_download} %{time_total}\n' "$_u" > "$_sd/sp.out" 2> "$_sd/sp.prog" &
    _cp=$!
    while sleep 1; kill -0 "$_cp" 2>/dev/null; do
      set -- $(tr '\r' '\n' < "$_sd/sp.prog" | awk "$SPEED_AWK")
      # -> "stop B T avg stab prev" using this chunk's bytes so far and avg speed
      set -- $(awk -v B="$_B" -v T="$_T" -v rb="${1:-0}" -v ra="${2:-0}" -v p="$_prev" -v st="$_stab" -v lim="$SPEED_T" 'BEGIN {
        if (ra <= 0) { print 0, B, T, 0, 0, p; exit }
        t = T + rb / ra; avg = (B + rb) / t
        st = (t >= 3 && p > 0 && (avg > p ? avg - p : p - avg) < 0.03 * avg) ? st + 1 : 0
        printf "%d %.0f %.3f %.0f %d %.0f\n", (st >= 2 || t >= lim - 0.3), B + rb, t, avg, st, avg }')
      _stab=$5; _prev=$6
      if [ "$1" = 1 ]; then
        kill "$_cp" 2>/dev/null; wait "$_cp" 2>/dev/null
        _B=$2; _T=$3; _done=1; break
      fi
    done
    [ "$_done" = 1 ] && break
    wait "$_cp" 2>/dev/null
    set -- $(cat "$_sd/sp.out" 2>/dev/null)
    if [ -z "${2:-}" ] || [ "${2:-0}" -lt 100000 ] 2>/dev/null; then
      [ "$_B" = 0 ] && { _h=${_u#*://}; echo "HTTP ${1:-000} from ${_h%%/*}"; return 1; }
      break
    fi
    # a whole chunk arrived: add it and check the running average again
    set -- $(awk -v B="$_B" -v T="$_T" -v b="$2" -v t="${3:-0}" -v p="$_prev" -v st="$_stab" -v lim="$SPEED_T" 'BEGIN {
      B += b; T += t; avg = (T > 0) ? B / T : 0
      st = (T >= 3 && p > 0 && (avg > p ? avg - p : p - avg) < 0.03 * avg) ? st + 1 : 0
      printf "%d %.0f %.3f %d %.0f\n", (st >= 2 || T >= lim - 0.3), B, T, st, avg }')
    _B=$2; _T=$3; _stab=$4; _prev=$5
    [ "$1" = 1 ] && break
  done
  awk -v b="$_B" -v t="$_T" 'BEGIN { if (t > 0) printf "%.1f\n", b * 8 / t / 1000000; else print "0.0" }'
}

# speed_measure <dir>: download speed through the running node -> <dir>/speed
# in Mbit/s (reason for a failure in <dir>/speed.why)
speed_measure() {
  _sd=$1; _why=""; _res=""
  set -f
  for _su in ${SPEED_URL:-$SPEED_URLS}; do
    if _res=$(speed_fetch "$_su"); then _why=""; break; fi
    _why="${_why:+$_why, }$_res"; _res=""
  done
  set +f
  echo "${_res:-0.0}" > "$1/speed"
  [ -n "$_why" ] && echo "$_why" > "$1/speed.why"
}

# fire <curl-config> <times-file>: the requests of one stage
fire() {
  if [ "$HAS_PARALLEL" = 1 ]; then
    curl -s -K "$1" -Z --parallel-max "$C" --parallel-immediate \
      --max-time "$T" --noproxy '' -x "$_px" -w '%{http_code} %{time_total}\n' >> "$2" 2>/dev/null
  else
    curl -s -K "$1" --max-time "$T" --noproxy '' -x "$_px" -w '%{http_code} %{time_total}\n' >> "$2" 2>/dev/null
  fi
}

# speed_node <idx>: start the node again and measure its speed
speed_node() {
  _sn=$1
  if sb_start "$_sn"; then
    _px="socks5h://127.0.0.1:$_port"
    speed_measure "$WORK/n/$_sn"
  else
    echo "0.0" > "$WORK/n/$_sn/speed"; echo "sing-box did not start" > "$WORK/n/$_sn/speed.why"
  fi
  sb_stop "$_sn"
}

# same_key <idx>: links to the same server/port/transport share a speed test
# (e.g. "Германия #1" and "Германия #1 (для iOS)")
same_key() {
  if [ -f "$WORK/n/$1/link" ]; then
    sed -e 's/#.*//' -e 's|^\([a-z0-9]*\)://[^@]*@\([^?/]*\).*|\1 \2|' "$WORK/n/$1/link" | tr -d '\n'
    printf ' %s %s\n' "$(sed -n 's/.*[?&]type=\([^&#]*\).*/\1/p' "$WORK/n/$1/link")" \
      "$(sed -n 's/.*[?&]security=\([^&#]*\).*/\1/p' "$WORK/n/$1/link")"
  else
    echo "node $1"
  fi
}

run_node() {
  _i=$1; _d="$WORK/n/$_i"
  _st=ok; _ip=""; _cc=""
  if [ -f "$_d/skip" ]; then
    _st=skip
  elif ! sb_start "$_i"; then
    _st=start
  fi

  : > "$_d/times"
  if [ "$_st" = ok ]; then
    _px="socks5h://127.0.0.1:$_port"
    exit_ip "$_px" > "$_d/exit" &                  # runs alongside the requests
    _epid=$!

    # stage 0: a few requests; if none gets through the node is dead
    # stage 1: up to half the series; a node losing >30% by then is bad
    #          enough, no need to wait for the rest to time out
    # stage 2: the rest
    fire "$WORK/req0.cfg" "$_d/times"
    if grep -qv '^000' "$_d/times"; then
      [ -s "$WORK/req1.cfg" ] && fire "$WORK/req1.cfg" "$_d/times"
      if [ -s "$WORK/req2.cfg" ] && awk '$1 == "000" { f++ } END { exit !(f * 10 <= NR * 3) }' "$_d/times"; then
        fire "$WORK/req2.cfg" "$_d/times"
      fi
    fi
    wait "$_epid" 2>/dev/null
    set -- $(cat "$_d/exit")
    _ip=${1:-}; _cc=${2:-}
    [ "${_cc:--}" = "-" ] && _cc=$(cat "$_d/ncc" 2>/dev/null)
    if [ -z "$_ip" ]; then _st=noexit
    elif [ "$_ip" = "$DIRECT_IP" ]; then _st=direct
    fi
    cc_allowed "${_cc:--}" || _st=region
    sb_stop "$_i"
  elif [ "$_st" = start ]; then
    sb_stop "$_i"
  fi

  # status ok total min median p90 (total = requests actually sent)
  set -- $(awk '$1 != "000" {print $2}' "$_d/times" | sort -n | awk -v tot="$(wc -l < "$_d/times")" -v st="$_st" '
    { a[++k] = $1 }
    END {
      if (st == "skip" || st == "start") { print st, 0, 0, "-", "-", "-"; exit }
      if (!k) { print st, 0, tot, "-", "-", "-"; exit }
      med = (k % 2) ? a[(k + 1) / 2] : (a[k / 2] + a[k / 2 + 1]) / 2
      p = int(k * 0.9); if (p < k * 0.9) p++; if (p < 1) p = 1
      printf "%s %d %d %.3f %.3f %.3f\n", st, k, tot, a[1], med, a[p]
    }')
  _sp=$(cat "$_d/speed" 2>/dev/null); [ -n "$_sp" ] || _sp=-
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "${_ip:--}" "${_cc:--}" "$_sp" "$(cat "$_d/name")" > "$_d/result"
  print_progress "$_i" "$_d/result"
}

# curl through $_px when set; --noproxy '' stops NO_PROXY from bypassing it
pcurl() { if [ -n "$_px" ]; then curl --noproxy '' -x "$_px" "$@"; else curl "$@"; fi; }

# exit_ip [proxy] -> "ip country"
exit_ip() {
  _px=${1:-}
  _r=0
  while [ "$_r" -lt 1 ]; do
    _j=$(pcurl -s --max-time 5 https://ipinfo.io/json 2>/dev/null)
    _ip=$(printf '%s\n' "$_j" | sed -n 's/.*"ip": *"\([^"]*\)".*/\1/p' | head -n 1)
    _cc=$(printf '%s\n' "$_j" | sed -n 's/.*"country": *"\([^"]*\)".*/\1/p' | head -n 1)
    if [ -z "$_ip" ]; then
      _ip=$(pcurl -s --max-time 5 https://api.ipify.org 2>/dev/null | grep -oE '^[0-9a-fA-F.:]+$')
    fi
    [ -n "$_ip" ] && { echo "$_ip ${_cc:--}"; return; }
    _r=$((_r + 1))
  done
}

# verdict <status> <ok> <total> -> "LABEL<TAB>color"
verdict() {
  case "$1" in
    skip)   echo "SKIPPED" ; return ;;
    start)  echo "NO START"; return ;;
    direct) echo "NOT VIA NODE"; return ;;
    region) echo "OTHER REGION"; return ;;
  esac
  [ "$3" -gt 0 ] || { echo "DEAD"; return; }
  _f=$(( ($3 - $2) * 1000 / $3 ))
  if   [ "$2" -eq 0 ];   then echo "DEAD"
  elif [ "$_f" -eq 0 ];  then echo "GOOD"
  elif [ "$_f" -le 50 ]; then echo "OK"
  elif [ "$_f" -le 200 ]; then echo "FLAKY"
  else echo "BAD"; fi
}

vcolor() {
  case "$1" in GOOD) echo "$GR" ;; OK) echo "$GR" ;; FLAKY) echo "$YL" ;; *) echo "$RD" ;; esac
}

print_progress() {
  IFS="$TAB" read -r _s _ok _tot _mn _md _p9 _xi _xc _sp _nm < "$2"
  _v=$(verdict "$_s" "$_ok" "$_tot")
  printf '  [%*d/%d] %s%-12s%s %5s  med %-6s  %-15s %-3s %s\n' \
    "${#COUNT}" "$1" "$COUNT" "$(vcolor "$_v")" "$_v" "$R0" "$_ok/$_tot" "$_md" "$_xi" "$_xc" "$_nm"
}


# --- nightly auto-update -----------------------------------------------------

shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

nightly_on() { [ -f "$CONF" ] && grep -q 'podkop-probe --cron' "$CRONTAB" 2>/dev/null; }

nightly_status() {
  if nightly_on; then
    ( . "$CONF"; printf 'ON at %s, %s subscription(s), best %s, %s' "${NIGHTLY:-?}" "$(printf '%s' "$SUBS" | grep -c .)" "$TOP" "$(countries_label)" )
  else
    echo "off"
  fi
}

# copy this script to $BIN (download it when we run from a pipe)
install_self() {
  _src=""
  case "$0" in /dev/*|/proc/*|sh|-sh|ash|-ash) ;; *) [ -f "$0" ] && _src=$0 ;; esac
  if [ -n "$_src" ] && grep -q '^VERSION=' "$_src"; then
    [ "$_src" -ef "$BIN" ] && return 0
    cp "$_src" "$BIN.new" || return 1
  else
    set -f
    for _u in $SELF_URLS; do
      fetch "$_u" > "$BIN.new" 2>/dev/null && grep -q '^VERSION=' "$BIN.new" && break
      rm -f "$BIN.new"
    done
    set +f
  fi
  [ -s "$BIN.new" ] || return 1
  chmod +x "$BIN.new" && mv "$BIN.new" "$BIN"
}

nightly_install() {
  case "$NIGHTLY" in [0-9]:[0-5][0-9]|[01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
    *) die "time must be HH:MM, got '$NIGHTLY'" ;; esac
  [ -n "$SUBS" ] || die "nightly auto-update needs at least one subscription URL (-s)"
  [ -d "${CRONTAB%/*}" ] || die "no ${CRONTAB%/*}: cron is not available here"
  install_self || die "could not install $BIN"
  {
    echo "# podkop-probe nightly settings. Edit freely, or re-run: podkop-probe"
    echo "SUBS=$(shq "$SUBS")"
    echo "TOP=$TOP"; echo "N=$N"; echo "C=$C"; echo "T=$T"
    echo "SECTION=$(shq "$SECTION")"
    echo "URL=$(shq "$URL")"
    echo "SPEED=$SPEED"
    [ -n "$SPEED_J" ] && echo "SPEED_J=$SPEED_J"
    echo "COUNTRIES=$(shq "$COUNTRIES")"
    [ -n "$SPEED_URL" ] && echo "SPEED_URL=$(shq "$SPEED_URL")"
    echo "NIGHTLY=$(shq "$NIGHTLY")"
  } > "$CONF" || die "cannot write $CONF"
  chmod 600 "$CONF"
  _h=$(( $(echo "${NIGHTLY%%:*}" | sed 's/^0//') + 0 )); _mi=$(( $(echo "${NIGHTLY#*:}" | sed 's/^0//') + 0 ))
  touch "$CRONTAB"
  sed -i '/podkop-probe --cron/d' "$CRONTAB"
  echo "$_mi $_h * * * $BIN --cron >/tmp/podkop-probe.log 2>&1" >> "$CRONTAB"
  /etc/init.d/cron enable 2>/dev/null; /etc/init.d/cron restart >/dev/null 2>&1
  for _f in "$BIN" "$CONF"; do
    grep -qxF "$_f" /etc/sysupgrade.conf 2>/dev/null || echo "$_f" >> /etc/sysupgrade.conf
  done
  info "nightly auto-update is ON: every day at $NIGHTLY"
  info "  subscriptions: $(printf '%s' "$SUBS" | grep -c .), $(countries_label), best $TOP node(s) go to podkop section '$SECTION'"
  info "  settings: $CONF   last run log: /tmp/podkop-probe.log"
  info "  run it now: $BIN --cron    turn off: $BIN --nightly-off"
}

nightly_remove() {
  [ -f "$CRONTAB" ] && sed -i '/podkop-probe --cron/d' "$CRONTAB"
  rm -f "$CONF"
  /etc/init.d/cron restart >/dev/null 2>&1
  info "nightly auto-update is OFF ($BIN is kept, delete it if you like)"
}

ask_time() {
  printf 'Time to run every night, HH:MM [%s]: ' "${NIGHTLY:-04:00}"
  read -r _t < "$TTY" || return 1
  NIGHTLY=${_t:-${NIGHTLY:-04:00}}
}

nightly_menu() {
  echo
  if nightly_on; then
    printf 'Nightly auto-update: %s\n' "$(nightly_status)"
    ( . "$CONF"; printf '%s' "$SUBS" | sed 's/^/  /' )
    echo "  1) change it   2) turn it off   Enter) back"
    printf '> '; read -r _m < "$TTY" || return
    case "$_m" in
      1) ;;
      2) nightly_remove; return ;;
      *) return ;;
    esac
    _old=$( . "$CONF"; printf '%s' "$SUBS" ); _oldt=$( . "$CONF"; printf '%s' "$NIGHTLY" )
    echo "(empty line right away keeps the current subscriptions)"
    ask_subs || SUBS=$_old
    NIGHTLY=$_oldt
    ask_countries
  else
    echo "Every night the router re-tests your subscriptions and puts the best"
    echo "$TOP nodes (by ping and speed) into podkop as URLTest, then restarts podkop."
    ask_subs || die "no subscription URL given"
    ask_countries
  fi
  ask_time || return
  nightly_install
}

# --- main --------------------------------------------------------------------

if [ "$NIGHTLY_OFF" = 1 ]; then nightly_remove; exit 0; fi
if [ -n "$NIGHTLY" ] && [ "$CRON" = 0 ]; then
  # fetch needs curl or wget only; no test run here
  nightly_install; exit 0
fi

if [ "$CRON" = 1 ]; then
  mkdir /tmp/podkop-probe.lock 2>/dev/null || { echo "another run is in progress" >&2; exit 1; }
  trap 'rmdir /tmp/podkop-probe.lock 2>/dev/null' EXIT
  echo "=== $(date) nightly run"
fi

cleanup() {
  for _f in "$WORK"/pids/*; do [ -f "$_f" ] && kill "$(cat "$_f")" 2>/dev/null; done
  rm -rf "$WORK"
  [ "$CRON" = 1 ] && rmdir /tmp/podkop-probe.lock 2>/dev/null
}
mkdir -p "$WORK/n" "$WORK/pids" || die "cannot create $WORK"
trap cleanup EXIT
trap 'echo; warn "interrupted"; exit 130' INT TERM
: > "$NODES"

printf '%spodkop-probe %s%s  %s%s%s\n' "$BD" "$VERSION" "$R0" "$DM" "$REPO_URL" "$R0"
_model=$(cat /tmp/sysinfo/model 2>/dev/null)
_os=$(sed -n "s/^DISTRIB_DESCRIPTION='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null)
[ -n "$_model$_os" ] && printf '%s%s %s%s\n' "$DM" "$_model" "$_os" "$R0"

# sing-box is the one hard requirement
if ! command -v sing-box >/dev/null 2>&1; then
  need_tool sing-box sing-box "it runs the proxy nodes" ||
    die "sing-box not found. Install podkop first: $PODKOP_INSTALL"
fi
need_tool curl curl "it sends the test requests" || die "curl is required"

SB_VER=$(sing-box version 2>/dev/null | awk 'NR == 1 {print $3}')
SB_DNS=""; SB_RES=""
case "$SB_VER" in
  0.*|1.[0-9]|1.[0-9].*|1.1[01]|1.1[01].*) ;;
  *) SB_DNS='"dns":{"servers":[{"type":"local","tag":"local"}]},'
     SB_RES=',"default_domain_resolver":"local"' ;;
esac

# collect nodes
if [ -n "$ARGLINKS" ]; then printf '%s' "$ARGLINKS" | add_links; SOURCE="command line"; fi
if [ -n "$FILE" ]; then
  case "$FILE" in
    -) add_links ;;
    http://*|https://*) fetch "$FILE" | add_links ;;
    *) [ -f "$FILE" ] || die "file not found: $FILE"; add_links < "$FILE" ;;
  esac
  SOURCE="${SOURCE:+$SOURCE + }$FILE"
fi
MODE=""
if [ -z "$ARGLINKS$FILE$SUBS$CONFIG" ] && [ -n "$TTY" ] && [ "$ASSUME_YES" = 0 ]; then
  menu
  [ "$MODE" = paste ] && ask_links
fi
[ -n "$SUBS" ] && from_subs
if [ -n "$CONFIG" ]; then from_config "$CONFIG"; SOURCE="${SOURCE:+$SOURCE + }$CONFIG"; fi

if [ "$(count_nodes)" -eq 0 ] && [ -z "$SOURCE" ]; then
  if _cfg=$(podkop_config_path) && { command -v jq >/dev/null 2>&1 || need_tool jq jq "needed to read podkop's sing-box config"; }; then
    from_config "$_cfg"; SOURCE="podkop sing-box config $_cfg"
  fi
  if [ "$(count_nodes)" -eq 0 ] && from_uci && [ "$(count_nodes)" -gt 0 ]; then
    SOURCE="podkop settings (/etc/config/podkop)"
  fi
  [ "$(count_nodes)" -gt 0 ] || ask_links
fi

# drop duplicates (the same link in several subscriptions differs only in #name)
awk '{ k = $0; if (substr(k, 1, 1) == "L") sub(/#.*/, "", k) } !seen[k]++' "$NODES" > "$NODES.u"
mv "$NODES.u" "$NODES"
COUNT=$(count_nodes)
if [ "$COUNT" -eq 0 ]; then
  warn "no proxy nodes found${SOURCE:+ in $SOURCE}"
  echo "Is podkop installed and configured? Or pass links / -s URL / -f FILE. See -h." >&2
  exit 1
fi

_i=0; OUT_REGION=0
while IFS= read -r _line; do
  _i=$((_i + 1)); _d="$WORK/n/$_i"; mkdir -p "$_d"
  case "$_line" in
    L"$TAB"*) ( build_link "${_line#L"$TAB"}" "$_d" ) ;;
    O"$TAB"*)
      _r=${_line#O"$TAB"}
      printf '%s\n' "${_r%%"$TAB"*}" > "$_d/name"
      printf '%s\n' "${_r#*"$TAB"}" > "$_d/ob.json" ;;
  esac
  [ -f "$_d/ob.json" ] || [ -f "$_d/skip" ] || echo "build failed" > "$_d/skip"
  _ncc=$(name_cc "$(cat "$_d/name")"); echo "$_ncc" > "$_d/ncc"
  if ! cc_allowed "$_ncc"; then           # e.g. "🇺🇸 USA" when only Europe is wanted
    rm -rf "$_d"; _i=$((_i - 1)); OUT_REGION=$((OUT_REGION + 1))
  fi
done < "$NODES"
COUNT=$_i

HAS_PARALLEL=0
curl --help all 2>/dev/null | grep -q -- '--parallel-immediate' && HAS_PARALLEL=1

# drop nodes whose server IP is outside the wanted countries, e.g. relays
# "via RU" whose entry point is in Russia
OUT_ENTRY=0
case "$COUNTRIES" in all|"") ;; *)
  if [ "$ENTRY_CHECK" = 1 ] && [ "$COUNT" -gt 0 ]; then
    info "checking where the $COUNT server(s) are ..."
    entry_countries
    _i=0; _j=0
    while [ "$_i" -lt "$COUNT" ]; do
      _i=$((_i + 1))
      if cc_allowed "$(cat "$WORK/n/$_i/ecc" 2>/dev/null || echo -)"; then
        _j=$((_j + 1)); [ "$_j" -ne "$_i" ] && mv "$WORK/n/$_i" "$WORK/n/$_j"
      else
        rm -rf "$WORK/n/$_i"; OUT_ENTRY=$((OUT_ENTRY + 1))
      fi
    done
    COUNT=$_j
  fi ;;
esac

if [ "$COUNT" -eq 0 ]; then
  warn "all node(s) are outside $(countries_label)"
  exit 1
fi

# latency tests of up to 4 nodes run side by side: they are small requests
# that don't disturb each other (~40 MB of RAM per node). Speed tests always
# run one at a time afterwards, with nothing else going on.
_mem=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null)
_max=$(( ${_mem:-160} / 40 )); [ "$_max" -lt 1 ] && _max=1
if [ -z "$J" ]; then
  J=4; [ "$J" -gt "$_max" ] && J=$_max
elif [ "$J" -gt "$_max" ]; then
  warn "-j $J needs more free RAM, using $_max"; J=$_max
fi
[ "$J" -gt "$COUNT" ] && J=$COUNT

# request list, shared by all nodes; "Connection: close" makes every request
# open a fresh tunnel through the node, which is what we want to measure
# req_cfg <count>: curl config with <count> requests
req_cfg() {
  [ "$1" -gt 0 ] || return 0
  echo 'http1.1'
  echo 'header = "Connection: close"'
  _k=0; while [ "$_k" -lt "$1" ]; do printf 'url = "%s"\noutput = "/dev/null"\n' "$URL"; _k=$((_k + 1)); done
}
N0=$C; [ "$N0" -gt "$N" ] && N0=$N
N1=$(( N / 2 - N0 )); [ "$N1" -lt 0 ] && N1=0
req_cfg "$N0" > "$WORK/req0.cfg"
req_cfg "$N1" > "$WORK/req1.cfg"
req_cfg $(( N - N0 - N1 )) > "$WORK/req2.cfg"

if sleep 0.1 2>/dev/null; then NAP=0.2; WAIT_TICKS=75; else NAP=1; WAIT_TICKS=15; fi

set -- $(exit_ip)
DIRECT_IP=${1:-none}; DIRECT_CC=${2:--}

echo
info "source:    ${SOURCE:-?}"
_sk=""
[ "$OUT_REGION" -gt 0 ] && _sk="$OUT_REGION by name"
[ "$OUT_ENTRY" -gt 0 ] && _sk="${_sk:+$_sk, }$OUT_ENTRY by server IP"
info "nodes:     $COUNT, $J at a time${_sk:+ (skipped outside $(countries_label): $_sk)}"
info "countries: $(countries_label)"
info "test:      $N requests per node, $C in flight, timeout ${T}s -> $URL"
[ "$SPEED" = 1 ] && info "speed:     up to ${SPEED_T}s download per node (nodes losing >20% are skipped)"
info "router IP: $DIRECT_IP ($DIRECT_CC)   sing-box $SB_VER"
echo

START=$(date +%s)
mkfifo "$WORK/sem" || die "mkfifo failed"
exec 3<>"$WORK/sem"
_k=0; while [ "$_k" -lt "$J" ]; do echo >&3; _k=$((_k + 1)); done

_i=0
while [ "$_i" -lt "$COUNT" ]; do
  _i=$((_i + 1))
  read -r _ <&3
  ( run_node "$_i"; echo >&3 ) &
done
wait
exec 3>&-

# --- speed test --------------------------------------------------------------

# nodes that lost at most 20%, best latency first; one download at a time
if [ "$SPEED" = 1 ]; then
  : > "$WORK/speedlist"
  _i=0
  while [ "$_i" -lt "$COUNT" ]; do
    _i=$((_i + 1))
    IFS="$TAB" read -r _s _ok _tot _mn _md _rest < "$WORK/n/$_i/result" || continue
    case "$_s" in ok|noexit) ;; *) continue ;; esac
    [ "$_ok" -gt 0 ] || continue
    [ $(( (_tot - _ok) * 5 )) -le "$_tot" ] || continue
    printf '%s\t%s\t%s\n' "$_md" "$_i" "$(same_key "$_i")" >> "$WORK/speedlist"
  done
  sort -t "$TAB" -k1,1g "$WORK/speedlist" -o "$WORK/speedlist"
  # one test per server/port/transport; duplicates get its result afterwards
  awk -F "$TAB" '!seen[$3]++ { print $2 }' "$WORK/speedlist" > "$WORK/speed.uniq"
  _ns=$(wc -l < "$WORK/speed.uniq" | tr -d ' ')
  if [ "$_ns" -gt 0 ]; then
    echo
    if [ -z "$SPEED_J" ]; then
      # how many tests fit on the line at once: measure it directly, then
      # allow one test per ~200 Mbit/s (a node rarely gives more than ~150)
      SPEED_J=1
      if [ "$_ns" -gt 1 ]; then
        _line=$(curl -s -o /dev/null --max-time 5 -w '%{size_download} %{time_total}' "$LINE_URL" 2>/dev/null |
          awk '$2 > 0 && $1 > 1000000 { printf "%.0f", $1 * 8 / $2 / 1000000 }')
        if [ -n "$_line" ]; then
          SPEED_J=$(( _line / 200 )); [ "$SPEED_J" -lt 1 ] && SPEED_J=1; [ "$SPEED_J" -gt 3 ] && SPEED_J=3
          info "your line (direct): ~$_line Mbit/s"
        fi
      fi
    fi
    [ "$SPEED_J" -gt "$_ns" ] && SPEED_J=$_ns
    info "speed test: $_ns server(s), $SPEED_J at a time, until the result is stable (max ${SPEED_T}s)"
    mkfifo "$WORK/ssem" && exec 5<>"$WORK/ssem"
    _k=0; while [ "$_k" -lt "$SPEED_J" ]; do echo >&5; _k=$((_k + 1)); done
    : > "$WORK/speed.done"
    while IFS= read -r _n; do
      read -r _ <&5
      (
        speed_node "$_n"
        echo "$_n" >> "$WORK/speed.done"
        printf '  [%*d/%d] %7s Mbit/s  %s\n' "${#_ns}" "$(wc -l < "$WORK/speed.done")" "$_ns" \
          "$(cat "$WORK/n/$_n/speed")" "$(cat "$WORK/n/$_n/name")"
        echo >&5
      ) &
    done < "$WORK/speed.uniq"
    wait
    exec 5>&-
    # copy results to the duplicates
    awk -F "$TAB" -v OFS="$TAB" '!($3 in f) { f[$3] = $2 } { print $2, f[$3] }' "$WORK/speedlist" > "$WORK/speed.map"
    while IFS="$TAB" read -r _n _src; do
      [ "$_n" = "$_src" ] && continue
      [ -f "$WORK/n/$_src/speed" ] && cp "$WORK/n/$_src/speed" "$WORK/n/$_n/speed"
      [ -f "$WORK/n/$_src/speed.why" ] && cp "$WORK/n/$_src/speed.why" "$WORK/n/$_n/speed.why"
    done < "$WORK/speed.map"
  fi
fi

# --- ranking -----------------------------------------------------------------

# all rows: n status ok total min median p90 ip cc speed name
_i=0
: > "$WORK/all"
while [ "$_i" -lt "$COUNT" ]; do
  _i=$((_i + 1))
  [ -f "$WORK/n/$_i/result" ] || continue
  _sp=$(cat "$WORK/n/$_i/speed" 2>/dev/null)
  awk -F "$TAB" -v OFS="$TAB" -v n="$_i" -v sp="${_sp:--}" '{ $9 = sp; print n, $0 }' "$WORK/n/$_i/result" >> "$WORK/all"
done
ELAPSED=$(( $(date +%s) - START ))

# classes: 0 = lost <=5% (and speed test passed), 1 = lost <=20% or speed test
# failed, 2 = worse, 3 = wrong country / not via node, 4 = skipped / no start.
# Inside classes 0-1 the score is  median / best median  +  best speed / speed
# (1 + 1 = 2 for a node that is best at both; lower is better), so 20% more
# latency weighs the same as 20% less speed.
awk -F "$TAB" -v OFS="$TAB" -v speed="$SPEED" '
{ row[NR] = $0
  st = $2; ok = $3 + 0; tot = $4 + 0
  fail = tot > 0 ? (tot - ok) / tot : 1
  M[NR] = ($6 == "-") ? 0 : $6 + 0; S[NR] = ($10 == "-") ? 0 : $10 + 0
  if ((st == "ok" || st == "noexit") && ok > 0) {
    cls = (fail <= 0.05) ? 0 : (fail <= 0.2 ? 1 : 2)
    if (cls == 0 && speed == 1 && S[NR] <= 0) cls = 1
  }
  else if (st == "direct" || st == "region") cls = 3
  else if (st == "ok" || st == "noexit") cls = 2
  else cls = 4
  C[NR] = cls; F[NR] = fail
  if (cls <= 1 && M[NR] > 0 && (bm == 0 || M[NR] < bm)) bm = M[NR]
  if (cls <= 1 && S[NR] > bs) bs = S[NR]
}
END {
  for (i = 1; i <= NR; i++) {
    sc = 99
    if (C[i] <= 1 && M[i] > 0) sc = M[i] / bm + ((speed == 1 && bs > 0) ? ((S[i] > 0) ? bs / S[i] : 10) : 0)
    printf "%d\t%.4f\t%.6f\t%s\n", C[i], sc, F[i], row[i]
  }
}' "$WORK/all" | sort -t "$TAB" -k1,1n -k2,2g -k3,3g | cut -f 4- > "$WORK/sorted"

# pick the best TOP nodes that came from links (config outbounds have no
# link): usable classes only, and one link per exit IP, since several links
# to the same server add nothing to a URLTest group
: > "$WORK/best"; : > "$WORK/best.names"; : > "$WORK/best.ips"
pick() { # <n>: add node n to the pick list
  cat "$WORK/n/$1/link" >> "$WORK/best"
  IFS="$TAB" read -r _s _ok _tot _mn _md _p9 _xi _xc _sp _nm < "$WORK/n/$1/result"
  printf '#%-3s median %6ss %7s Mbit/s  %s\n' "$1" "$_md" "$_sp" "$_nm" >> "$WORK/best.names"
  echo "$_xi" >> "$WORK/best.ips"
}
while IFS="$TAB" read -r _n _s _ok _tot _mn _md _p9 _xi _xc _sp _nm; do
  [ "$(wc -l < "$WORK/best")" -ge "$TOP" ] && break
  [ -f "$WORK/n/$_n/link" ] || continue
  case "$(verdict "$_s" "$_ok" "$_tot")" in GOOD|OK|FLAKY) ;; *) continue ;; esac
  [ "$_xi" != "-" ] && grep -qxF "$_xi" "$WORK/best.ips" && continue
  pick "$_n"
done < "$WORK/sorted"
# not enough different servers: fill up with the next best links anyway
while IFS="$TAB" read -r _n _s _ok _tot _mn _md _p9 _xi _xc _sp _nm; do
  [ "$(wc -l < "$WORK/best")" -ge "$TOP" ] && break
  [ -f "$WORK/n/$_n/link" ] || continue
  case "$(verdict "$_s" "$_ok" "$_tot")" in GOOD|OK|FLAKY) ;; *) continue ;; esac
  grep -q "^#$_n " "$WORK/best.names" || pick "$_n"
done < "$WORK/sorted"

# --- report ------------------------------------------------------------------

echo
printf '%s  %-3s %-12s %8s %6s %7s %7s %7s %7s  %-15s %-3s %s%s\n' "$BD" "#" "verdict" "ok" "fail%" "min" "median" "p90" "Mbit/s" "exit IP" "cc" "node" "$R0"
_good=0; _okn=0; _bad=0; _skp=0; BEST=""
while IFS="$TAB" read -r _n _s _ok _tot _mn _md _p9 _xi _xc _sp _nm; do
  _v=$(verdict "$_s" "$_ok" "$_tot")
  _fp="-"; [ "$_tot" -gt 0 ] && _fp=$(awk -v o="$_ok" -v t="$_tot" 'BEGIN {printf "%.1f", (t - o) * 100 / t}')
  _mk=" "; grep -q "^#$_n " "$WORK/best.names" && _mk="*"
  printf '%s %-3s %s%-12s%s %8s %6s %7s %7s %7s %7s  %-15s %-3s %s\n' \
    "$_mk" "$_n" "$(vcolor "$_v")" "$_v" "$R0" "$_ok/$_tot" "$_fp" "$_mn" "$_md" "$_p9" "$_sp" "$_xi" "$_xc" "$_nm"
  case "$_v" in GOOD) _good=$((_good + 1)) ;; OK|FLAKY) _okn=$((_okn + 1)) ;; SKIPPED) _skp=$((_skp + 1)) ;; *) _bad=$((_bad + 1)) ;; esac
  [ -z "$BEST" ] && case "$_v" in GOOD|OK|FLAKY) BEST="$_nm (#$_n, median ${_md}s, $_sp Mbit/s)" ;; esac
done < "$WORK/sorted"

echo
printf 'Summary: %s%d good%s, %s%d usable%s, %s%d not working%s%s — %ds total\n' \
  "$GR" "$_good" "$R0" "$YL" "$_okn" "$R0" "$RD" "$_bad" "$R0" \
  "$( [ "$_skp" -gt 0 ] && echo ", $_skp skipped (can't run in sing-box/podkop)")" "$ELAPSED"
[ -n "$BEST" ] && printf 'Best node: %s%s%s\n' "$BD" "$BEST" "$R0"

# explain problems in plain words
_hdr=0
while IFS="$TAB" read -r _n _s _ok _tot _mn _md _p9 _xi _xc _sp _nm; do
  _why=""
  case "$_s" in
    skip)   cat "$WORK/n/$_n/skip" >> "$WORK/skipped"; continue ;;
    start)  _why="sing-box did not start: $(grep -v '^[[:space:]]*$' "$WORK/n/$_n/sb.log" 2>/dev/null | tail -n 1 | cut -c 1-200)" ;;
    direct) _why="exit IP equals the router's own IP: traffic did not go through the node, results are void" ;;
    region) _why="exit country $_xc is outside $(countries_label), not chosen" ;;
    noexit) _why="could not learn the exit IP through the node (ipinfo.io / ipify blocked or node down)" ;;
  esac
  case "$_s" in ok|noexit)
    [ "$_ok" -eq 0 ] && _why="all $_tot requests failed: node unreachable, blocked, or wrong credentials" ;;
  esac
  [ "$_sp" = "0.0" ] && _why="${_why:+$_why; }speed test failed: $(cat "$WORK/n/$_n/speed.why" 2>/dev/null || echo "no data")"
  [ -n "$_why" ] || continue
  [ "$_hdr" = 0 ] && { echo; printf '%sProblems:%s\n' "$BD" "$R0"; _hdr=1; }
  printf '  #%-3s %s: %s\n' "$_n" "$_nm" "$_why"
done < "$WORK/sorted"

# skipped links, one line per reason
if [ -s "$WORK/skipped" ]; then
  [ "$_hdr" = 0 ] && { echo; printf '%sProblems:%s\n' "$BD" "$R0"; }
  sort "$WORK/skipped" | uniq -c | while read -r _c _why; do
    printf '  %s link(s) skipped: %s\n' "$_c" "$_why"
  done
fi

if [ "$VERBOSE" = 1 ]; then
  echo
  printf '%sPer-request results (http_code seconds, 000 = failed):%s\n' "$BD" "$R0"
  while IFS="$TAB" read -r _n _s _ok _tot _rest; do
    printf -- '--- #%s %s\n' "$_n" "$(cat "$WORK/n/$_n/name")"
    awk '{ c[$1]++ } END { for (k in c) printf "  http %s x%d\n", (k == "000" ? "000 (failed)" : k), c[k] }' "$WORK/n/$_n/times"
    awk '$1 != "000" { print $2 }' "$WORK/n/$_n/times" | sort -n | tr '\n' ' ' | fold -w 78 | sed 's/^/  /'; echo
    [ -s "$WORK/n/$_n/sb.log" ] && { echo "sing-box log:"; tail -n 5 "$WORK/n/$_n/sb.log"; }
  done < "$WORK/sorted"
fi

if [ -n "$CSV" ]; then
  { echo "n,verdict,ok,total,min,median,p90,mbit_s,exit_ip,country,node"
    while IFS="$TAB" read -r _n _s _ok _tot _mn _md _p9 _xi _xc _sp _nm; do
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s"\n' "$_n" "$(verdict "$_s" "$_ok" "$_tot")" \
        "$_ok" "$_tot" "$_mn" "$_md" "$_p9" "$_sp" "$_xi" "$_xc" "$(printf '%s' "$_nm" | sed 's/"/""/g')"
    done < "$WORK/sorted"
  } > "$CSV" && info "saved $CSV"
fi

echo
printf '%sLegend:%s ok = successful requests; min/median/p90 = seconds per request\n' "$DM" "$R0"
printf '%s        (new connection through the node + HTTPS to the target each time);%s\n' "$DM" "$R0"
printf '%s        Mbit/s = download speed through the node (up to %ss, one node at a time).%s\n' "$DM" "$SPEED_T" "$R0"
printf '%s        GOOD 0%% fail, OK <=5%%, FLAKY <=20%%, BAD >20%%, DEAD = nothing got through.%s\n' "$DM" "$R0"
printf '%s        Order: fewest failures, then latency and speed together; * = picked.%s\n' "$DM" "$R0"

# --- put the best nodes into podkop ------------------------------------------

apply_podkop() {
  _cur=$(uci -q get "podkop.$SECTION.urltest_proxy_links" | tr ' ' '\n' | sort)
  if [ "$(uci -q get "podkop.$SECTION.proxy_config_type")" = urltest ] && [ "$_cur" = "$(sort "$WORK/best")" ]; then
    info "podkop already uses exactly these nodes, nothing to change"
    return 0
  fi
  _cfg=/etc/config/podkop
  _bak="$_cfg.probe-backup.$(date +%Y%m%d-%H%M%S)"
  cp "$_cfg" "$_bak" || die "cannot back up $_cfg"
  # keep only the 3 newest backups
  ls -1t "$_cfg".probe-backup.* 2>/dev/null | tail -n +4 | while IFS= read -r _f; do rm -f "$_f"; done
  uci -q delete "podkop.$SECTION.urltest_proxy_links"
  uci set "podkop.$SECTION.connection_type=proxy"
  uci set "podkop.$SECTION.proxy_config_type=urltest"
  while IFS= read -r _l; do uci add_list "podkop.$SECTION.urltest_proxy_links=$_l"; done < "$WORK/best"
  uci commit podkop || die "uci commit failed, your old config is in $_bak"
  _msg="podkop.$SECTION: URLTest with $(wc -l < "$WORK/best" | tr -d ' ') node(s); old config saved to $_bak"
  info "$_msg"
  info "restarting podkop ..."
  if /etc/init.d/podkop restart; then
    info "done. Check the state in LuCI -> Services -> Podkop."
    [ "$CRON" = 1 ] && logger -t podkop-probe "$_msg" 2>/dev/null
  else
    warn "podkop restart failed. Restore with: cp $_bak $_cfg && /etc/init.d/podkop restart"
    [ "$CRON" = 1 ] && logger -t podkop-probe "podkop restart failed after update, backup: $_bak" 2>/dev/null
  fi
}

if [ "$APPLY" != no ] && [ -s "$WORK/best" ] && case "$SOURCE" in podkop*) false ;; *) true ;; esac; then
  _nb=$(wc -l < "$WORK/best" | tr -d ' ')
  cp "$WORK/best" "/tmp/podkop-probe-best.txt" 2>/dev/null &&
    info "best $_nb link(s) saved to /tmp/podkop-probe-best.txt"
  if [ -f /etc/config/podkop ] && command -v uci >/dev/null 2>&1; then
    uci -q get "podkop.$SECTION" >/dev/null || die "podkop has no section '$SECTION' (use --section)"
    echo
    printf '%sBest %s node(s) to put into podkop (lowest latency + fastest, one per server where possible):%s\n' "$BD" "$_nb" "$R0"
    sed 's/^/  /' "$WORK/best.names"
    if [ "$APPLY" != yes ] && [ -n "$TTY" ]; then
      printf 'Press Enter to take these, or type the # numbers you want instead (e.g. 35 41 44): '
      read -r _sel < "$TTY" || _sel=""
      _sel=$(printf '%s' "$_sel" | tr -c '0-9\n' ' ')
      if [ -n "$(printf '%s' "$_sel" | tr -d ' ')" ]; then
        : > "$WORK/best"; : > "$WORK/best.names"; : > "$WORK/best.ips"
        for _n in $_sel; do
          if [ -f "$WORK/n/$_n/link" ] && [ -f "$WORK/n/$_n/result" ]; then
            grep -q "^#$_n " "$WORK/best.names" || pick "$_n"
          else
            warn "#$_n is not a tested node with a link, ignored"
          fi
        done
        _nb=$(wc -l < "$WORK/best" | tr -d ' ')
        [ "$_nb" -gt 0 ] || { info "nothing chosen, podkop settings left unchanged"; exit 0; }
        cp "$WORK/best" "/tmp/podkop-probe-best.txt" 2>/dev/null
        printf '%sYour choice:%s\n' "$BD" "$R0"
        sed 's/^/  /' "$WORK/best.names"
      fi
    fi
    if [ "$APPLY" = yes ] || ask_yn "Replace podkop '$SECTION' proxy with a URLTest of these $_nb node(s) and restart podkop"; then
      apply_podkop
    else
      info "podkop settings left unchanged"
    fi
  fi
elif [ "$CRON" = 1 ]; then
  warn "no working nodes found, podkop settings left unchanged"
  logger -t podkop-probe "no working nodes found, podkop left unchanged" 2>/dev/null
fi

# offer to repeat this every night
if [ -n "$SUBS" ] && [ "$CRON" = 0 ] && [ -n "$TTY" ] && [ "$ASSUME_YES" = 0 ] && [ -d "${CRONTAB%/*}" ]; then
  _same=0
  nightly_on && [ "$( . "$CONF"; printf '%s' "$SUBS" )" = "$(printf '%s' "$SUBS")" ] && _same=1
  if [ "$_same" = 0 ]; then
    echo
    if ask_yn "Do this automatically every night (re-test these subscriptions, update podkop)"; then
      ask_time && nightly_install
    fi
  fi
fi
exit 0
