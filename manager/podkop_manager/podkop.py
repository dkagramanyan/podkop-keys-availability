"""podkop's settings: the option schema of podkop 0.7.24 (from its LuCI app),
the diff between two configs, and putting podkop-probe's lists into a config.

A config is what podkop-agent's config-get returns:
{"sections": [{"name", "type", "anonymous", "options": {opt: str | [str]}}]}
"""

from __future__ import annotations

import copy
from urllib.parse import unquote

# kind: select (one of values), combo (free text with suggestions), text,
# number, flag ("0"/"1"), list (several values), textarea, devices / device
# (network devices of the router), interfaces (logical interfaces), community
# (podkop's community lists), section (one of the proxy/vpn sections).
# depends: any of the conditions must hold; a condition is {option: value}.

SECTION_OPTIONS = [
    {"name": "connection_type", "label": "Connection type", "kind": "select",
     "values": ["proxy", "vpn", "block", "exclusion"]},
    {"name": "proxy_config_type", "label": "Configuration type", "kind": "select",
     "values": ["url", "selector", "urltest", "outbound"], "default": "url",
     "depends": [{"connection_type": "proxy"}]},
    {"name": "proxy_string", "label": "Proxy link", "kind": "textarea",
     "depends": [{"proxy_config_type": "url"}]},
    {"name": "outbound_json", "label": "Outbound (sing-box JSON)", "kind": "textarea",
     "depends": [{"proxy_config_type": "outbound"}]},
    {"name": "selector_proxy_links", "label": "Selector links", "kind": "list",
     "depends": [{"proxy_config_type": "selector"}]},
    {"name": "urltest_proxy_links", "label": "URLTest links", "kind": "list",
     "depends": [{"proxy_config_type": "urltest"}]},
    {"name": "urltest_fallback_links", "label": "Fallback links", "kind": "list",
     "help": "Used only when all URLTest links fail",
     "depends": [{"proxy_config_type": "urltest"}]},
    {"name": "urltest_check_interval", "label": "URLTest check interval", "kind": "select",
     "values": ["30s", "1m", "3m", "5m"], "default": "3m", "depends": [{"proxy_config_type": "urltest"}]},
    {"name": "urltest_tolerance", "label": "URLTest tolerance, ms", "kind": "number", "default": "50",
     "depends": [{"proxy_config_type": "urltest"}]},
    {"name": "urltest_testing_url", "label": "URLTest testing URL", "kind": "combo",
     "values": ["https://www.gstatic.com/generate_204", "https://cp.cloudflare.com/generate_204",
                "https://captive.apple.com", "https://connectivity-check.ubuntu.com",
                "https://www.youtube.com/generate_204"],
     "default": "https://www.gstatic.com/generate_204", "depends": [{"proxy_config_type": "urltest"}]},
    {"name": "urltest_download_check", "label": "Download check", "kind": "select",
     "values": ["default", "off", "custom"], "default": "default", "depends": [{"proxy_config_type": "urltest"}]},
    {"name": "urltest_download_url", "label": "Download check URL", "kind": "combo",
     "values": ["https://speed.cloudflare.com/__down?bytes=65536",
                "https://cachefly.cachefly.net/1mb.test"],
     "default": "https://speed.cloudflare.com/__down?bytes=65536",
     "depends": [{"proxy_config_type": "urltest", "urltest_download_check": "custom"}]},
    {"name": "enable_udp_over_tcp", "label": "UDP over TCP", "kind": "flag", "default": "0",
     "depends": [{"connection_type": "proxy"}]},
    {"name": "interface", "label": "VPN interface", "kind": "device", "depends": [{"connection_type": "vpn"}]},
    {"name": "domain_resolver_enabled", "label": "Domain resolver", "kind": "flag", "default": "0",
     "depends": [{"connection_type": "vpn"}]},
    {"name": "domain_resolver_dns_type", "label": "Resolver DNS protocol", "kind": "select",
     "values": ["doh", "dot", "udp"], "default": "udp", "depends": [{"domain_resolver_enabled": "1"}]},
    {"name": "domain_resolver_dns_server", "label": "Resolver DNS server", "kind": "combo",
     "values": ["1.1.1.1", "8.8.8.8", "9.9.9.9", "dns.adguard-dns.com"], "default": "8.8.8.8",
     "depends": [{"domain_resolver_enabled": "1"}]},
    {"name": "community_lists", "label": "Community lists", "kind": "community"},
    {"name": "user_domain_list_type", "label": "User domains", "kind": "select",
     "values": ["disabled", "dynamic", "text"], "default": "disabled"},
    {"name": "user_domains", "label": "User domains", "kind": "list",
     "depends": [{"user_domain_list_type": "dynamic"}]},
    {"name": "user_domains_text", "label": "User domains (text)", "kind": "textarea",
     "depends": [{"user_domain_list_type": "text"}]},
    {"name": "user_subnet_list_type", "label": "User subnets", "kind": "select",
     "values": ["disabled", "dynamic", "text"], "default": "disabled"},
    {"name": "user_subnets", "label": "User subnets", "kind": "list",
     "depends": [{"user_subnet_list_type": "dynamic"}]},
    {"name": "user_subnets_text", "label": "User subnets (text)", "kind": "textarea",
     "depends": [{"user_subnet_list_type": "text"}]},
    {"name": "local_domain_lists", "label": "Local domain lists (files)", "kind": "list"},
    {"name": "local_subnet_lists", "label": "Local subnet lists (files)", "kind": "list"},
    {"name": "remote_domain_lists", "label": "Remote domain lists (URLs)", "kind": "list"},
    {"name": "remote_subnet_lists", "label": "Remote subnet lists (URLs)", "kind": "list"},
    {"name": "fully_routed_ips", "label": "Fully routed IPs", "kind": "list",
     "depends": [{"connection_type": "proxy"}, {"connection_type": "vpn"}]},
    {"name": "mixed_proxy_enabled", "label": "Mixed proxy", "kind": "flag", "default": "0",
     "depends": [{"connection_type": "proxy"}, {"connection_type": "vpn"}]},
    {"name": "mixed_proxy_port", "label": "Mixed proxy port", "kind": "number",
     "depends": [{"mixed_proxy_enabled": "1"}]},
    {"name": "resolve_real_ip_for_routing", "label": "Resolve real IP for routing", "kind": "flag",
     "default": "0", "depends": [{"connection_type": "proxy"}, {"connection_type": "vpn"}]},
]

