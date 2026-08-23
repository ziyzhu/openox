import { request } from "./ws.ts";
import { el, onTab } from "./ui.ts";
import { highlightJson } from "./json.ts";
import { oneLine, type ClientEntry, type AgentRunResult } from "./snapshot.ts";

const controlsEl = document.getElementById("agent-controls")!;
const resultEl = document.getElementById("agent-result")!;
const metaEl = document.getElementById("agent-meta")!;

let clients: ClientEntry[] = [];
let loaded = false;

onTab("agent", () => {
  if (!loaded) { loaded = true; loadModels(); }
});

async function loadModels() {
  controlsEl.replaceChildren(el("div", { class: "empty" }, "loading…"));
  const res = await request("list-models");
  if (!res?.ok) {
    controlsEl.replaceChildren(el("div", { class: "empty" }, `failed: ${res?.error ?? "unknown"}`));
    return;
  }
  clients = (res.clients ?? []) as ClientEntry[];
  renderControls();
}

function renderControls() {
  if (clients.length === 0) {
    controlsEl.replaceChildren(el("div", { class: "empty" }, "no providers registered"));
    return;
  }

  const providerSel = el<HTMLSelectElement>("select", { class: "agent-select", change: () => fillModels() });
  for (const c of clients) {
    providerSel.append(el("option", { value: c.id }, `${c.displayName}  [${c.regions.join(", ")}]`));
  }

  const modelSel = el<HTMLSelectElement>("select", { class: "agent-select" });
  function fillModels() {
    const client = clients.find(c => c.id === providerSel.value) ?? clients[0]!;
    modelSel.replaceChildren();
    for (const m of client.models) {
      modelSel.append(el("option", { value: m.id }, `${m.displayName}  ·  ctx ${m.maxContext.toLocaleString()}`));
    }
  }
  fillModels();

  const sessionInput = el<HTMLInputElement>("input", {
    class: "agent-input", placeholder: "active chat (or paste a chat id prefix)", spellcheck: "false",
  });

  const promptArea = el<HTMLTextAreaElement>("textarea", {
    class: "args", spellcheck: "false", placeholder: "leave empty to replay the chat 1:1",
  });

  const status = el("div", { class: "status" });
  const run = el<HTMLButtonElement>("button", {
    class: "invoke-btn",
    click: () => runAgent(providerSel.value, modelSel.value, sessionInput.value.trim(), promptArea.value.trim(), run, status),
  }, "Run");

  controlsEl.replaceChildren(
    el("div", { class: "action-desc" }, "Runs the chosen provider+model as a single turn. With a prompt, it seeds the chat's system prompt + history + tools (if any) and appends your message; empty prompt replays the chat 1:1. Read-only — the session is never mutated."),
    el("label", { class: "args-label" }, "provider"),
    providerSel,
    el("label", { class: "args-label" }, "model"),
    modelSel,
    el("label", { class: "args-label" }, "chat"),
    sessionInput,
    el("label", { class: "args-label" }, "prompt"),
    promptArea,
    el("div", { class: "form-actions" }, run, status),
  );
}

async function runAgent(clientId: string, modelId: string, sessionId: string, prompt: string, btn: HTMLButtonElement, status: HTMLElement) {
  btn.disabled = true;
  status.textContent = "running…";
  status.className = "status";
  resultEl.replaceChildren(el("div", { class: "empty" }, "waiting…"));
  metaEl.textContent = "";

  const start = performance.now();
  try {
    const res = await request("run-agent", { sessionId, clientId, modelId, prompt }, 120000) as AgentRunResult & { error?: string };
    const ms = Math.round(performance.now() - start);
    if (res?.ok) {
      status.textContent = `ok · ${ms}ms`;
      status.className = "status ok";
    } else {
      status.textContent = `failed · ${ms}ms`;
      status.className = "status err";
    }
    renderRun(res);
  } finally {
    btn.disabled = false;
  }
}

function assistantText(message: any): string {
  const blocks = message?.content ?? [];
  const parts: string[] = [];
  for (const b of blocks) {
    if (b?.type === "text") {
      const t = typeof b.text === "string" ? b.text : b.text?.text ?? "";
      if (t) parts.push(t);
    } else if (b?.type === "thinking") {
      const t = typeof b.thinking === "string" ? b.thinking : b.thinking?.text ?? "";
      if (t) parts.push(`[thinking] ${oneLine(t)}`);
    } else if (b?.type === "toolCall") {
      const tc = b.toolCall ?? b;
      parts.push(`→ ${tc.name ?? "tool"}(${JSON.stringify(tc.arguments ?? {})})`);
    }
  }
  return parts.join("\n");
}

function renderRun(run: AgentRunResult & { error?: string }) {
  const u = run.message?.usage;
  const stop = run.message?.stopReason ?? "?";
  const tokens = u ? `${u.input}/${u.output} tok` : "no usage";
  const ttft = run.ttftMs != null ? `ttft ${run.ttftMs}ms` : "ttft —";
  const total = run.totalMs != null ? `total ${run.totalMs}ms` : "total —";
  metaEl.textContent = `${stop} · ${tokens} · ${ttft} · ${total}`;

  const text = run.message ? assistantText(run.message) : "";
  const errorMessage = run.message?.errorMessage ?? run.error;

  const nodes: Node[] = [];
  if (errorMessage) nodes.push(el("pre", { class: "json body err" }, errorMessage));
  nodes.push(el("pre", { class: "agent-text" }, text || "(no text content)"));
  if (run.message) {
    nodes.push(el("details", { class: "agent-raw" },
      el("summary", {}, "raw message"),
      el("pre", { class: "json body", html: highlightJson(JSON.stringify(run.message, null, 2)) }),
    ));
  }
  resultEl.replaceChildren(...nodes);
}
