#!/bin/sh
# shellcheck shell=dash disable=SC1090,SC2012,SC2016,SC2046,SC2154,SC2317
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

VERSION="1.1.0"
REPO_URL="https://github.com/dkagramanyan/podkop-keys-availability-"
SELF_URLS="$REPO_URL/releases/latest/download/probe.sh
https://raw.githubusercontent.com/dkagramanyan/podkop-keys-availability-/main/probe.sh"
BIN=/usr/bin/podkop-probe
CONF=/etc/podkop-probe.conf
CRONTAB=/etc/crontabs/root
PODKOP_INSTALL="sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh)"

set -u
export LC_ALL=C

N=30; C=5; J=""; T=10
URL="https://www.gstatic.com/generate_204"
BASEPORT=39000
FILE=""; SUBS=""; CONFIG=""; CSV=""
VERBOSE=0; ASSUME_YES=0; COLOR=auto; SOURCE=""
TOP=10; APPLY=ask; SECTION=main
SPEED=1; SPEED_URL="https://speed.cloudflare.com/__down?bytes=10000000"; SPEED_T=10
NIGHTLY=""; NIGHTLY_OFF=0; CRON=0
UA="v2rayNG/1.9.0"
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

Test:
  -n N              requests per node               (default $N)
  -c N              requests in flight per node     (default $C)
  -j N              nodes tested at the same time   (default: by free RAM, max 4)
  -t SEC            timeout per request, seconds    (default $T)
  -u URL            target URL                      (default $URL)
  -q                quick run:    -n 10
  -F                thorough run: -n 100 -c 10
  -p PORT           first local SOCKS port          (default $BASEPORT)
  --no-speed        skip the download speed test
  --speed-url URL   file for the speed test (default: 10 MB from Cloudflare)

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
    -f|-s|-C|--config|-n|-c|-j|-t|-u|-p|-o|--top|--section|--speed-url|--nightly)
      [ $# -ge 2 ] || { echo "option $1 needs a value" >&2; usage 1; }
      case "$1" in
        -f) FILE="$2" ;; -s) SUBS="$SUBS$2
" ;; -C|--config) CONFIG="$2" ;;
        -n) N="$2" ;; -c) C="$2" ;; -j) J="$2" ;; -t) T="$2" ;;
        -u) URL="$2" ;; -p) BASEPORT="$2" ;; -o) CSV="$2" ;;
        --top) TOP="$2" ;; --section) SECTION="$2" ;;
        --speed-url) SPEED_URL="$2" ;; --nightly) NIGHTLY="$2" ;;
      esac
      shift 2 ;;
    -q) N=10; shift ;;
    -F) N=100; C=10; shift ;;
    -v) VERBOSE=1; shift ;;
    -y) ASSUME_YES=1; shift ;;
    --apply) APPLY=yes; shift ;;
    --no-apply) APPLY=no; shift ;;
    --no-speed) SPEED=0; shift ;;
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
fi

for _v in N C T BASEPORT TOP; do
  eval "_x=\$$_v"; is_uint "$_x" || die "$_v must be a positive number, got '$_x'"
done
[ -z "$J" ] || is_uint "$J" || die "-j must be a positive number"
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
        { skip "transport '${q_type:-}' is not supported by sing-box"; return; }
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
        { skip "transport '${v_net:-}' is not supported by sing-box"; return; }
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

# from_sub <url> <label>
from_sub() {
  _host=${1#*://}; _host=${_host%%/*}
  fetch "$1" > "$WORK/sub" 2>/dev/null || { warn "$2 ($_host): download failed"; return 1; }
  _before=$(count_nodes)
  add_links < "$WORK/sub"
  [ "$(count_nodes)" -gt "$_before" ] ||
    { warn "$2 ($_host): no vless/vmess/trojan/ss/hysteria2 links inside"; return 1; }
  info "$2 ($_host): $(( $(count_nodes) - _before )) link(s)"
}

from_subs() {
  _total=$(printf '%s' "$SUBS" | grep -c .); _k=0; _oks=0
  set -f
  for _u in $SUBS; do
    _k=$((_k + 1))
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
    2) ask_subs || die "no subscription URL given"; MODE=sub ;;
    3) MODE="paste" ;;
    4) nightly_menu; exit 0 ;;
    *) exit 0 ;;
  esac
}

