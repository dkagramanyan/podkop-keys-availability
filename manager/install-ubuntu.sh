#!/bin/sh
# Installs or updates podkop-manager on Ubuntu/Debian (run with sudo):
#   sudo sh install-ubuntu.sh            # from GitHub, branch main
#   sudo sh install-ubuntu.sh --src DIR  # from a local checkout
# Then: sudo -u podkop-manager podkop-manager set-password, and open http://<this machine>:8080
set -eu

REPO=https://github.com/dkagramanyan/podkop-keys-availability
BASE=/opt/podkop-manager
DATA=/var/lib/podkop-manager
SRC=""
[ "${1:-}" = --src ] && SRC=$(cd "$2" && pwd)

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
command -v python3 >/dev/null || apt-get install -y python3
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || { echo "needs Python 3.10 or newer" >&2; exit 1; }
python3 -c 'import venv, ensurepip' 2>/dev/null || apt-get install -y python3-venv

id podkop-manager >/dev/null 2>&1 || useradd --system --home "$DATA" --shell /usr/sbin/nologin podkop-manager
install -d -o podkop-manager -g podkop-manager -m 700 "$DATA"
install -d "$BASE"

if [ -n "$SRC" ]; then
  rm -rf "$BASE/src.new" && cp -a "$SRC" "$BASE/src.new"
else
  command -v git >/dev/null || apt-get install -y git
  rm -rf "$BASE/src.new" && git clone --depth 1 "$REPO" "$BASE/src.new"
fi
rm -rf "$BASE/src" && mv "$BASE/src.new" "$BASE/src"

[ -x "$BASE/venv/bin/python" ] || python3 -m venv "$BASE/venv"
"$BASE/venv/bin/pip" install -q --upgrade pip
"$BASE/venv/bin/pip" install -q "$BASE/src/manager"
ln -sf "$BASE/venv/bin/podkop-manager" /usr/local/bin/podkop-manager

install -m 644 "$BASE/src/manager/podkop-manager.service" /etc/systemd/system/podkop-manager.service
systemctl daemon-reload
systemctl enable podkop-manager >/dev/null 2>&1
if sudo -u podkop-manager env PODKOP_MANAGER_DATA="$DATA" podkop-manager check >/dev/null 2>&1; then
  systemctl restart podkop-manager
  echo "podkop-manager updated and restarted: http://$(hostname -I | cut -d ' ' -f 1):8080"
else
  echo "Installed. Set the web password, then start it:"
  echo "  sudo -u podkop-manager env PODKOP_MANAGER_DATA=$DATA podkop-manager set-password"
  echo "  sudo systemctl start podkop-manager"
fi
