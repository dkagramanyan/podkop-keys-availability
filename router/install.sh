#!/bin/sh
# shellcheck shell=dash disable=SC2015
#
# Installs podkop-agent on the router (run as root on the router):
#
#   sh install.sh --key 'ssh-ed25519 AAAA... podkop-manager' [--allow-clash IP ...] [--keep-clash-open] [--src DIR]
#   sh install.sh --uninstall
#
# --key          the manager's public key; it may run only podkop-agent
# --allow-clash  computers that may still open podkop's Clash API (port 9090,
#                e.g. for the dashboard in LuCI); the rest of the LAN is blocked
# --keep-clash-open  leave the firewall as it is (the Clash API stays open to the LAN)
# --src DIR      take podkop-agent, podkop-agent.init and probe.sh from DIR
#                instead of the latest release

REPO_URL="https://github.com/dkagramanyan/podkop-manager"
RELEASE="$REPO_URL/releases/latest/download"
KEYS=/etc/dropbear/authorized_keys
MARK=podkop-agent
KEEP="/usr/bin/podkop-agent /etc/init.d/podkop-agent /etc/podkop-agent/ /usr/bin/podkop-probe /usr/share/podkop-agent/"

set -u
KEY=""; ALLOW=""; SRC=""; UNINSTALL=0; BLOCK=on
while [ $# -gt 0 ]; do
  case "$1" in
    --key) KEY=${2:-}; shift 2 ;;
    --allow-clash) ALLOW="$ALLOW ${2:-}"; shift 2 ;;
    --keep-clash-open) BLOCK=off; shift ;;
    --src) SRC=${2:-}; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

fetch() { # <name> <to>
  if [ -n "$SRC" ]; then cp "$SRC/$1" "$2"
  else wget -q -O "$2" "$RELEASE/$1" || uclient-fetch -q -O "$2" "$RELEASE/$1"; fi
}

firewall_rules() {
  uci -q delete firewall.podkop_agent_clash_allow
  uci -q delete firewall.podkop_agent_clash_block
  if [ -n "$1" ]; then
    uci set firewall.podkop_agent_clash_allow=rule
    uci set firewall.podkop_agent_clash_allow.name='podkop-agent: Clash API for admins'
    uci set firewall.podkop_agent_clash_allow.src=lan
    uci set firewall.podkop_agent_clash_allow.proto=tcp
    uci set firewall.podkop_agent_clash_allow.dest_port=9090
    uci set firewall.podkop_agent_clash_allow.target=ACCEPT
    for _ip in $1; do uci add_list firewall.podkop_agent_clash_allow.src_ip="$_ip"; done
  fi
  if [ "$2" = on ]; then
    uci set firewall.podkop_agent_clash_block=rule
    uci set firewall.podkop_agent_clash_block.name='podkop-agent: no Clash API from the LAN'
    uci set firewall.podkop_agent_clash_block.src=lan
    uci set firewall.podkop_agent_clash_block.proto=tcp
    uci set firewall.podkop_agent_clash_block.dest_port=9090
    uci set firewall.podkop_agent_clash_block.target=REJECT
  fi
  uci commit firewall && /etc/init.d/firewall reload >/dev/null 2>&1
}

if [ "$UNINSTALL" = 1 ]; then
  /etc/init.d/podkop-agent stop 2>/dev/null; /etc/init.d/podkop-agent disable 2>/dev/null
  rm -rf /usr/bin/podkop-agent /etc/init.d/podkop-agent /etc/podkop-agent /tmp/podkop-agent /usr/share/podkop-agent
  [ -f "$KEYS" ] && sed -i "/ $MARK\$/d" "$KEYS"
  firewall_rules "" off
  for _f in $KEEP; do
    [ "$_f" = /usr/bin/podkop-probe ] && continue      # podkop-probe stays
    sed -i "\\|^$_f\$|d" /etc/sysupgrade.conf 2>/dev/null
  done
  echo "podkop-agent removed (podkop-probe is kept: podkop-probe --uninstall removes it)"
  exit 0
fi

[ -n "$KEY" ] || die "--key 'ssh-ed25519 AAAA...' is required"
case "$KEY" in ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*) ;; *) die "--key must be an SSH public key" ;; esac
[ -x /usr/bin/podkop ] && [ -f /usr/lib/podkop/sing_box_config_facade.sh ] || die "podkop is not installed"
# without podkop-engine the agent works (reading, applying, the watchdog), podkop-probe does not
sing-box version 2>/dev/null | grep -q 'tools.decode-link' ||
  echo "warning: podkop-engine is not installed, so podkop-probe can't test servers here (https://github.com/FiyeroT/podkop-engine)" >&2
command -v jq >/dev/null 2>&1 || die "jq is not installed"
for _t in flock setsid; do command -v "$_t" >/dev/null 2>&1 || die "$_t is not available (BusyBox without it?)"; done

TMP=/tmp/podkop-agent-install.$$
mkdir -p "$TMP" || die "cannot create $TMP"
trap 'rm -rf "$TMP"' EXIT
# whole <file> <its last line>: a cut-off download is not installed
whole() { [ "$(tail -n 1 "$1")" = "$2" ] && sh -n "$1" 2>/dev/null; }
fetch podkop-agent "$TMP/podkop-agent" && whole "$TMP/podkop-agent" "# end of podkop-agent" || die "could not get podkop-agent"
fetch podkop-agent.init "$TMP/podkop-agent.init" && grep -q 'podkop-agent daemon' "$TMP/podkop-agent.init" &&
  sh -n "$TMP/podkop-agent.init" 2>/dev/null || die "could not get podkop-agent.init"
fetch probe.sh "$TMP/probe.sh" && whole "$TMP/probe.sh" "# end of podkop-probe" || die "could not get probe.sh"

# flash: a file that is already the same is not written again
put() { cmp -s "$1" "$2" || { cp "$1" "$2.new" && chmod 755 "$2.new" && mv "$2.new" "$2"; } || die "could not write $2"; }
put "$TMP/podkop-agent" /usr/bin/podkop-agent
put "$TMP/podkop-agent.init" /etc/init.d/podkop-agent
put "$TMP/probe.sh" /usr/bin/podkop-probe
mkdir -p /etc/podkop-agent /usr/share/podkop-agent && chmod 700 /etc/podkop-agent
# kept for "podkop-agent uninstall"
[ "$0" -ef /usr/share/podkop-agent/install.sh ] || cp "$0" /usr/share/podkop-agent/install.sh

# the manager's key: only podkop-agent, no shell, no forwarding
touch "$KEYS" && chmod 600 "$KEYS"
sed -i "/ $MARK\$/d" "$KEYS"
set -f
# shellcheck disable=SC2086
set -- $KEY
set +f
printf 'restrict,command="/usr/bin/podkop-agent" %s %s %s\n' "$1" "$2" "$MARK" >> "$KEYS"

if [ "$BLOCK" = on ]; then firewall_rules "$ALLOW" on
# nothing to change: only remove rules an earlier install of ours added
elif uci -q get firewall.podkop_agent_clash_block >/dev/null || uci -q get firewall.podkop_agent_clash_allow >/dev/null; then
  firewall_rules "" off
fi

for _f in $KEEP; do grep -qxF "$_f" /etc/sysupgrade.conf 2>/dev/null || echo "$_f" >> /etc/sysupgrade.conf; done

/etc/init.d/podkop-agent enable && /etc/init.d/podkop-agent restart 2>/dev/null || die "could not start podkop-agent"
echo "podkop-agent $(sed -n 's/^AGENT_VERSION="\(.*\)"/\1/p' /usr/bin/podkop-agent) installed"