count_nodes() { [ -s "$NODES" ] && wc -l < "$NODES" | tr -d ' ' || echo 0; }

# --- per-node worker ---------------------------------------------------------

port_busy() { grep -q ":$(printf '%04X' "$1") 00000000:0000 0A" /proc/net/tcp 2>/dev/null; }

# sb_start <idx>: run sing-box for node idx on a free local port.
# Sets _pid and _port; fails if sing-box did not come up.
sb_start() {
  _sd="$WORK/n/$1"; _port=$((BASEPORT + $1))
  while port_busy "$_port"; do _port=$((_port + 500)); done
  printf '{"log":{"level":"error"},%s"inbounds":[{"type":"mixed","tag":"in","listen":"127.0.0.1","listen_port":%s}],"outbounds":[%s,{"type":"direct","tag":"direct"}],"route":{"final":"node"%s}}\n' \
    "$SB_DNS" "$_port" "$(cat "$_sd/ob.json")" "$SB_RES" > "$_sd/config.json"
  sing-box run -c "$_sd/config.json" > "$_sd/sb.log" 2>&1 &
  _pid=$!; echo "$_pid" > "$WORK/pids/$1"
  _sk=0
  while :; do
    kill -0 "$_pid" 2>/dev/null || return 1
    port_busy "$_port" && return 0
    _sk=$((_sk + 1)); [ "$_sk" -ge "$WAIT_TICKS" ] && return 1
    sleep "$NAP"
  done
}

sb_stop() { kill "$_pid" 2>/dev/null; rm -f "$WORK/pids/$1"; }

