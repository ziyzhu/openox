import { request } from "./ws.ts";
import { el, onTab } from "./ui.ts";

type LogRow = { seq: number; time: string; level: string; category: string; thread?: string; location: string; message: string };

const LEVELS = ["debug", "info", "warning", "error"];

const viewLogs = document.getElementById("view-logs")!;
const listEl = document.getElementById("logs-list")!;
const countEl = document.getElementById("logs-count")!;
const levelSel = document.getElementById("logs-level") as HTMLSelectElement;
const grepEl = document.getElementById("logs-grep") as HTMLInputElement;
const refreshBtn = document.getElementById("logs-refresh") as HTMLButtonElement;
const copyBtn = document.getElementById("logs-copy") as HTMLButtonElement;

let rows: LogRow[] = [];
let loaded = false;
let lastSig = "";

const POLL_MS = 1500;

onTab("logs", () => {
  if (!loaded) { loaded = true; load(); }
});

function filtered(): LogRow[] {
  const min = LEVELS.indexOf(levelSel.value);
  const needle = grepEl.value.trim().toLowerCase();
  return rows.filter((r) => {
    if (min >= 0 && LEVELS.indexOf(r.level) < min) return false;
    if (needle && !r.message.toLowerCase().includes(needle) && !r.category.toLowerCase().includes(needle)) return false;
    return true;
  });
}

function line(r: LogRow): string {
  const thread = r.thread ? ` (${r.thread})` : "";
  return `${r.time.slice(11, 23)} ${r.level.toUpperCase()} [${r.category}]${thread} ${r.location} ${r.message}`;
}

function render() {
  const atBottom = listEl.scrollHeight - listEl.scrollTop - listEl.clientHeight < 40;
  const prevTop = listEl.scrollTop;
  const shown = filtered();
  countEl.textContent = String(shown.length);
  listEl.replaceChildren();
  if (shown.length === 0) {
    listEl.append(el("div", { class: "empty" }, rows.length === 0 ? "no logs" : "no logs match filter"));
    return;
  }
  for (const r of shown) {
    listEl.append(el("div", { class: "log-row" },
      el("div", { class: "log-head" },
        el("span", { class: "log-time" }, r.time.slice(11, 23)),
        el("span", { class: `log-level ${r.level}` }, r.level.toUpperCase()),
        el("span", { class: "log-cat" }, r.category),
        ...(r.thread ? [el("span", { class: "log-loc" }, `(${r.thread})`)] : []),
        el("span", { class: "log-loc" }, r.location),
      ),
      el("div", { class: "log-msg" }, r.message),
    ));
  }
  listEl.scrollTop = atBottom ? listEl.scrollHeight : prevTop;
}

async function load(quiet = false) {
  if (!quiet) listEl.replaceChildren(el("div", { class: "empty" }, "loading…"));
  const res = await request("get-logs");
  if (!res?.ok) {
    if (!quiet) listEl.replaceChildren(el("div", { class: "empty" }, `failed: ${res?.error ?? "unknown"}`));
    return;
  }
  rows = (res.logs ?? []) as LogRow[];
  const sig = `${rows.length}:${rows.at(-1)?.seq ?? -1}`;
  if (quiet && sig === lastSig) return;
  lastSig = sig;
  render();
}

setInterval(() => { if (!viewLogs.hidden && loaded) load(true); }, POLL_MS);

levelSel.addEventListener("change", render);
grepEl.addEventListener("input", render);
refreshBtn.addEventListener("click", () => { load(); });
copyBtn.addEventListener("click", async () => {
  const text = filtered().map(line).join("\n");
  try {
    await navigator.clipboard.writeText(text);
    copyBtn.textContent = "Copied";
    setTimeout(() => { copyBtn.textContent = "Copy"; }, 1000);
  } catch {
    copyBtn.textContent = "Failed";
    setTimeout(() => { copyBtn.textContent = "Copy"; }, 1000);
  }
});
