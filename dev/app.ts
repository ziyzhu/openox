import { highlightJson } from "./json.ts";
import { el } from "./ui.ts";
import {
  type Snapshot,
  type SnapshotHeader,
  type SnapshotDelta,
  type ToolDecl,
  type UsageBreakdown,
  fmtK,
  oneLine,
  extractCatalog,
  summarizeMessage,
  summarizeBlock,
  usageBreakdown,
} from "./snapshot.ts";

const meta = document.getElementById("meta")!;
const systemEl = document.getElementById("system")!;
const soulEl = document.getElementById("soul")!;
const memoryEl = document.getElementById("memory")!;
const chatListEl = document.getElementById("chat-list")!;
const toolsEl = document.getElementById("tools")!;
const toolsCount = document.getElementById("tools-count")!;
const messagesEl = document.getElementById("messages")!;
const blocksEl = document.getElementById("blocks")!;
const messagesCount = document.getElementById("messages-count")!;
const blocksCount = document.getElementById("blocks-count")!;
const usageEl = document.getElementById("usage")!;
const usageBar = document.getElementById("usage-bar")!;
const usageLegend = document.getElementById("usage-legend")!;

const fmt = (v: unknown) => JSON.stringify(v, null, 2);

function row(kindLabel: string, kindClass: string, summary: string, body: unknown): HTMLElement {
  const isJson = typeof body !== "string";
  const text = isJson ? fmt(body) : body as string;
  const r = el("div", { class: "row collapsed" });
  const chevron = el("span", { class: "chevron" });
  const head = el("div", { class: "head" },
    chevron,
    el("span", { class: `kind ${kindClass}` }, kindLabel),
    el("span", { class: "summary" }, summary),
  );
  const bodyEl = isJson
    ? el("pre", { class: "json body", html: highlightJson(text) })
    : el("pre", { class: "json body" }, text);
  r.append(head, bodyEl);
  head.addEventListener("click", () => r.classList.toggle("collapsed"));
  return r;
}

function toolRows(t: ToolDecl, tok: number): HTMLElement[] {
  const catalog = extractCatalog(t.description);
  const parent = catalog
    ? row(t.name, "tool", oneLine(catalog.prose), { ...t, description: catalog.prose })
    : row(t.name, "tool", oneLine(t.description), t);
  parent.querySelector(".head")!.append(el("span", { class: "tok" }, "~" + fmtK(tok)));
  if (!catalog) return [parent];
  const kids = Object.entries(catalog.fns).map(([name, schema]) => {
    const desc = typeof schema === "string" ? schema : (schema as any)?.description ?? "";
    const kid = row(name, "fn", oneLine(desc), schema);
    kid.classList.add("nested");
    kid.querySelector(".chevron")!.after(el("span", { class: "nest" }, "└"));
    return kid;
  });
  return [parent, ...kids];
}

function renderUsage(u: UsageBreakdown) {
  const pct = (tok: number) => `${((tok / u.maxCtx) * 100).toFixed(2)}%`;

  usageBar.replaceChildren(
    el("div", { class: "seg system", style: `width:${pct(u.system)}` }),
    el("div", { class: "seg tools", style: `width:${pct(u.tools)}` }),
    el("div", { class: "seg messages", style: `width:${pct(u.messages)}` }),
  );

  const seg = (cls: string, label: string, tok: number) =>
    el("span", { class: `lg ${cls}` }, el("i"), `${label} ${fmtK(tok)}`);
  const legend: (Node | string)[] = [
    seg("system", "system", u.system),
    seg("tools", "tools", u.tools),
    seg("messages", "messages", u.messages),
    el("span", { class: "total" }, `${fmtK(u.input)} / ${fmtK(u.maxCtx)} (${Math.round((u.input / u.maxCtx) * 100)}%)`),
  ];
  if (!u.estimated) {
    legend.push(u.cached > 0
      ? el("span", { class: "cache" }, `${fmtK(u.cached)} cached (${Math.round((u.cached / u.input) * 100)}%)`)
      : el("span", { class: "cache" }, "0 cached"));
  } else {
    legend.push(el("span", { class: "est" }, "estimated · no usage yet"));
  }
  usageLegend.replaceChildren(...legend);
}