# speed_node <idx>: download SPEED_URL through the node -> <dir>/speed (Mbit/s)
speed_node() {
  _si=$1; _d="$WORK/n/$_si"
  if sb_start "$_si"; then
    set -- $(curl -s -o /dev/null --noproxy '' -x "socks5h://127.0.0.1:$_port" --max-time "$SPEED_T" \
      -w '%{size_download} %{speed_download}' "$SPEED_URL" 2>/dev/null)
    awk -v b="${1:-0}" -v s="${2:-0}" 'BEGIN { if (b < 100000) print "0.0"; else printf "%.1f\n", s * 8 / 1000000 }' > "$_d/speed"
  else
    echo "0.0" > "$_d/speed"
  fi
  sb_stop "$_si"
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

    if [ "$HAS_PARALLEL" = 1 ]; then
      curl -s -K "$WORK/req.cfg" -Z --parallel-max "$C" --parallel-immediate \
        --max-time "$T" --noproxy '' -x "$_px" -w '%{http_code} %{time_total}\n' >> "$_d/times" 2>/dev/null
    else
      _pids=""; _l=1
      while [ "$_l" -le "$C" ]; do
        curl -s -K "$WORK/req.$_l.cfg" --max-time "$T" --noproxy '' -x "$_px" \
          -w '%{http_code} %{time_total}\n' > "$_d/times.$_l" 2>/dev/null &
        _pids="$_pids $!"; _l=$((_l + 1))
      done
      for _p in $_pids; do wait "$_p" 2>/dev/null; done
      cat "$_d"/times.* >> "$_d/times" 2>/dev/null
    fi
    wait "$_epid" 2>/dev/null
    set -- $(cat "$_d/exit")
    _ip=${1:-}; _cc=${2:-}
    if [ -z "$_ip" ]; then _st=noexit
    elif [ "$_ip" = "$DIRECT_IP" ]; then _st=direct
    fi
    sb_stop "$_i"
  elif [ "$_st" = start ]; then
    sb_stop "$_i"
  fi

  # status ok total min median p90
  set -- $(awk '$1 != "000" {print $2}' "$_d/times" | sort -n | awk -v tot="$N" -v st="$_st" '
    { a[++k] = $1 }
    END {
      if (st == "skip" || st == "start") { print st, 0, 0, "-", "-", "-"; exit }
      if (!k) { print st, 0, tot, "-", "-", "-"; exit }
      med = (k % 2) ? a[(k + 1) / 2] : (a[k / 2] + a[k / 2 + 1]) / 2
      p = int(k * 0.9); if (p < k * 0.9) p++; if (p < 1) p = 1
      printf "%s %d %d %.3f %.3f %.3f\n", st, k, tot, a[1], med, a[p]
    }')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "${_ip:--}" "${_cc:--}" "$(cat "$_d/name")" > "$_d/result"
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
  IFS="$TAB" read -r _s _ok _tot _mn _md _p9 _xi _xc _nm < "$2"
  _v=$(verdict "$_s" "$_ok" "$_tot")
  printf '  [%*d/%d] %s%-12s%s %4s  med %-7s %-15s %-3s %s\n' \
    "${#COUNT}" "$1" "$COUNT" "$(vcolor "$_v")" "$_v" "$R0" "$_ok/$_tot" "$_md" "$_xi" "$_xc" "$_nm"
}


# --- nightly auto-update -----------------------------------------------------

shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

nightly_on() { [ -f "$CONF" ] && grep -q 'podkop-probe --cron' "$CRONTAB" 2>/dev/null; }

nightly_status() {
  if nightly_on; then
    ( . "$CONF"; printf 'ON at %s, %s subscription(s), best %s' "${NIGHTLY:-?}" "$(printf '%s' "$SUBS" | grep -c .)" "$TOP" )
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
    echo "SPEED_URL=$(shq "$SPEED_URL")"
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
  info "  subscriptions: $(printf '%s' "$SUBS" | grep -c .), best $TOP node(s) go to podkop section '$SECTION'"
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
  else
    echo "Every night the router re-tests your subscriptions and puts the best"
    echo "$TOP nodes (by ping and speed) into podkop as URLTest, then restarts podkop."
    ask_subs || die "no subscription URL given"
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

_i=0
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
done < "$NODES"

# parallelism: ~40 MB per sing-box + curl, keep 1..4 unless -j given
if [ -z "$J" ]; then
  _mem=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null)
  J=$(( ${_mem:-160} / 40 )); [ "$J" -gt 4 ] && J=4; [ "$J" -lt 1 ] && J=1
fi
[ "$J" -gt "$COUNT" ] && J=$COUNT

# request list, shared by all nodes; "Connection: close" makes every request
# open a fresh tunnel through the node, which is what we want to measure
HAS_PARALLEL=0
curl --help all 2>/dev/null | grep -q -- '--parallel-immediate' && HAS_PARALLEL=1
{
  echo 'http1.1'
  echo 'header = "Connection: close"'
  _k=0; while [ "$_k" -lt "$N" ]; do printf 'url = "%s"\noutput = "/dev/null"\n' "$URL"; _k=$((_k + 1)); done
} > "$WORK/req.cfg"
if [ "$HAS_PARALLEL" = 0 ]; then
  _l=1
  while [ "$_l" -le "$C" ]; do
    _cnt=$(( N / C )); [ "$_l" -le $(( N % C )) ] && _cnt=$((_cnt + 1))
    { echo 'http1.1'; echo 'header = "Connection: close"'
      _k=0; while [ "$_k" -lt "$_cnt" ]; do printf 'url = "%s"\noutput = "/dev/null"\n' "$URL"; _k=$((_k + 1)); done
    } > "$WORK/req.$_l.cfg"
    _l=$((_l + 1))
  done
fi

if sleep 0.1 2>/dev/null; then NAP=0.2; WAIT_TICKS=75; else NAP=1; WAIT_TICKS=15; fi

set -- $(exit_ip)
DIRECT_IP=${1:-none}; DIRECT_CC=${2:--}

echo
info "source:    ${SOURCE:-?}"
info "nodes:     $COUNT, $J at a time"
info "test:      $N requests per node, $C in flight, timeout ${T}s -> $URL"
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

# all rows: n status ok total min median p90 ip cc speed name
_i=0
: > "$WORK/all"
while [ "$_i" -lt "$COUNT" ]; do
  _i=$((_i + 1))
  [ -f "$WORK/n/$_i/result" ] && printf '%s\t%s\n' "$_i" "$(cat "$WORK/n/$_i/result")" >> "$WORK/all"
done

# the fastest-answering working nodes get a download test, one at a time so
# they don't share the router's bandwidth
if [ "$SPEED" = 1 ]; then
  awk -F "$TAB" -v OFS="$TAB" '($2 == "ok" || $2 == "noexit") && $3 > 0 && ($4 - $3) * 5 <= $4 {
    print int(($4 - $3) * 100000 / $4), $6, $1 }' "$WORK/all" |
    sort -t "$TAB" -k1,1n -k2,2g | head -n $((TOP * 2)) | cut -f 3 > "$WORK/speedlist"
  _ns=$(wc -l < "$WORK/speedlist" | tr -d ' ')
  if [ "$_ns" -gt 0 ]; then
    echo
    info "speed test: $_ns best node(s), one at a time, up to ${SPEED_T}s each"
    _k=0
    while IFS= read -r _n; do
      _k=$((_k + 1))
      speed_node "$_n"
      printf '  [%*d/%d] %7s Mbit/s  %s\n' "${#_ns}" "$_k" "$_ns" "$(cat "$WORK/n/$_n/speed")" "$(cat "$WORK/n/$_n/name")"
    done < "$WORK/speedlist"
  fi
