# podkop-manager

A web interface on a Linux server for
[podkop](https://github.com/itdoginfo/podkop) on one or more OpenWrt routers:
rules and settings, servers, the nightly [podkop-probe](../README.md), logs
and a history of every change.

```
Ubuntu: podkop-manager ── SSH, a key that may run only podkop-agent ──▶ OpenWrt: podkop-agent
  web UI, schedule, history                                              checks, applies, undoes,
                                                                         watchdog, pins, probe
```

Every change is checked before podkop is touched. If podkop doesn't come up
with it, the router puts the old settings back within about 30 s, even when
the manager is offline.

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

**Add router** → address, root password (used once, not stored). Needs
podkop and podkop-engine on the router. It installs podkop-agent with a
watchdog, podkop-probe, the manager's key (allowed to run only podkop-agent)
and firewall rules that close podkop's Clash API (port 9090) to the LAN,
except the computers you list. **Settings → Remove** undoes all of it.

## Good to know

- Changes collect in a draft until **Review and apply**.
- A rule can take servers **from your subscriptions** by exit country,
  protocol, exit IP or name; they are refreshed after every probe run.
- Nightly probe: **Servers probe** → time and "Apply the nightly result by itself".
- To stop podkop, use **Stop**: otherwise the watchdog starts it again within
  about 30 s (**Disable** in LuCI turns that off).
- Data: `/var/lib/podkop-manager` (database, SSH key). Logs: `journalctl -u podkop-manager`.