function render(snap: Snapshot) {
  meta.textContent = snap.id
    ? `id=${snap.id.slice(0, 8)} · model=${snap.model.id} · ctx=${snap.model.maxContext.toLocaleString()} · received ${snap.receivedAt?.slice(11, 19) ?? "?"}`
    : "no active chat";

  systemEl.textContent = snap.systemPrompt || "(empty)";
  soulEl.textContent = snap.soul || "(empty)";
  memoryEl.textContent = snap.memory || "(empty)";

  const tools = snap.tools ?? [];
  const u = usageBreakdown(snap);

  usageEl.hidden = !snap.id;
  if (snap.id) renderUsage(u);

  toolsCount.textContent = String(tools.length);
  toolsEl.replaceChildren();
  if (tools.length === 0) {
    toolsEl.append(el("div", { class: "empty" }, "no tools"));
  } else {
    tools.forEach((t, i) => toolsEl.append(...toolRows(t, u.toolToks[i]!)));
  }

  messagesCount.textContent = String(snap.messages.length);
  messagesEl.replaceChildren();
  if (snap.messages.length === 0) {
    messagesEl.append(el("div", { class: "empty" }, "no messages yet"));
  } else {
    snap.messages.forEach((m: any) => {
      const { kind, cls, summary } = summarizeMessage(m);
      messagesEl.append(row(kind, cls, summary, m));
    });
  }

  blocksCount.textContent = String(snap.blocks.length);
  blocksEl.replaceChildren();
  if (snap.blocks.length === 0) {
    blocksEl.append(el("div", { class: "empty" }, "no blocks yet"));
  } else {
    snap.blocks.forEach((b: any) => {
      const { kind, cls, summary } = summarizeBlock(b);
      blocksEl.append(row(kind, cls, summary, b));
    });
  }
}

const emptySnapshot: Snapshot = {
  id: "",
  model: { id: "", maxTokens: 0, maxContext: 0 },
  systemPrompt: "",
  soul: "",
  memory: "",
  tools: [],
  messages: [],
  blocks: [],
};

import { subscribe, onState, request } from "./ws.ts";

type Envelope =
  | { type: "header"; data: SnapshotHeader }
  | { type: "delta"; data: SnapshotDelta }
  | { type: "clear" };

let live: Snapshot = { ...emptySnapshot };

type ChatRow = {
  id: string;
  title: string;
  model: string;
  createdAt: string;
  lastActivity: string | null;
  messages: number;
  blocks: number;
  active: boolean;
};

let chats: ChatRow[] = [];
let selectedId: string | null = null;

function renderChatList() {
  const shownId = selectedId ?? chats.find((c) => c.active)?.id ?? null;
  chatListEl.replaceChildren(...chats.map((c) => {
    const cls = "chat-chip" + (c.id === shownId ? " selected" : "") + (c.active ? " active" : "");
    const chip = el("button", { class: cls, "data-id": c.id },
      el("span", { class: "chat-chip-title" }, c.title || "(untitled)"),
      el("span", { class: "chat-chip-meta" },
        ...(c.active ? [el("span", { class: "dot" })] : []),
        typeof c.messages === "number" ? `${c.messages} msg${c.messages === 1 ? "" : "s"}` : c.model,
      ),
    );
    chip.addEventListener("click", () => selectChat(c.id));
    return chip;
  }));
}

async function loadChats() {
  const res = await request("list-chats");
  if (!res.ok) return;
  chats = res.chats ?? [];
  renderChatList();
}

async function selectChat(id: string) {
  selectedId = chats.find((c) => c.id === id)?.active ? null : id;
  renderChatList();
  const res = await request("get-chat", { sessionId: id });
  if (res.ok && res.data) render({ ...res.data, receivedAt: new Date().toISOString() });
  else if (res.ok) meta.textContent = "chat not found";
}

onState((s) => {
  if (s === "open") { meta.textContent = "connected · waiting for snapshot…"; loadChats(); }
  else if (s === "connecting") meta.textContent = "connecting…";
  else meta.textContent = "disconnected · reconnecting…";
});

function renderLiveIfActive() {
  if (selectedId === null || selectedId === live.id) render({ ...live, receivedAt: new Date().toISOString() });
}

subscribe((msg) => {
  const env = msg as Envelope;
  if (env.type === "header") {
    live = { ...live, ...env.data };
    loadChats();
    renderLiveIfActive();
  } else if (env.type === "delta") {
    live = { ...live, id: env.data.id, messages: env.data.messages, blocks: env.data.blocks };
    loadChats();
    renderLiveIfActive();
  } else if (env.type === "clear") {
    live = { ...emptySnapshot };
    loadChats();
    if (selectedId === null) render(emptySnapshot);
  }
});