fi
ELAPSED=$(( $(date +%s) - START ))

awk -F "$TAB" -v OFS="$TAB" -v w="$WORK" '{
  f = w "/n/" $1 "/speed"; sp = "-"
  if ((getline v < f) > 0) sp = v
  close(f)
  $10 = sp "\t" $10
  print
}' "$WORK/all" > "$WORK/all.s" && mv "$WORK/all.s" "$WORK/all"

# ranking:
#  1. class: <=5% failed, <=20% failed, worse, not via node, not started/skipped
#  2. inside the usable classes: rank by median latency + rank by speed
#     (nodes without a speed result come after the measured ones)
#  3. then failure rate, then median
awk -F "$TAB" -v OFS="$TAB" '
{ row[NR] = $0
  st = $2; ok = $3 + 0; tot = $4 + 0
  fail = tot > 0 ? (tot - ok) / tot : 1
  if ((st == "ok" || st == "noexit") && ok > 0) cls = (fail <= 0.05) ? 0 : (fail <= 0.2 ? 1 : 2)
  else if (st == "direct") cls = 3
  else if (st == "ok" || st == "noexit") cls = 2
  else cls = 4
  C[NR] = cls; F[NR] = fail
  M[NR] = ($6 == "-") ? 1e9 : $6 + 0
  S[NR] = ($10 == "-") ? -1 : $10 + 0
}
END {
  n = 0
  for (i = 1; i <= NR; i++) if (C[i] <= 1) { a[++n] = i; b[n] = i }
  for (x = 2; x <= n; x++) { t = a[x]; y = x - 1; while (y > 0 && M[a[y]] > M[t]) { a[y + 1] = a[y]; y-- } a[y + 1] = t }
  for (x = 2; x <= n; x++) { t = b[x]; y = x - 1; while (y > 0 && S[b[y]] < S[t]) { b[y + 1] = b[y]; y-- } b[y + 1] = t }
  for (x = 1; x <= n; x++) { LR[a[x]] = x; SR[b[x]] = (S[b[x]] > 0) ? x : n + 1 }
  for (i = 1; i <= NR; i++) {
    score = (C[i] <= 1) ? LR[i] + SR[i] : 0
    printf "%d\t%d\t%.6f\t%.6f\t%s\n", C[i], score, F[i], M[i], row[i]
  }
}' "$WORK/all" | sort -t "$TAB" -k1,1n -k2,2n -k3,3g -k4,4g | cut -f 5- > "$WORK/sorted"

# --- report ------------------------------------------------------------------

echo
printf '%s%-3s %-12s %8s %6s %7s %7s %7s %7s  %-15s %-3s %s%s\n' "$BD" "#" "verdict" "ok" "fail%" "min" "median" "p90" "Mbit/s" "exit IP" "cc" "node" "$R0"
_good=0; _okn=0; _bad=0; BEST=""
while IFS="$TAB" read -r _n _s _ok _tot _mn _md _p9 _xi _xc _sp _nm; do
  _v=$(verdict "$_s" "$_ok" "$_tot")
  _fp="-"; [ "$_tot" -gt 0 ] && _fp=$(awk -v o="$_ok" -v t="$_tot" 'BEGIN {printf "%.1f", (t - o) * 100 / t}')
  printf '%-3s %s%-12s%s %8s %6s %7s %7s %7s %7s  %-15s %-3s %s\n' \
    "$_n" "$(vcolor "$_v")" "$_v" "$R0" "$_ok/$_tot" "$_fp" "$_mn" "$_md" "$_p9" "$_sp" "$_xi" "$_xc" "$_nm"
  case "$_v" in GOOD) _good=$((_good + 1)) ;; OK|FLAKY) _okn=$((_okn + 1)) ;; *) _bad=$((_bad + 1)) ;; esac
  [ -z "$BEST" ] && case "$_v" in GOOD|OK|FLAKY) BEST="$_nm (#$_n, median ${_md}s, $_sp Mbit/s)" ;; esac
