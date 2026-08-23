import { highlightJson } from "./json.ts";
import { el, onTab } from "./ui.ts";
import { request } from "./ws.ts";

type Transcript = {
  chatID: string;
  frame: string | null;
  position: string;
  owner: string;
  restingFromEnd: number;
  jumpDistance: number;
  jumpThreshold: number;
  insetsSettling: boolean;
  showsJumpButton: boolean;
  history: string[];
};
type Projection = { name: string; turns: number; blocks: number; samplesMs: number[]; medianMs: number };
type Performance = {
  projections: Projection[];
  search: Record<string, number[]>;
};
type SandboxLog = { level: string; message: string };

const transcriptEl = document.getElementById("diagnostics-transcript")!;
const performanceEl = document.getElementById("diagnostics-performance")!;
const sandboxEl = document.getElementById("diagnostics-sandbox")!;
const metaEl = document.getElementById("diagnostics-meta")!;
const refreshBtn = document.getElementById("diagnostics-refresh") as HTMLButtonElement;

let loaded = false;
let loading = false;

function json(value: unknown, className = "json body"): HTMLElement {
  return el("pre", { class: className, html: highlightJson(JSON.stringify(value, null, 2)) });
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted.length ? sorted[Math.floor(sorted.length / 2)]! : 0;
}

function milliseconds(value: number): string {
  if (value < 1) return `${value.toFixed(2)} ms`;
  if (value < 10) return `${value.toFixed(1)} ms`;
  return `${Math.round(value)} ms`;
}

function kv(entries: [string, unknown][]): HTMLElement {
  const list = el("dl", { class: "diagnostic-kv" });
  for (const [key, value] of entries) {
    list.append(el("dt", {}, key), el("dd", {}, String(value ?? "—")));
  }
  return list;
}

function renderTranscript(result: { ok: boolean; transcript?: Transcript; error?: string }) {
  if (!result.ok || !result.transcript) {
    transcriptEl.replaceChildren(el("div", { class: "empty" }, `unavailable: ${result.error ?? "no active transcript"}`));
    return;
  }
  const transcript = result.transcript;
  transcriptEl.replaceChildren(
    kv([
      ["chat", transcript.chatID],
      ["frame", transcript.frame],
      ["position", transcript.position],
      ["owner", transcript.owner],
      ["resting from end", transcript.restingFromEnd],
      ["jump", `${transcript.jumpDistance} / ${transcript.jumpThreshold}`],
      ["insets settling", transcript.insetsSettling],
      ["jump button", transcript.showsJumpButton],
    ]),
    el("div", { class: "diagnostic-section" }, `Recent geometry · ${transcript.history.length}`),
    el("pre", { class: "diagnostic-history" }, transcript.history.join("\n") || "no geometry history"),
  );
}

function renderPerformance(result: { ok: boolean; data?: Performance; error?: string }) {
  if (!result.ok || !result.data) {
    performanceEl.replaceChildren(el("div", { class: "empty" }, `unavailable: ${result.error ?? "no snapshot"}`));
    return;
  }
  const data = result.data;
  const table = el("table", { class: "diagnostic-table" },
    el("thead", {}, el("tr", {}, el("th", {}, "projection"), el("th", {}, "turns"), el("th", {}, "blocks"), el("th", {}, "median"))),
    el("tbody", {}, ...data.projections.map((projection) => el("tr", {},
      el("td", {}, projection.name),
      el("td", {}, String(projection.turns)),
      el("td", {}, String(projection.blocks)),
      el("td", {}, milliseconds(projection.medianMs)),
    ))),
  );
  const search = Object.entries(data.search).map(([name, samples]) => [name.replace(/SamplesMs$/, ""), milliseconds(median(samples))] as [string, string]);
  performanceEl.replaceChildren(
    el("div", { class: "diagnostic-section" }, "Projection reducer"),
    table,
    el("div", { class: "diagnostic-section" }, "Service search medians"),
    kv(search),
  );
}

async function load() {
  if (loading) return;
  loading = true;
  refreshBtn.disabled = true;
  metaEl.textContent = "loading…";
  transcriptEl.replaceChildren(el("div", { class: "empty" }, "loading…"));
  performanceEl.replaceChildren(el("div", { class: "empty" }, "loading…"));
  try {
    const [transcript, performance] = await Promise.all([
      request("get-transcript"),
      request("get-performance", {}, 30000),
    ]);
    renderTranscript(transcript);
    renderPerformance(performance);
    metaEl.textContent = new Date().toLocaleTimeString();
  } finally {
    loading = false;
    refreshBtn.disabled = false;
  }
}

function renderSandbox() {
  const sessionInput = el<HTMLInputElement>("input", {
    class: "agent-input", placeholder: "active chat (or paste a chat id prefix)", spellcheck: "false",
  });
  const script = el<HTMLTextAreaElement>("textarea", { class: "args", spellcheck: "false" });
  script.value = "return Object.keys(ox).sort();";
  const status = el("div", { class: "status" });
  const result = el("div");
  const run = el<HTMLButtonElement>("button", {
    class: "invoke-btn",
    click: async () => {
      run.disabled = true;
      status.textContent = "running…";
      status.className = "status";
      result.replaceChildren(el("div", { class: "empty" }, "waiting…"));
      const started = performance.now();
      try {
        const response = await request("sandbox-eval", { sessionId: sessionInput.value.trim(), script: script.value }, 60000);
        const elapsed = Math.round(performance.now() - started);
        status.textContent = `${response.ok ? "ok" : "failed"} · ${elapsed}ms`;
        status.className = response.ok ? "status ok" : "status err";
        const nodes: Node[] = [];
        if (response.error) nodes.push(el("pre", { class: "json err" }, String(response.error)));
        if (response.ok) nodes.push(json(response.value));
        const logs = (response.logs ?? []) as SandboxLog[];
        if (logs.length) nodes.push(
          el("div", { class: "diagnostic-section sandbox-logs" }, `Console · ${logs.length}`),
          el("pre", { class: "diagnostic-history" }, logs.map((entry) => `${entry.level.toUpperCase()} ${entry.message}`).join("\n")),
        );
        result.replaceChildren(...nodes);
      } finally {
        run.disabled = false;
      }
    },
  }, "Run");
  sandboxEl.replaceChildren(
    el("div", { class: "action-desc" }, "Runs JavaScript in a chat's agent sandbox with its bound ox namespace. This can mutate the selected chat's on-device data."),
    el("label", { class: "args-label" }, "chat"),
    sessionInput,
    el("label", { class: "args-label" }, "script"),
    script,
    el("div", { class: "form-actions" }, run, status),
    result,
  );
}

onTab("diagnostics", () => {
  if (!loaded) {
    loaded = true;
    renderSandbox();
    void load();
  }
});

refreshBtn.addEventListener("click", () => { void load(); });
