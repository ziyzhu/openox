import { request } from "./ws.ts";
import { el, onTab } from "./ui.ts";
import { highlightJson } from "./json.ts";

type Action = { id: string; description?: string; baseUrl?: string; requireAuth?: boolean; requireApproval?: boolean; defaultArgs?: unknown };
type Manifest = { name?: string; description?: string; baseUrl?: string; faviconUrl?: string; actions?: Action[] } & Record<string, unknown>;
type Listing = { domain: string; manifest: Manifest };

type PageState = {
  url: string | null;
  title: string | null;
  isLoading: boolean;
  progress: number;
  canGoBack: boolean;
  canGoForward: boolean;
};
type LiveService = { domain: string; title: string; phase: string; auth: string; page?: PageState };

type Selection =
  | { domain: string; kind: "action"; action: string }
  | { domain: string; kind: "eval" }
  | null;

const listEl = document.getElementById("services-list")!;
const countEl = document.getElementById("services-count")!;
const formEl = document.getElementById("action-form")!;
const titleEl = document.getElementById("action-title")!;
const resultEl = document.getElementById("result")!;
const resultMeta = document.getElementById("result-meta")!;

let services: Listing[] = [];
const liveByDomain = new Map<string, LiveService>();
let openDomain: string | null = null;
let selection: Selection = null;
let loaded = false;

onTab("services", () => {
  if (!loaded) { loaded = true; loadServices(); }
});

async function loadServices() {
  listEl.replaceChildren(el("div", { class: "empty" }, "loading…"));
  const ok = await refreshState();
  if (!ok) { listEl.replaceChildren(el("div", { class: "empty" }, "failed to reach the iOS app")); return; }
  renderList();
}

// The registry rides the debug WS now (the api only speaks git): the app reports
// each service's manifest from its cloned repo alongside its live state.
async function refreshState(): Promise<boolean> {
  const res = await request("list-services");
  liveByDomain.clear();
  if (!res?.ok || !Array.isArray(res.services)) return false;
  const rows = res.services as (LiveService & { manifest?: Manifest; favicon?: string })[];
  for (const s of rows) liveByDomain.set(s.domain, s);
  services = rows
    .filter(s => !!s.manifest && (s.manifest.actions?.length ?? 0) > 0)
    .map(s => ({ domain: s.domain, manifest: { ...s.manifest!, faviconUrl: s.favicon } }))
    .sort((a, b) => a.domain.localeCompare(b.domain));
  countEl.textContent = String(services.length);
  return true;
}

function phaseDotClass(phase: string): string {
  if (phase === "active") return "dot ok";
  if (phase === "loading") return "dot warn";
  return "dot";
}

function authCase(auth: string): string {
  return auth.split("(")[0];
}

function authLabel(auth: string): string {
  const c = authCase(auth);
  if (c === "signedIn") return "signed in";
  if (c === "signedOut") return "signed out";
  return c;
}

function renderList() {
  listEl.replaceChildren();

  if (services.length === 0) {
    listEl.append(el("div", { class: "empty" }, "no services"));
    return;
  }

  for (const s of services) {
    const open = s.domain === openDomain;
    const live = liveByDomain.get(s.domain);

    const status = el("div", { class: "svc-status" });
    if (live) {
      status.append(
        el("span", { class: phaseDotClass(live.phase), title: `phase: ${live.phase}` }),
        el("span", { class: "svc-phase" }, live.phase),
      );
      if (live.auth && authCase(live.auth) !== "unknown") {
        status.append(
          el("span", { class: "sep" }, "·"),
          el("span", { class: `svc-auth ${authCase(live.auth) === "signedIn" ? "in" : "out"}` }, authLabel(live.auth)),
        );
      }
    } else {
      status.append(el("span", { class: "svc-phase dim" }, "—"));
    }

    const favicon = s.manifest.faviconUrl
      ? el("img", { class: "svc-favicon", src: String(s.manifest.faviconUrl), alt: "" })
      : el("span", { class: "svc-favicon placeholder" });

    const chevron = el("span", { class: open ? "svc-chev open" : "svc-chev" });

    listEl.append(el("div", {
      class: open ? "svc head open" : "svc head",
      click: () => { toggleOpen(s.domain); },
    },
      chevron,
      favicon,
      el("span", { class: "svc-domain" }, s.domain),
      status,
    ));

    if (!open) continue;

    if (live?.page) renderPageDetail(live.page);

    const group = el("div", { class: "svc-actions" });

    for (const a of s.manifest.actions ?? []) {
      const active = selection?.kind === "action" && selection.domain === s.domain && selection.action === a.id;
      const tags = el("span", { class: "action-tags" });
      if (a.baseUrl) tags.append(el("span", { class: "tag" }, "separate page"));
      if (a.requireAuth) tags.append(el("span", { class: "tag auth" }, "auth"));
      if (a.requireApproval) tags.append(el("span", { class: "tag approval" }, "approval"));
      group.append(el("div", {
        class: active ? "action-row active" : "action-row",
        click: () => { selection = { domain: s.domain, kind: "action", action: a.id }; renderList(); renderActionForm(s, a); },
      },
        el("span", { class: "action-id" }, a.id),
        tags,
      ));
    }

    const evalActive = selection?.kind === "eval" && selection.domain === s.domain;
    group.append(el("div", {
      class: evalActive ? "action-row eval active" : "action-row eval",
      click: () => { selection = { domain: s.domain, kind: "eval" }; renderList(); renderEvalForm(s.domain); },
    },
      el("span", { class: "action-id" }, "evaluate JS"),
      el("span", { class: "action-tags" }, el("span", { class: "tag eval" }, "‹/›")),
    ));

    listEl.append(group);
  }
}