done < "$WORK/sorted"

echo
printf 'Summary: %s%d good%s, %s%d usable%s, %s%d not working%s — %ds total\n' \
  "$GR" "$_good" "$R0" "$YL" "$_okn" "$R0" "$RD" "$_bad" "$R0" "$ELAPSED"
[ -n "$BEST" ] && printf 'Best node: %s%s%s\n' "$BD" "$BEST" "$R0"

# explain problems in plain words
_hdr=0
while IFS="$TAB" read -r _n _s _ok _tot _mn _md _p9 _xi _xc _sp _nm; do
  _why=""
  case "$_s" in
    skip)   _why=$(cat "$WORK/n/$_n/skip") ;;
    start)  _why="sing-box did not start: $(grep -v '^[[:space:]]*$' "$WORK/n/$_n/sb.log" 2>/dev/null | tail -n 1 | cut -c 1-200)" ;;
    direct) _why="exit IP equals the router's own IP: traffic did not go through the node, results are void" ;;
    noexit) _why="could not learn the exit IP through the node (ipinfo.io / ipify blocked or node down)" ;;
  esac
  case "$_s" in ok|noexit)
    [ "$_ok" -eq 0 ] && _why="all $_tot requests failed: node unreachable, blocked, or wrong credentials" ;;
  esac
  [ "$_sp" = "0.0" ] && _why="${_why:+$_why; }speed test download failed"
  [ -n "$_why" ] || continue
  [ "$_hdr" = 0 ] && { echo; printf '%sProblems:%s\n' "$BD" "$R0"; _hdr=1; }
  printf '  #%-3s %s: %s\n' "$_n" "$_nm" "$_why"
done < "$WORK/sorted"

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
printf '%s        Mbit/s = download speed, measured for the %s best-answering nodes.%s\n' "$DM" "$((TOP * 2))" "$R0"
printf '%s        GOOD 0%% fail, OK <=5%%, FLAKY <=20%%, BAD >20%%, DEAD = nothing got through.%s\n' "$DM" "$R0"
printf '%s        Order: fewest failures, then best ping + speed together.%s\n' "$DM" "$R0"

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

# best working nodes that came from links (config outbounds have no link)
: > "$WORK/best"; : > "$WORK/best.names"
while IFS="$TAB" read -r _n _s _ok _tot _mn _md _p9 _xi _xc _sp _nm; do
  [ "$(wc -l < "$WORK/best")" -ge "$TOP" ] && break
  [ -f "$WORK/n/$_n/link" ] || continue
  case "$(verdict "$_s" "$_ok" "$_tot")" in GOOD|OK|FLAKY)
    cat "$WORK/n/$_n/link" >> "$WORK/best"
    printf '#%-3s median %6ss %7s Mbit/s  %s\n' "$_n" "$_md" "$_sp" "$_nm" >> "$WORK/best.names" ;;
  esac
done < "$WORK/sorted"

if [ "$APPLY" != no ] && [ -s "$WORK/best" ] && case "$SOURCE" in podkop*) false ;; *) true ;; esac; then
  _nb=$(wc -l < "$WORK/best" | tr -d ' ')
  cp "$WORK/best" "/tmp/podkop-probe-best.txt" 2>/dev/null &&
    info "best $_nb link(s) saved to /tmp/podkop-probe-best.txt"
  if [ -f /etc/config/podkop ] && command -v uci >/dev/null 2>&1; then
    uci -q get "podkop.$SECTION" >/dev/null || die "podkop has no section '$SECTION' (use --section)"
    echo
    printf '%sBest %s node(s) to put into podkop:%s\n' "$BD" "$_nb" "$R0"
    sed 's/^/  /' "$WORK/best.names"
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
