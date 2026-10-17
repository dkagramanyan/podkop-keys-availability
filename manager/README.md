# podkop-manager

A web interface on an Ubuntu (or any Linux) server that manages
[podkop](https://github.com/itdoginfo/podkop) on one or more OpenWrt routers:
all podkop settings and sections, server pinning, the nightly
[podkop-probe](../README.md), live logs and a history of every change.

```
Ubuntu: podkop-manager ── SSH, a key that may run only podkop-agent ──▶ OpenWrt: podkop-agent
  web UI, schedule, history                                              checks, applies, undoes,
                                                                         watchdog, pins, probe
```

Every change is checked before podkop is touched (links through podkop's own
parser, lists, required fields). If podkop doesn't come up with the new
settings, the router puts the old ones back by itself within about 30 s. The
router keeps podkop running and the pinned servers set even when the manager
is offline.

## Install on the server

```sh
git clone https://github.com/dkagramanyan/podkop-keys-availability
sudo sh podkop-keys-availability/manager/install-ubuntu.sh
sudo -u podkop-manager env PODKOP_MANAGER_DATA=/var/lib/podkop-manager podkop-manager set-password
sudo systemctl start podkop-manager
```

Open `http://<server>:8080`. Update later by running `install-ubuntu.sh` again.
Needs Python 3.10 or newer (Ubuntu 22.04+).

## Add a router

**Add router** → address, root password. The password is used once to install
podkop-agent, podkop-probe and this manager's key on the router; it is not
stored. Needs podkop and podkop-engine on the router.

What gets installed on the router:

- `/usr/bin/podkop-agent` and its service (the watchdog), `/usr/bin/podkop-probe`
- a line in `/etc/dropbear/authorized_keys`: the manager's key, allowed to run
  only podkop-agent (no shell, no port forwarding)
- two firewall rules: podkop's Clash API (port 9090) is closed to the LAN,
  except for the computers listed when adding the router

Remove from the router: `sh /tmp/install.sh --uninstall` with
[`agent/install.sh`](../agent/install.sh).

## Good to know

- To stop podkop for a while, use **Stop** in the manager. If podkop is
  stopped in another way while it's enabled, the watchdog starts it again
  within about 30 s. **Disable** in LuCI turns that off.
- Nightly probe: **Servers probe** → time and "apply automatically".
- Data: `/var/lib/podkop-manager` (database, SSH key). Logs: `journalctl -u podkop-manager`.
