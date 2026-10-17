import pytest

from podkop_manager import podkop


def cfg(*sections):
    return {"sections": [{"name": n, "type": t, "anonymous": False, "options": o} for n, t, o in sections]}


BASE = cfg(("settings", "settings", {"dns_type": "udp", "shutdown_correctly": "1"}),
           ("main", "section", {"connection_type": "proxy", "proxy_config_type": "url",
                                "proxy_string": "vless://a@h:1#A", "community_lists": ["russia_inside"]}))


def test_diff_ignores_podkop_own_option():
    m = BASE["sections"][1]
    new = cfg(("settings", "settings", {"dns_type": "udp", "shutdown_correctly": "0"}), (m["name"], m["type"], m["options"]))
    assert podkop.diff(BASE, new) == []


def test_diff_changes_added_removed_order():
    new = cfg(("yt", "section", {"connection_type": "block"}),
              ("settings", "settings", {"dns_type": "doh", "shutdown_correctly": "1"}))
    d = podkop.diff(BASE, new)
    assert {"section": "yt", "change": "added", "type": "section", "options": {"connection_type": "block"}} in d
    assert {"section": "main", "change": "removed"} in d
    assert {"section": "settings", "option": "dns_type", "change": "changed", "old": "udp", "new": "doh"} in d


def test_diff_order():
    a = cfg(("settings", "settings", {}), ("main", "section", {}), ("yt", "section", {}))
    b = cfg(("settings", "settings", {}), ("yt", "section", {}), ("main", "section", {}))
    assert podkop.diff(a, b) == [{"change": "order", "old": ["settings", "main", "yt"], "new": ["settings", "yt", "main"]}]


def test_merge_probe_main_and_new_youtube_section_goes_first():
    lists = {"main": ["vless://1#a", "vless://2#b"], "main_fallback": ["vless://3#c"], "youtube": ["vless://1#a"]}
    out = podkop.merge_probe(BASE, lists)
    names = [s["name"] for s in out["sections"]]
    assert names == ["settings", "youtube", "main"]
    main = out["sections"][2]["options"]
    assert main["proxy_config_type"] == "urltest"
    assert main["urltest_proxy_links"] == lists["main"] and main["urltest_fallback_links"] == ["vless://3#c"]
    assert main["community_lists"] == ["russia_inside"]          # untouched
    yt = out["sections"][1]["options"]
    assert yt["community_lists"] == ["youtube"] and yt["urltest_testing_url"] == podkop.YOUTUBE_PING_URL
    assert "urltest_fallback_links" not in yt
    assert BASE["sections"][1]["options"]["proxy_config_type"] == "url"   # input not modified


def test_merge_probe_empty_lists_leave_sections_alone():
    out = podkop.merge_probe(BASE, {"main": [], "youtube": []})
    assert out == BASE


def test_merge_probe_drops_old_fallbacks_and_needs_main():
    with_fb = podkop.merge_probe(BASE, {"main": ["vless://1#a"], "main_fallback": ["vless://2#b"]})
    again = podkop.merge_probe(with_fb, {"main": ["vless://1#a"], "main_fallback": []})
    assert "urltest_fallback_links" not in again["sections"][1]["options"]
    with pytest.raises(ValueError):
        podkop.merge_probe(BASE, {"main": ["vless://1#a"]}, main="nope")


def test_schema_names_are_unique():
    for part in ("settings", "section"):
        names = [o["name"] for o in podkop.SCHEMA[part]]
        assert len(names) == len(set(names))


def test_tag_names():
    c = podkop.merge_probe(BASE, {"main": ["vless://1@h:1#%F0%9F%87%B1%F0%9F%87%B9%20A", "vless://2@h2:3?x=1"],
                                  "main_fallback": ["trojan://p@h3:4#C+D"]})
    n = podkop.tag_names(c)
    assert n["main-1-out"] == "🇱🇹 A" and n["main-2-out"] == "h2:3" and n["main-fallback-1-out"] == "C D"
    assert n["main-urltest-out"] == "automatic"