function renderPageDetail(w: PageState) {
  const row = (label: string, value: Node | string) =>
    el("div", { class: "kv-row" },
      el("span", { class: "kv-key" }, label),
      typeof value === "string" ? el("span", { class: "kv-val" }, value) : value,
    );

  const loading = w.isLoading
    ? `loading · ${Math.round(w.progress * 100)}%`
    : (w.progress >= 1 ? "loaded" : "idle");

  listEl.append(el("div", { class: "svc-detail" },
    row("URL", w.url ?? "—"),
    row("State", loading),
  ));
}

function toggleOpen(domain: string) {
  if (openDomain === domain) {
    openDomain = null;
    if (selection?.domain === domain) { selection = null; clearForm(); }
  } else {
    openDomain = domain;
  }
  renderList();
}

function clearForm() {
  titleEl.textContent = "Action";
  formEl.replaceChildren(el("div", { class: "empty" }, "select an action or evaluate"));
}

function renderActionForm(s: Listing, a: Action) {
  titleEl.textContent = `${s.domain} · ${a.id}`;
  const desc = a.description ?? "";
  const textarea = el<HTMLTextAreaElement>("textarea", { class: "args", spellcheck: "false" });
  textarea.value = a.defaultArgs !== undefined ? JSON.stringify(a.defaultArgs, null, 2) : "{}";
  const status = el("div", { class: "status" });
  const submit = el<HTMLButtonElement>("button", {
    class: "invoke-btn",
    click: () => invoke(s.domain, a.id, textarea.value, submit, status),
  }, "Invoke");
  formEl.replaceChildren(
    desc ? el("div", { class: "action-desc" }, desc) : document.createTextNode(""),
    el("label", { class: "args-label" }, "args (JSON)"),
    textarea,
    el("div", { class: "form-actions" }, submit, status),
  );
}

function renderEvalForm(domain: string) {
  titleEl.textContent = `${domain} · evaluate`;
  const textarea = el<HTMLTextAreaElement>("textarea", { class: "args", spellcheck: "false" });
  textarea.value = "return document.title;";
  const status = el("div", { class: "status" });
  const submit = el<HTMLButtonElement>("button", {
    class: "invoke-btn",
    click: () => evaluate(domain, textarea.value, submit, status),
  }, "Run");
  formEl.replaceChildren(
    el("div", { class: "action-desc" }, "Runs on the service page via callJavaScript. Use return to send a value back; loads the page if idle."),
    el("label", { class: "args-label" }, "script (JS)"),
    textarea,
    el("div", { class: "form-actions" }, submit, status),
  );
}

async function invoke(domain: string, action: string, argsJson: string, btn: HTMLButtonElement, status: HTMLElement) {
  let args: unknown;
  try { args = JSON.parse(argsJson); }
  catch (e) { status.textContent = `invalid JSON: ${(e as Error).message}`; status.className = "status err"; return; }
  await runRequest("invoke-action", { domain, action, args }, btn, status);
}

async function evaluate(domain: string, script: string, btn: HTMLButtonElement, status: HTMLElement) {
  await runRequest("evaluate", { domain, script }, btn, status);
}

async function runRequest(kind: string, args: Record<string, unknown>, btn: HTMLButtonElement, status: HTMLElement) {
  btn.disabled = true;
  status.textContent = "running…";
  status.className = "status";
  resultEl.replaceChildren(el("div", { class: "empty" }, "waiting…"));
  resultMeta.textContent = "";

  const start = performance.now();
  try {
    const res = await request(kind, args, 30000);
    const ms = Math.round(performance.now() - start);
    resultMeta.textContent = `${ms}ms`;
    if (res?.ok) {
      status.textContent = `ok · ${ms}ms`;
      status.className = "status ok";
      resultEl.replaceChildren(el("pre", { class: "json body", html: highlightJson(JSON.stringify(res.value, null, 2)) }));
    } else {
      status.textContent = `failed · ${ms}ms`;
      status.className = "status err";
      resultEl.replaceChildren(el("pre", { class: "json body err" }, String(res?.error ?? "unknown")));
    }
  } finally {
    btn.disabled = false;
    await refreshState();
    renderList();
  }
}