SETTINGS_OPTIONS = [
    {"name": "dns_type", "label": "DNS protocol", "kind": "select", "values": ["doh", "dot", "udp"],
     "default": "udp"},
    {"name": "dns_server", "label": "DNS server", "kind": "combo",
     "values": ["1.1.1.1", "8.8.8.8", "9.9.9.9", "dns.adguard-dns.com", "unfiltered.adguard-dns.com",
                "family.adguard-dns.com"], "default": "8.8.8.8"},
    {"name": "bootstrap_dns_server", "label": "Bootstrap DNS server", "kind": "combo",
     "values": ["77.88.8.8", "77.88.8.1", "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "9.9.9.11"],
     "default": "77.88.8.8"},
    {"name": "dns_rewrite_ttl", "label": "DNS rewrite TTL", "kind": "number", "default": "60"},
    {"name": "source_network_interfaces", "label": "Source interfaces", "kind": "devices",
     "default": ["br-lan"]},
    {"name": "enable_output_network_interface", "label": "Output interface", "kind": "flag", "default": "0"},
    {"name": "output_network_interface", "label": "Output interface device", "kind": "device",
     "depends": [{"enable_output_network_interface": "1"}]},
    {"name": "enable_badwan_interface_monitoring", "label": "Bad WAN monitoring", "kind": "flag",
     "default": "0"},
    {"name": "badwan_monitored_interfaces", "label": "Monitored interfaces", "kind": "interfaces",
     "depends": [{"enable_badwan_interface_monitoring": "1"}]},
    {"name": "badwan_reload_delay", "label": "Monitoring delay, ms", "kind": "number", "default": "2000",
     "depends": [{"enable_badwan_interface_monitoring": "1"}]},
    {"name": "enable_yacd", "label": "YACD dashboard", "kind": "flag", "default": "0"},
    {"name": "enable_yacd_wan_access", "label": "YACD from WAN", "kind": "flag", "default": "0",
     "depends": [{"enable_yacd": "1"}]},
    {"name": "yacd_secret_key", "label": "YACD secret", "kind": "text",
     "depends": [{"enable_yacd_wan_access": "1"}]},
    {"name": "enable_utls_fallback", "label": "uTLS fallback", "kind": "flag", "default": "0"},
    {"name": "disable_quic", "label": "Disable QUIC", "kind": "flag", "default": "0"},
    {"name": "update_interval", "label": "List update interval", "kind": "select",
     "values": ["1h", "3h", "12h", "1d", "3d"], "default": "1d"},
    {"name": "download_lists_via_proxy", "label": "Download lists via proxy", "kind": "flag", "default": "0"},
    {"name": "download_lists_via_proxy_section", "label": "Via section", "kind": "section",
     "depends": [{"download_lists_via_proxy": "1"}]},
    {"name": "dont_touch_dhcp", "label": "Don't touch DHCP", "kind": "flag", "default": "0"},
    {"name": "config_path", "label": "sing-box config file", "kind": "select",
     "values": ["/etc/sing-box/config.json", "/tmp/sing-box/config.json"],
     "default": "/etc/sing-box/config.json"},
    {"name": "cache_path", "label": "sing-box cache file", "kind": "text", "default": "/tmp/sing-box/cache.db"},
    {"name": "log_level", "label": "Log level", "kind": "select",
     "values": ["trace", "debug", "info", "warn", "error", "fatal", "panic"], "default": "warn"},
    {"name": "exclude_ntp", "label": "Exclude NTP", "kind": "flag", "default": "0"},
    {"name": "routing_excluded_ips", "label": "Routing excluded IPs", "kind": "list"},
]

# written by podkop itself on every start and stop
INTERNAL_OPTIONS = {"shutdown_correctly"}

SCHEMA = {"podkop": "0.7.24", "settings": SETTINGS_OPTIONS, "section": SECTION_OPTIONS,
          "internal": sorted(INTERNAL_OPTIONS)}

YOUTUBE_PING_URL = "https://www.youtube.com/generate_204"


def sections_by_name(config: dict) -> dict:
    return {s["name"]: s for s in config.get("sections", [])}


def diff(old: dict, new: dict) -> list[dict]:
    """What changes from old to new: one entry per section/option, plus the
    order of sections when it changed."""
    out = []
    a, b = sections_by_name(old), sections_by_name(new)
    for name, sec in b.items():
        if name not in a:
            out.append({"section": name, "change": "added", "type": sec["type"], "options": sec["options"]})
    for name in a:
        if name not in b:
            out.append({"section": name, "change": "removed"})
    for name, sec in b.items():
        if name not in a:
            continue
        oo, no = a[name].get("options", {}), sec.get("options", {})
        for opt in list(oo) + [k for k in no if k not in oo]:
            if opt in INTERNAL_OPTIONS:
                continue
            if oo.get(opt) != no.get(opt):
                out.append({"section": name, "option": opt, "change": "changed",
                            "old": oo.get(opt), "new": no.get(opt)})
    order_a = [s for s in a if s in b]
    order_b = [s for s in b if s in a]
    if order_a != order_b:
        out.append({"change": "order", "old": order_a, "new": order_b})
    return out


def _move_before(sections: list, name: str, before: str) -> None:
    names = [s["name"] for s in sections]
    if name not in names or before not in names:
        return
    i, j = names.index(name), names.index(before)
    if i > j:
        sections.insert(j, sections.pop(i))


def _set_urltest(sec: dict, links: list, fallback: list) -> None:
    o = sec.setdefault("options", {})
    o["connection_type"] = "proxy"
    o["proxy_config_type"] = "urltest"
    o["urltest_proxy_links"] = list(links)
    if fallback:
        o["urltest_fallback_links"] = list(fallback)
    else:
        o.pop("urltest_fallback_links", None)


def merge_probe(config: dict, lists: dict, main: str = "main", youtube: str | None = "youtube") -> dict:
    """podkop-probe's lists put into a config, the way podkop-probe itself
    does it: the main list (and its fallbacks) become the URLTest of `main`;
    the YouTube list goes into `youtube`, created with podkop's youtube list
    and kept above `main` (podkop routes by the first section that matches).
    An empty list leaves its section alone."""
    cfg = copy.deepcopy(config)
    secs = cfg.setdefault("sections", [])
    by = sections_by_name(cfg)
    if lists.get("main"):
        if main not in by:
            raise ValueError(f"podkop has no section {main!r}")
        _set_urltest(by[main], lists["main"], lists.get("main_fallback") or [])
    if youtube and lists.get("youtube"):
        if youtube not in by:
            sec = {"name": youtube, "type": "section", "anonymous": False,
                   "options": {"connection_type": "proxy", "community_lists": ["youtube"]}}
            secs.append(sec)
            by[youtube] = sec
        _set_urltest(by[youtube], lists["youtube"], lists.get("youtube_fallback") or [])
        by[youtube]["options"]["urltest_testing_url"] = YOUTUBE_PING_URL
        _move_before(secs, youtube, main)
    return cfg


def link_name(link: str) -> str:
    """A server's name: the #fragment of its link, else its host."""
    if "#" in link:
        return unquote(link.split("#", 1)[1].replace("+", " "))
    rest = link.split("://", 1)[-1]
    return rest.split("@", 1)[-1].split("?", 1)[0].split("/", 1)[0]


def tag_names(config: dict) -> dict:
    """sing-box outbound tag -> server name, the way podkop names outbounds."""
    out = {}
    for s in config.get("sections", []):
        o = s.get("options", {})
        name = s["name"]

        def add(links, mid=""):
            for i, link in enumerate(links if isinstance(links, list) else [links] if links else []):
                out[f"{name}-{mid}{i + 1}-out"] = link_name(link)

        if o.get("proxy_config_type") == "urltest":
            add(o.get("urltest_proxy_links"))
            add(o.get("urltest_fallback_links"), "fallback-")
            out[f"{name}-urltest-out"] = "automatic"
        elif o.get("proxy_config_type") == "selector":
            add(o.get("selector_proxy_links"))
        elif o.get("proxy_config_type") == "url" and o.get("proxy_string"):
            out[f"{name}-out"] = link_name(o["proxy_string"])
    return out
