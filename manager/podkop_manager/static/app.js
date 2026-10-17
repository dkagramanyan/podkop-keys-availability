"use strict";
// podkop-manager web interface: hash routes, plain DOM, live updates over SSE.

const S = { routers: {}, schema: null, manager: null, view: null };

// --- helpers --------------------------------------------------------------------

function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "class") el.className = v;
    else if (k === "value") el.value = v;
    else if (k === "checked") el.checked = !!v;
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of kids.flat(Infinity)) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

// replaceChildren that, like h(), flattens arrays and skips empty values
function put(el, ...kids) {
  el.replaceChildren(...kids.flat(Infinity).filter((c) => c !== null && c !== undefined && c !== false)
    .map((c) => (c instanceof Node ? c : document.createTextNode(String(c)))));
}

async function api(method, path, body) {
  const r = await fetch(path, {
    method,
    headers: { "Content-Type": "application/json", "X-Podkop-Manager": "1" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (r.status === 401) { location.href = "/login"; throw new Error("log in first"); }
  const data = await r.json().catch(() => ({}));
  if (!r.ok) {
    const e = new Error((data.error && data.error.message) || data.detail || r.statusText);
    e.info = data.error;
    throw e;
  }
  return data;
}

let toastTimer;
function toast(msg, bad) {
  const t = document.getElementById("toast");
  t.textContent = msg; t.className = "toast" + (bad ? " bad" : ""); t.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => (t.hidden = true), bad ? 8000 : 3500);
}

function modal(...content) {
  const bg = h("div", { class: "modal-bg", onclick: (e) => { if (e.target === bg) bg.remove(); } },
    h("div", { class: "modal" }, ...content));
  document.body.append(bg);
  return bg;
}

const ago = (t) => {
  if (!t) return "never";
  const s = Math.round(Date.now() / 1000 - t);
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return new Date(t * 1000).toLocaleString();
};
const when = (t) => (t ? new Date(t * 1000).toLocaleString() : "");
const clone = (x) => JSON.parse(JSON.stringify(x));
const asList = (v) => (v === undefined || v === null ? [] : Array.isArray(v) ? v : [v]);

// the name of a server: the #fragment of its link
function linkName(link) {
  const i = link.indexOf("#");
  if (i < 0) return link.replace(/^[a-z0-9]+:\/\/([^@]*@)?/, "").split(/[?/]/)[0];
  try { return decodeURIComponent(link.slice(i + 1).replace(/\+/g, " ")); } catch { return link.slice(i + 1); }
}

// outbound tag -> server name, from a section's links
function tagNames(config) {
  const m = {};
  for (const s of (config && config.sections) || []) {
    const o = s.options || {};
    const add = (list, mid) => asList(list).forEach((l, i) => (m[`${s.name}-${mid}${i + 1}-out`] = linkName(l)));
    if (o.proxy_config_type === "urltest") { add(o.urltest_proxy_links, ""); add(o.urltest_fallback_links, "fallback-"); }
    if (o.proxy_config_type === "selector") add(o.selector_proxy_links, "");
    if (o.proxy_config_type === "url" && o.proxy_string) m[`${s.name}-out`] = linkName(o.proxy_string);
    m[`${s.name}-urltest-out`] = "auto (URLTest)";
  }
  return m;
}

function routerState(rt) {
  if (!rt.online) return ["bad", "offline"];
  const p = rt.status.podkop;
  if (p.busy) return ["warn", "applying"];
  if (p.paused) return ["warn", "stopped"];
  if (!p.enabled) return ["warn", "disabled"];
  if (!p.running) return ["bad", "podkop down"];
  return ["ok", "running"];
}

// --- routing ------------------------------------------------------------------------

const routes = [
  [/^#?\/?$/, viewDashboard],
  [/^#\/add$/, viewAdd],
  [/^#\/settings$/, viewSettings],
  [/^#\/r\/(\d+)$/, viewOverview],
  [/^#\/r\/(\d+)\/config$/, viewConfig],
  [/^#\/r\/(\d+)\/probe$/, viewProbe],
  [/^#\/r\/(\d+)\/logs$/, viewLogs],
  [/^#\/r\/(\d+)\/history$/, viewHistory],
];

async function render() {
  const main = document.getElementById("main");
  if (S.view && S.view.leave) S.view.leave();
  S.view = null;
  for (const [re, fn] of routes) {
    const m = location.hash.match(re);
    if (m) {
      put(main, h("p", { class: "muted" }, "Loading…"));
      try { await fn(main, ...m.slice(1).map(Number)); }
      catch (e) { put(main, h("div", { class: "card" }, h("p", { class: "bad" }, e.message))); }
      return;
    }
  }
  put(main, h("p", {}, "Not found"));
}

function routerTabs(rt, active) {
  const t = (path, label) => h("a", { href: `#/r/${rt.id}${path}`, class: active === path ? "active" : "" }, label);
  const [cls, label] = routerState(rt);
  return [
    h("div", { class: "row spread" },
      h("h1", {}, rt.name, " ", h("span", { class: `badge ${cls}` }, label)),
      h("span", { class: "muted small" }, `${rt.host}${rt.port !== 22 ? ":" + rt.port : ""}`)),
    h("nav", { class: "tabs" }, t("", "Overview"), t("/config", "Settings"), t("/probe", "Servers probe"),
      t("/logs", "Logs"), t("/history", "History")),
  ];
}

function getRouter(id) {
  const rt = S.routers[id];
  if (!rt) throw new Error("no such router");
  return rt;
}

// --- dashboard ----------------------------------------------------------------------

async function viewDashboard(main) {
  const draw = () => {
    const list = Object.values(S.routers);
    put(main, 
      h("div", { class: "row spread" }, h("h1", {}, "Routers"), h("a", { href: "#/add", class: "button" }, "Add router")),
      list.length ? h("div", { class: "grid" }, list.map(routerCard))
        : h("div", { class: "card" }, h("p", {}, "No routers yet. "), h("a", { href: "#/add" }, "Add your first router")));
  };
  draw();
  S.view = { onRouter: draw };
}

function routerCard(rt) {
  const [cls, label] = routerState(rt);
  const st = rt.status;
  const all = (rt.proxies && rt.proxies.groups) || [];
  const groups = all.filter((g) => g.type === "Selector");
  const names = rt.names || {};
  const shown = (g) => {
    const ut = all.find((x) => x.name === g.now && x.type === "URLTest");
    return ut ? `${names[ut.now] || ut.now} (automatic)` : names[g.now] || g.now;
  };
  return h("a", { href: `#/r/${rt.id}`, class: "card", style: "display:block;color:inherit;text-decoration:none" },
    h("div", { class: "row spread" }, h("h2", {}, rt.name), h("span", { class: `badge ${cls}` }, label)),
    st ? h("div", { class: "small muted" }, `podkop ${st.podkop.version} · sing-box ${st.singbox.version}`) : null,
    st ? h("div", { class: "small muted" }, st.router.model) : h("div", { class: "small bad" }, rt.error),
    groups.length ? h("table", { style: "margin-top:8px" }, groups.map((g) =>
      h("tr", {}, h("td", {}, g.name.replace(/-out$/, "")), h("td", { class: "muted" }, shown(g))))) : null,
    h("div", { class: "small muted", style: "margin-top:6px" }, `checked ${ago(rt.checked)}`));
}

// --- add router ---------------------------------------------------------------------

async function viewAdd(main) {
  const f = {
    name: h("input", { placeholder: "e.g. home" }),
    host: h("input", { placeholder: "192.168.1.1", required: true }),
    port: h("input", { value: "22", type: "number" }),
    password: h("input", { type: "password", autocomplete: "off" }),
    allow: h("input", { placeholder: "e.g. 192.168.1.10 (optional)" }),
  };
  const out = h("div");
  const btn = h("button", { class: "primary", type: "submit" }, "Install podkop-agent and add");
  put(main, h("h1", {}, "Add router"), h("form", {
    class: "card", onsubmit: async (e) => {
      e.preventDefault(); btn.disabled = true; put(out, h("p", { class: "muted" }, "Installing… (up to a minute)"));
      try {
        const r = await api("POST", "/api/routers", { name: f.name.value, host: f.host.value, port: +f.port.value,
          password: f.password.value, allow_clash: f.allow.value });
        f.password.value = "";
        await loadRouters();
        location.hash = `#/r/${r.id}`;
      } catch (err) { put(out, h("p", { class: "problem" }, err.message)); btn.disabled = false; }
    } },
    field("Name", f.name), field("Router address", f.host), field("SSH port", f.port),
    field("Root password", f.password, "Used once to install podkop-agent and this manager's key; not stored."),
    field("Clash API allowed for", f.allow,
      "podkop's Clash API (port 9090) gets blocked for the LAN. List computers that should still reach it (e.g. for LuCI's dashboard)."),
    h("p", { class: "small muted" }, "Needs podkop and podkop-engine on the router. Installs podkop-agent, podkop-probe, a restricted SSH key and two firewall rules."),
    btn, out));
}

function field(label, input, help, opt) {
  return h("div", { class: "field" },
    h("div", { class: "name" }, label, opt ? h("div", { class: "opt" }, opt) : null),
    h("div", {}, input, help ? h("div", { class: "help" }, help) : null));
}

// --- settings (the manager's) ------------------------------------------------------------

async function viewSettings(main) {
  const info = S.manager || (S.manager = await api("GET", "/api/manager"));
  put(main, h("h1", {}, "Settings"),
    h("div", { class: "card" },
      h("h2", {}, "This manager"),
      h("p", {}, `podkop-manager ${info.version}`),
      h("p", { class: "small muted" }, "Its SSH key (routers let it run only podkop-agent):"),
      h("pre", {}, info.public_key),
      h("form", { method: "post", action: "/logout", style: "margin-top:14px" }, h("button", {}, "Log out"))));
}

// --- overview ---------------------------------------------------------------------------

async function viewOverview(main, id) {
  const rt = getRouter(id);
  let config = null;
  try { config = (await api("GET", `/api/routers/${id}/config`)).config; } catch { /* offline */ }
  const events = h("div");
  const loadEvents = async () => {
    const ev = await api("GET", `/api/routers/${id}/events?limit=30`);
    put(events, h("table", {}, ev.map((e) => h("tr", {},
      h("td", { class: "small muted", style: "white-space:nowrap" }, ago(e.t)), h("td", {}, eventText(e.type, e.data))))));
  };

  const draw = () => {
    const rt = S.routers[id];
    if (!rt) return;
    const st = rt.status;
    const pk = st && st.podkop;
    const svc = (action, label, cls) => h("button", { class: cls, onclick: async (e) => {
      e.target.disabled = true;
      try { await api("POST", `/api/routers/${id}/service`, { action }); toast(`podkop: ${action}`); }
      catch (err) { toast(err.message, true); }
      e.target.disabled = false;
    } }, label);
    put(main, ...routerTabs(rt, ""),
      !rt.online ? h("div", { class: "card problem" }, rt.error || "offline") : null,
      st ? h("div", { class: "card" },
        h("div", { class: "row spread" },
          h("div", {},
            h("div", {}, `podkop ${pk.version} · sing-box ${st.singbox.version} · agent ${st.agent.version}`),
            h("div", { class: "small muted" }, `${st.router.model} · ${st.router.openwrt} · up ${Math.round(st.uptime / 3600)} h`),
            st.failsafe && !pk.running ? h("div", { class: "small bad" }, `failsafe ${st.failsafe.time}: ${st.failsafe.message}`) : null),
          h("div", { class: "row" },
            pk.running ? svc("restart", "Restart podkop") : svc("start", "Start podkop", "primary"),
            pk.running ? svc("stop", "Stop", "danger") : null,
            h("button", { onclick: async () => { await api("POST", `/api/routers/${id}/refresh`); } }, "Refresh")))) : null,
      groupsCard(rt, Object.assign(tagNames(config), rt.names || {}), config),
      h("div", { class: "card" }, h("h2", {}, "Events"), events),
      h("div", { class: "card row" },
        h("button", { class: "danger", onclick: () => removeRouter(rt) }, "Remove router"),
        h("span", { class: "small muted" }, "From this manager; optionally also removes podkop-agent and the key from the router (podkop itself stays).")));
    loadEvents().catch(() => {});
  };
  draw();
  S.view = { onRouter: (r) => r.id === id && draw(), onEvent: (m) => m.router_id === id && loadEvents() };
}

function groupsCard(rt, names, config) {
  if (!rt.proxies) return h("div", { class: "card muted" }, "Servers show up here while podkop runs.");
  const delay = {};
  for (const s of rt.proxies.servers) delay[s.name] = s.delay;
  const pins = {};
  for (const p of (rt.status && rt.status.pins) || []) pins[p.section] = p.server;
  const sections = ((config && config.sections) || []).filter((s) => s.type === "section");
  const groups = rt.proxies.groups.filter((g) => g.type === "Selector");
  return h("div", { class: "card" }, h("h2", {}, "Servers"),
    groups.length ? null : h("p", { class: "muted" }, "No section uses selector or URLTest."),
    groups.map((g) => {
      const sec = g.name.replace(/-out$/, "");
      const ut = rt.proxies.groups.find((x) => x.name === `${sec}-urltest-out`);
      const current = g.now === `${sec}-urltest-out` && ut ? ut.now : g.now;
      const pin = async (server) => {
        try { await api("POST", `/api/routers/${rt.id}/pin`, { section: sec, server }); toast(server === "auto" ? "automatic choice" : `pinned ${names[server] || server}`); }
        catch (e) { toast(e.message, true); }
      };
      const test = h("button", { class: "small", onclick: async (e) => {
        e.target.disabled = true; e.target.textContent = "testing…";
        try {
          const d = await api("POST", `/api/routers/${rt.id}/delays`, { section: sec });
          Object.assign(delay, d); toast(`tested ${Object.keys(d).length} servers`);
          api("POST", `/api/routers/${rt.id}/refresh`).catch(() => {});
        } catch (err) { toast(err.message, true); }
        e.target.disabled = false; e.target.textContent = "Test all now";
      } }, "Test all now");
      const members = g.all.filter((m) => !m.endsWith("-urltest-out"));
      return h("div", { style: "margin-bottom:14px" },
        h("div", { class: "row spread" },
          h("h3", {}, sec, " ", pins[sec] ? h("span", { class: "badge warn" }, "pinned") : ut ? h("span", { class: "badge ok" }, "automatic") : null),
          h("div", { class: "row" }, test, pins[sec] && ut ? h("button", { class: "small", onclick: () => pin("auto") }, "Back to automatic") : null)),
        h("div", { class: "scroll" }, h("table", {},
          h("tr", {}, h("th", {}, "server"), h("th", { class: "num" }, "delay, ms"), h("th", {})),
          members.map((m) => h("tr", { class: m === current ? "now" : "" },
            h("td", {}, m === current ? "▶ " : "", names[m] || m, h("span", { class: "muted small" }, ` ${m}`)),
            h("td", { class: "num" }, delay[m] ? delay[m] : "–"),
            h("td", {}, m === current && pins[sec] ? null : h("button", { class: "small", onclick: () => pin(m) }, "Use")))))));
    }),
    sections.length ? null : null);
}

function removeRouter(rt) {
  const also = h("input", { type: "checkbox", checked: true });
  const m = modal(h("h2", {}, `Remove ${rt.name}?`),
    h("label", { class: "row" }, also, "also remove podkop-agent, its key and firewall rules from the router"),
    h("p", { class: "small muted" }, "podkop and its settings stay on the router."),
    h("div", { class: "row" },
      h("button", { class: "danger", onclick: async () => {
        try {
          const r = await api("DELETE", `/api/routers/${rt.id}?uninstall=${also.checked ? 1 : 0}`);
          delete S.routers[rt.id]; m.remove(); location.hash = "#/";
          toast(r.note || `${rt.name} removed`, !!r.note);
        } catch (e) { toast(e.message, true); }
      } }, "Remove"),
      h("button", { onclick: () => m.remove() }, "Cancel")));
}

const EVENT_TEXT = {
  applied: (d) => (d.restarted ? "settings applied, podkop restarted" : "settings saved (podkop stopped)"),
  reverted: (d) => `change undone: ${d.reason}`,
  revert_failed: (d) => `change failed and podkop does not run with the old settings either: ${d.revert_reason}`,
  podkop_down: (d) => `podkop is down${d.failsafe ? ": " + d.failsafe : ""}`,
  podkop_up: () => "podkop is up again",
  recovered: (d) => `watchdog: ${d.action}`,
  recovery_failed: (d) => `watchdog could not bring podkop back: ${d.reason}`,
  recovery_gave_up: () => "watchdog gave up: 3 tries in the last hour",
  pinned: (d) => `${d.section}: pinned ${d.server}`,
  pin_cleared: (d) => `${d.section}: automatic choice`,
  pin_restored: (d) => `${d.section}: pin ${d.server} set again`,
  pin_dropped: (d) => `${d.section}: pin removed, ${d.reason}`,
  agent_started: (d) => `podkop-agent ${d.version} started`,
  service: (d) => `podkop ${d.action}`,
  probe_started: () => "probe started",
  probe_done: (d) => `probe finished (exit ${d.exit})`,
  probe_apply_failed: (d) => `probe result not applied: ${d.message}`,
  probe_not_started: (d) => `nightly probe not started: ${d.message}`,
};
function eventText(type, d) {
  const f = EVENT_TEXT[type];
  const bad = ["reverted", "revert_failed", "podkop_down", "recovery_failed", "recovery_gave_up", "probe_apply_failed"].includes(type);
  return h("span", { class: bad ? "bad" : "" }, f ? f(d || {}) : `${type} ${JSON.stringify(d)}`);
}

// --- settings editor ------------------------------------------------------------------

async function viewConfig(main, id) {
  const rt = getRouter(id);
  const schema = S.schema || (S.schema = await api("GET", "/api/schema"));
  const loaded = await api("GET", `/api/routers/${id}/config`);
  let base = loaded.fingerprint;
  let work = clone(loaded.config);
  const ctx = { lists: loaded.community_lists, interfaces: loaded.interfaces, devices: loaded.devices };
  const problemsBox = h("div");

  const settingsSec = () => work.sections.find((s) => s.name === "settings");
  const proxySections = () => work.sections.filter((s) => s.type === "section"
    && !["block", "exclusion"].includes((s.options || {}).connection_type)).map((s) => s.name);

  const draw = () => {
    const secs = work.sections.filter((s) => s.type === "section");
    put(main, ...routerTabs(rt, "/config"),
      h("div", { class: "card" }, h("h2", {}, "Global settings"), optionsForm(settingsSec(), schema.settings, schema, ctx, proxySections, draw)),
      secs.map((sec, i) => h("div", { class: "card" },
        h("div", { class: "row spread" }, h("h2", {}, `Section ${sec.name}`),
          h("div", { class: "row" },
            h("button", { class: "small", disabled: i === 0, onclick: () => move(sec, -1) }, "↑ earlier"),
            h("button", { class: "small", disabled: i === secs.length - 1, onclick: () => move(sec, 1) }, "↓ later"),
            h("button", { class: "small danger", onclick: () => {
              if (confirm(`Remove section ${sec.name}?`)) { work.sections = work.sections.filter((s) => s !== sec); draw(); }
            } }, "Remove"))),
        i === 0 && secs.length > 1 ? h("p", { class: "small muted" }, "The first section that matches a site wins.") : null,
        optionsForm(sec, schema.section, schema, ctx, proxySections, draw))),
      work.sections.filter((s) => s.type !== "section" && s.type !== "settings").map((s) =>
        h("div", { class: "card" }, h("h2", {}, `${s.type} ${s.name}`), optionsForm(s, [], schema, ctx, proxySections, draw))),
      h("div", { class: "card row" },
        h("input", { id: "newsec", placeholder: "new section name (letters, digits, _)", style: "max-width:320px" }),
        h("button", { onclick: () => {
          const n = document.getElementById("newsec").value.trim();
          if (!/^[A-Za-z0-9_]+$/.test(n)) return toast("letters, digits and _ only", true);
          if (work.sections.some((s) => s.name === n)) return toast("this name is taken", true);
          work.sections.push({ name: n, type: "section", anonymous: false, options: { connection_type: "proxy", proxy_config_type: "url" } });
          draw();
        } }, "Add section")),
      problemsBox,
      h("div", { class: "card row", style: "position:sticky;bottom:0" },
        h("button", { onclick: check }, "Check"),
        h("button", { class: "primary", onclick: review }, "Review and apply"),
        h("button", { onclick: async () => { const r = await api("GET", `/api/routers/${id}/config`); base = r.fingerprint; work = clone(r.config); put(problemsBox, ); draw(); toast("reloaded from the router"); } }, "Discard changes")));
  };

  const move = (sec, d) => {
    const all = work.sections; const i = all.indexOf(sec);
    let j = i + d;
    while (j >= 0 && j < all.length && all[j].type !== "section") j += d;
    if (j < 0 || j >= all.length) return;
    [all[i], all[j]] = [all[j], all[i]]; draw();
  };

  const showProblems = (probs) => put(problemsBox, probs.length
    ? h("div", { class: "card" }, h("h2", {}, "podkop would not start with these settings"),
      probs.map((p) => h("div", { class: "problem" }, `${p.section}${p.option ? " / " + p.option : ""}${p.index !== undefined ? " #" + (p.index + 1) : ""}: ${p.message}`)))
    : h("div", { class: "card" }, h("span", { class: "badge ok" }, "no problems found")));

  async function check() {
    try { showProblems((await api("POST", `/api/routers/${id}/validate`, { config: work })).problems); }
    catch (e) { toast(e.message, true); }
  }

  async function review() {
    let d;
    try { d = await api("POST", `/api/routers/${id}/diff`, { config: work }); } catch (e) { return toast(e.message, true); }
    if (d.fingerprint !== base) {
      return toast("podkop's settings changed on the router since you opened this page: press Discard changes to reload", true);
    }
    if (!d.diff.length) return toast("nothing changed");
    confirmApply(id, base, work, d.diff, "edited in the web interface", async (ok) => {
      if (ok) { const r = await api("GET", `/api/routers/${id}/config`); base = r.fingerprint; work = clone(r.config); draw(); }
    }, showProblems);
  }

  draw();
  S.view = {};
}

// optionsForm: every option of the schema whose dependencies hold, then the
// options the schema doesn't know (kept as they are)
function optionsForm(sec, defs, schema, ctx, proxySections, redraw) {
  const o = sec.options || (sec.options = {});
  const shown = (def) => !def.depends || def.depends.some((cond) =>
    Object.entries(cond).every(([k, v]) => (o[k] ?? defaultOf(defs, k)) === v));
  const set = (name, value, again) => {
    if (value === "" || value === null || (Array.isArray(value) && !value.length)) delete o[name];
    else o[name] = value;
    if (again) redraw();
  };
  const known = new Set(defs.map((d) => d.name).concat(schema.internal));
  const rows = defs.filter(shown).map((def) => field(def.label, widget(def, o[def.name], (v) =>
    set(def.name, v, defs.some((d) => d.depends && d.depends.some((c) => def.name in c))), ctx, proxySections), def.help, def.name));
  const other = Object.keys(o).filter((k) => !known.has(k));
  if (other.length) {
    rows.push(h("h3", {}, "Other options"));
    for (const k of other) {
      const isList = Array.isArray(o[k]);
      rows.push(field(k, h("textarea", { class: "mono", rows: isList ? 3 : 1,
        oninput: (e) => set(k, isList ? e.target.value.split("\n").map((x) => x.trim()).filter(Boolean) : e.target.value) },
      isList ? o[k].join("\n") : o[k]), isList ? "one per line" : null, k));
    }
  }
  return h("div", {}, rows);
}

function defaultOf(defs, name) {
  const d = defs.find((x) => x.name === name);
  return d && d.default !== undefined ? d.default : undefined;
}

function widget(def, value, onchange, ctx, proxySections) {
  const dv = def.default;
  switch (def.kind) {
    case "select":
      return h("select", { onchange: (e) => onchange(e.target.value) },
        value === undefined && dv === undefined ? h("option", { value: "" }, "—") : null,
        def.values.map((v) => h("option", { value: v, selected: (value ?? dv) === v }, v)),
        value !== undefined && !def.values.includes(value) ? h("option", { value, selected: true }, value) : null);
    case "combo": {
      const lid = `dl-${def.name}`;
      return h("div", {}, h("input", { list: lid, value: value ?? "", placeholder: dv ?? "", oninput: (e) => onchange(e.target.value) }),
        h("datalist", { id: lid }, def.values.map((v) => h("option", { value: v }))));
    }
    case "text": case "number":
      return h("input", { type: def.kind === "number" ? "number" : "text", value: value ?? "", placeholder: dv ?? "",
        oninput: (e) => onchange(e.target.value) });
    case "flag":
      return h("label", { class: "row" }, h("input", { type: "checkbox", checked: (value ?? dv) === "1",
        onchange: (e) => onchange(e.target.checked ? "1" : "0") }), "on");
    case "textarea":
      return h("textarea", { class: "mono", rows: 4, oninput: (e) => onchange(e.target.value) }, value ?? "");
    case "list":
      return h("div", {}, h("textarea", { class: "mono", rows: Math.min(12, Math.max(3, asList(value).length + 1)),
        oninput: (e) => onchange(e.target.value.split("\n").map((x) => x.trim()).filter(Boolean)) }, asList(value).join("\n")),
      h("div", { class: "help" }, `one per line${asList(value).length ? ` · ${asList(value).length}` : ""}`));
    case "community": case "devices": case "interfaces": {
      const all = def.kind === "community" ? ctx.lists : def.kind === "devices" ? ctx.devices : ctx.interfaces;
      const cur = asList(value ?? dv);
      const opts = [...new Set([...all, ...cur])];
      return h("div", { class: "checks" }, opts.map((v) => h("label", {},
        h("input", { type: "checkbox", checked: cur.includes(v), onchange: (e) => {
          const next = e.target.checked ? [...cur, v] : cur.filter((x) => x !== v);
          cur.splice(0, cur.length, ...next); onchange([...cur]);
        } }), v)));
    }
    case "device": case "section": {
      const all = def.kind === "device" ? ctx.devices : proxySections();
      return h("select", { onchange: (e) => onchange(e.target.value) }, h("option", { value: "" }, "—"),
        [...new Set([...all, ...(value ? [value] : [])])].map((v) => h("option", { value: v, selected: value === v }, v)));
    }
    default:
      return h("input", { value: value ?? "", oninput: (e) => onchange(e.target.value) });
  }
}

// --- review, apply, follow the job ----------------------------------------------------

function diffList(diff) {
  const val = (v) => (v === undefined || v === null ? "—" : Array.isArray(v) ? v.map(linkOrValue).join(", ") : linkOrValue(v));
  return h("ul", { class: "diff" }, diff.map((d) => {
    if (d.change === "added") return h("li", { class: "add" }, `new section ${d.section}`);
    if (d.change === "removed") return h("li", { class: "del" }, `section ${d.section} removed`);
    if (d.change === "order") return h("li", {}, `order of sections: ${d.new.join(" → ")}`);
    return h("li", {}, h("b", {}, `${d.section} / ${d.option}`), ": ", h("span", { class: "del" }, val(d.old)), " → ", h("span", { class: "add" }, val(d.new)));
  }));
}
const linkOrValue = (v) => (/^[a-z0-9]+:\/\//.test(v) ? linkName(v) : v.length > 80 ? v.slice(0, 77) + "…" : v);

function confirmApply(id, base, config, diff, note, done, showProblems) {
  const status = h("div");
  const go = h("button", { class: "primary", onclick: async () => {
    go.disabled = true;
    put(status, h("p", { class: "muted" }, "Checking and applying… podkop restarts (about 15 s)"));
    try {
      const r = await api("POST", `/api/routers/${id}/apply`, { base, config, note });
      const v = await followVersion(r.version, status);
      const ok = ["applied", "saved", "unchanged"].includes(v.state);
      if (!ok && v.details && v.details.problems && showProblems) { showProblems(v.details.problems); }
      done && done(ok);
    } catch (e) { put(status, h("p", { class: "problem" }, e.message)); go.disabled = false; }
  } }, "Apply");
  const m = modal(h("h2", {}, "Changes"), diffList(diff), status,
    h("div", { class: "row", style: "margin-top:12px" }, go, h("button", { onclick: () => m.remove() }, "Close")));
}

// wait for a version's job; the hub sends job updates live, a poll is the fallback
function followVersion(vid, status) {
  return new Promise((resolve) => {
    const show = (v) => {
      const cls = { applied: "ok", saved: "ok", unchanged: "ok", rejected: "bad", reverted: "bad", failed: "bad" }[v.state] || "warn";
      put(status, h("p", {}, h("span", { class: `badge ${cls}` }, v.state), " ", v.message || ""));
    };
    const poll = async () => {
      const v = await api("GET", `/api/versions/${vid}`).catch(() => null);
      if (v && !["pending", "running"].includes(v.state)) { show(v); resolve(v); return; }
      if (v && v.details) show({ state: v.details.state, message: v.details.message });
      setTimeout(poll, 2000);
    };
    poll();
  });
}

// --- probe ----------------------------------------------------------------------------

const PROBE_FIELDS = [
  ["--countries", "Countries", "europe, all, or codes like DE,NL"],
  ["--max-ping", "Max ping, ms", "700"],
  ["--min-speed", "Min speed, Mbit/s", "40"],
  ["--top", "Servers per list", "10"],
];

function parseOptions(opts) {
  const r = { flags: new Set() };
  for (let i = 0; i < opts.length; i++) {
    if (PROBE_FIELDS.some(([k]) => k === opts[i])) { r[opts[i]] = opts[i + 1]; i++; }
    else r.flags.add(opts[i]);
  }
  return r;
}

async function viewProbe(main, id) {
  const rt = getRouter(id);
  let data = await api("GET", `/api/routers/${id}/probe`);
  const ps = data.settings;
  const parsed = parseOptions(ps.options || []);
  const f = {
    keys: h("textarea", { class: "mono", rows: 4 }, (ps.keys || []).join("\n")),
    schedule: h("input", { value: ps.schedule || "", placeholder: "HH:MM, empty = off", style: "max-width:220px" }),
    auto: h("input", { type: "checkbox", checked: !!ps.auto_apply }),
    main: h("input", { value: ps.main_section || "main", style: "max-width:200px" }),
    yt: h("input", { value: ps.youtube_section || "youtube", style: "max-width:200px" }),
    noyt: h("input", { type: "checkbox", checked: parsed.flags.has("--no-youtube") }),
    quick: h("input", { type: "checkbox", checked: parsed.flags.has("-q") }),
  };
  for (const [k, , ph] of PROBE_FIELDS) f[k] = h("input", { value: parsed[k] || "", placeholder: ph, style: "max-width:260px" });
  const statusBox = h("div");

  const save = async () => {
    const options = [];
    for (const [k] of PROBE_FIELDS) if (f[k].value.trim()) options.push(k, f[k].value.trim());
    if (f.noyt.checked) options.push("--no-youtube");
    if (f.quick.checked) options.push("-q");
    await api("PUT", `/api/routers/${id}/probe`, {
      keys: f.keys.value.split("\n").map((x) => x.trim()).filter(Boolean), options, schedule: f.schedule.value.trim(),
      auto_apply: f.auto.checked, main_section: f.main.value.trim(), youtube_section: f.noyt.checked ? "" : f.yt.value.trim(),
    });
  };

  const drawStatus = () => {
    const st = data.status;
    if (!st || st.state === "none") { put(statusBox, h("p", { class: "muted" }, "No probe has run on this router since it started.")); return; }
    const lists = st.lists || {};
    const n = (k) => (lists[k] || []).length;
    const cls = { running: "warn", done: "ok", failed: "bad" }[st.state] || "";
    put(statusBox, 
      h("div", { class: "row spread" },
        h("div", {}, h("span", { class: `badge ${cls}` }, st.state), " ", h("span", { class: "muted small" }, `started ${st.started}${st.finished ? ", finished " + st.finished : ""}`)),
        st.state === "done" && (n("main") || n("youtube")) ? h("button", { class: "primary", onclick: applyLists },
          `Review and apply: main ${n("main")} + ${n("main_fallback")} fallback, YouTube ${n("youtube")}`) : null),
      st.rows && st.rows.length ? h("div", { class: "scroll", style: "margin-top:10px" }, h("table", {},
        h("tr", {}, ["#", "verdict", "ok", "median s", "Mbit/s", "country", "YouTube", "server"].map((x) => h("th", {}, x))),
        st.rows.map((r) => h("tr", {}, h("td", {}, r.n),
          h("td", {}, h("span", { class: `badge ${["GOOD", "OK"].includes(r.verdict) ? "ok" : r.verdict === "FLAKY" ? "warn" : "bad"}` }, r.verdict)),
          h("td", { class: "num" }, `${r.ok}/${r.total}`), h("td", { class: "num" }, r.median), h("td", { class: "num" }, r.mbit),
          h("td", {}, r.country), h("td", {}, r.youtube), h("td", {}, r.node))))) : null,
      h("details", { style: "margin-top:10px", open: st.state === "running" || st.state === "failed" },
        h("summary", {}, "Output"), h("pre", {}, (st.log || []).join("\n"))));
  };

  const applyLists = async () => {
    try {
      const p = await api("POST", `/api/routers/${id}/probe/preview`);
      confirmApply(id, p.fingerprint, p.config, p.diff, "probe result", null, null);
    } catch (e) { toast(e.message, true); }
  };

  const refresh = async () => { data = await api("GET", `/api/routers/${id}/probe`); drawStatus(); };

  put(main, ...routerTabs(rt, "/probe"),
    h("div", { class: "card" }, h("h2", {}, "Keys and options"),
      field("Keys", f.keys, "Subscription URLs, one per line. Kept on this manager."),
      PROBE_FIELDS.map(([k, label]) => field(label, f[k], null, k)),
      field("YouTube list", h("label", { class: "row" }, f.noyt, "skip"), "Otherwise the fastest servers where YouTube sees RU go into the YouTube section."),
      field("Quick run", h("label", { class: "row" }, f.quick, "fewer requests, short speed test")),
      field("Main section", f.main), field("YouTube section", f.yt),
      field("Every night at", f.schedule), field("Apply the nightly result", h("label", { class: "row" }, f.auto, "automatically (checked and undone if podkop fails)")),
      h("div", { class: "row" },
        h("button", { onclick: async () => { try { await save(); toast("saved"); } catch (e) { toast(e.message, true); } } }, "Save"),
        h("button", { class: "primary", onclick: async () => {
          try { await save(); await api("POST", `/api/routers/${id}/probe/start`); toast("probe started, takes 2–10 minutes"); await refresh(); }
          catch (e) { toast(e.message, true); }
        } }, "Save and run now"))),
    h("div", { class: "card" }, h("h2", {}, "Last run"), statusBox),
    h("div", { class: "card" }, h("h2", {}, "Runs"), h("table", {}, (data.runs || []).map((r) =>
      h("tr", {}, h("td", {}, when(r.started)), h("td", {}, r.trigger), h("td", {}, r.state),
        h("td", {}, r.version_id ? h("a", { href: `#/r/${id}/history` }, `applied as #${r.version_id}`) : ""))))));
  drawStatus();
  const timer = setInterval(() => { if (data.status && data.status.state === "running") refresh().catch(() => {}); }, 10000);
  S.view = { leave: () => clearInterval(timer), onProbe: (m) => m.router_id === id && refresh().catch(() => {}) };
}

// --- logs -------------------------------------------------------------------------------

async function viewLogs(main, id) {
  const rt = getRouter(id);
  const box = h("div", { class: "logbox" });
  const q = h("input", { placeholder: "search stored logs", style: "max-width:320px" });
  const line = (l) => h("div", { class: /\[(fatal|error)\]|ERROR|FATAL/.test(l) ? "err" : /\[warn\]|WARN/.test(l) ? "warn" : "" }, l);
  const fill = (lines) => { put(box, ...lines.map(line)); box.scrollTop = box.scrollHeight; };
  const load = async () => fill((await api("GET", `/api/routers/${id}/logs?limit=1000&q=${encodeURIComponent(q.value)}`)).map((r) => r.line));
  put(main, ...routerTabs(rt, "/logs"),
    h("div", { class: "card" },
      h("div", { class: "row", style: "margin-bottom:10px" }, q,
        h("button", { onclick: load }, "Search"),
        h("button", { onclick: async () => { try { fill(await api("GET", `/api/routers/${id}/logs/recent?lines=500`)); } catch (e) { toast(e.message, true); } } }, "Router's buffer now"),
        h("span", { class: "muted small" }, "podkop, sing-box, podkop-engine and podkop-agent; new lines appear live")),
      box));
  await load();
  S.view = { onLog: (m) => {
    if (m.router_id !== id || q.value) return;
    const stick = box.scrollTop + box.clientHeight >= box.scrollHeight - 30;
    box.append(line(m.line));
    if (box.childNodes.length > 3000) box.firstChild.remove();
    if (stick) box.scrollTop = box.scrollHeight;
  } };
}

// --- history ------------------------------------------------------------------------------

async function viewHistory(main, id) {
  const rt = getRouter(id);
  const list = await api("GET", `/api/routers/${id}/versions`);
  const cls = (s) => ({ applied: "ok", saved: "ok", unchanged: "", rejected: "bad", reverted: "bad", failed: "bad" }[s] || "warn");
  put(main, ...routerTabs(rt, "/history"),
    list.length ? null : h("div", { class: "card muted" }, "Nothing applied from this manager yet."),
    list.map((v) => h("div", { class: "card" },
      h("div", { class: "row spread" },
        h("div", {}, h("b", {}, `#${v.id}`), " ", h("span", { class: `badge ${cls(v.state)}` }, v.state), " ",
          h("span", { class: "muted small" }, `${when(v.t)} · ${v.note || ""}`)),
        ["applied", "saved"].includes(v.state) ? h("button", { class: "small", onclick: () => restore(v.id) }, "Restore this version") : null),
      v.message ? h("p", { class: "small" }, v.message) : null,
      h("details", {}, h("summary", {}, `${v.diff.length} change(s)`), diffList(v.diff)))));

  async function restore(vid) {
    const v = await api("GET", `/api/versions/${vid}`);
    const d = await api("POST", `/api/routers/${id}/diff`, { config: v.config });
    if (!d.diff.length) return toast("the router already has these settings");
    confirmApply(id, d.fingerprint, v.config, d.diff, `restore #${vid}`, () => render(), null);
  }
  S.view = {};
}

// --- start ------------------------------------------------------------------------------

async function loadRouters() {
  for (const r of await api("GET", "/api/routers")) S.routers[r.id] = r;
}

function connect() {
  const live = document.getElementById("live");
  const es = new EventSource("/api/stream");
  es.onopen = () => live.classList.add("on");
  es.onerror = () => live.classList.remove("on");
  es.onmessage = (e) => {
    const m = JSON.parse(e.data);
    const v = S.view || {};
    if (m.type === "router") { S.routers[m.router.id] = m.router; v.onRouter && v.onRouter(m.router); }
    else if (m.type === "event") { v.onEvent && v.onEvent(m); if (["reverted", "revert_failed", "podkop_down", "recovery_failed"].includes(m.event)) toast(`${S.routers[m.router_id]?.name}: ${eventText(m.event, m.data).textContent}`, true); }
    else if (m.type === "log") v.onLog && v.onLog(m);
    else if (m.type === "probe") v.onProbe && v.onProbe(m);
  };
}

(async () => {
  await loadRouters();
  connect();
  window.addEventListener("hashchange", render);
  render();
})();
