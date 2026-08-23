import { el, onTab } from "./ui.ts";

type Commit = {
  sha: string;
  short: string;
  parents: string[];
  author: string;
  date: string;
  subject: string;
};

type CommitDetail = Commit & {
  email: string;
  body: string;
  files: { status: string; path: string }[];
  diff: string;
};

const timelineEl = document.getElementById("timeline")!;
const countEl = document.getElementById("timeline-count")!;
const checkinTitle = document.getElementById("checkin-title")!;
const checkinEl = document.getElementById("checkin")!;
const sourceSel = document.getElementById("registry-source") as HTMLSelectElement;

const SOURCE_KEY = "dev.registry.source";
let source = sessionStorage.getItem(SOURCE_KEY) || "local";
sourceSel.value = source;

function url(path: string): string {
  const sep = path.includes("?") ? "&" : "?";
  return `${path}${sep}source=${encodeURIComponent(source)}`;
}

let commits: Commit[] = [];
let selected: string | null = null;
let loaded = false;

const DAY_FMT = new Intl.DateTimeFormat(undefined, { weekday: "short", month: "short", day: "numeric", year: "numeric" });
const TIME_FMT = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit", hour12: false });

function dayKey(iso: string): string {
  return iso.slice(0, 10);
}

function dayLabel(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso.slice(0, 10);
  return DAY_FMT.format(d);
}

function timeLabel(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso.slice(11, 16);
  return TIME_FMT.format(d);
}

onTab("registry", () => {
  if (!loaded) { loaded = true; load(); }
});

sourceSel.addEventListener("change", () => {
  const next = sourceSel.value;
  if (next === source) return;
  source = next;
  sessionStorage.setItem(SOURCE_KEY, source);
  selected = null;
  commits = [];
  checkinEl.replaceChildren();
  checkinTitle.textContent = "Check-in";
  load();
});

async function load() {
  timelineEl.replaceChildren(el("div", { class: "empty" }, "loading…"));
  let res: Response;
  try {
    res = await fetch(url("/registry/log?limit=300"));
  } catch (e) {
    timelineEl.replaceChildren(el("div", { class: "empty" }, `failed: ${(e as Error).message}`));
    return;
  }
  const body = await res.json().catch(() => ({ ok: false, error: "bad json" }));
  if (!body?.ok) {
    timelineEl.replaceChildren(el("div", { class: "empty" }, `failed: ${body?.error ?? res.statusText}`));
    return;
  }
  commits = body.commits as Commit[];
  renderTimeline();
  if (commits.length && (!selected || !commits.find((c) => c.sha === selected))) {
    select(commits[0].sha);
  }
}

function renderTimeline() {
  countEl.textContent = String(commits.length);
  timelineEl.replaceChildren();
  if (commits.length === 0) {
    timelineEl.append(el("div", { class: "empty" }, "no history yet"));
    return;
  }
  let prevDay: string | null = null;
  for (const c of commits) {
    const key = dayKey(c.date);
    if (key !== prevDay) {
      timelineEl.append(el("div", { class: "tl-day" }, dayLabel(c.date)));
      prevDay = key;
    }
    const row = el("button", {
      class: "tl-row" + (selected === c.sha ? " selected" : ""),
      "data-sha": c.sha,
      click: () => select(c.sha),
    },
      el("span", { class: "tl-time" }, timeLabel(c.date)),
      el("span", { class: "tl-dot" }),
      el("span", { class: "tl-subject" }, c.subject || "(no subject)"),
      el("span", { class: "tl-author" }, c.author),
    );
    timelineEl.append(row);
  }
}

async function select(sha: string) {
  selected = sha;
  for (const row of timelineEl.querySelectorAll<HTMLElement>(".tl-row")) {
    row.classList.toggle("selected", row.dataset.sha === sha);
  }
  checkinTitle.textContent = `Check-in ${sha.slice(0, 10)}`;
  checkinEl.replaceChildren(el("div", { class: "empty" }, "loading…"));

  let res: Response;
  try {
    res = await fetch(url(`/registry/commit/${encodeURIComponent(sha)}`));
  } catch (e) {
    checkinEl.replaceChildren(el("div", { class: "empty" }, `failed: ${(e as Error).message}`));
    return;
  }
  const body = await res.json().catch(() => ({ ok: false, error: "bad json" }));
  if (!body?.ok) {
    checkinEl.replaceChildren(el("div", { class: "empty" }, `failed: ${body?.error ?? res.statusText}`));
    return;
  }
  if (selected !== sha) return;
  renderCheckin(body as CommitDetail);
}

function renderCheckin(c: CommitDetail) {
  const header = el("div", { class: "ck-head" },
    el("div", { class: "ck-subject" }, c.subject || "(no subject)"),
    el("div", { class: "ck-meta" },
      el("span", { class: "ck-meta-k" }, "sha"),
      el("span", { class: "ck-meta-v ck-mono" }, c.sha),
    ),
    el("div", { class: "ck-meta" },
      el("span", { class: "ck-meta-k" }, "parents"),
      el("span", { class: "ck-meta-v ck-mono" }, c.parents.length ? c.parents.join("  ") : "(root)"),
    ),
    el("div", { class: "ck-meta" },
      el("span", { class: "ck-meta-k" }, "author"),
      el("span", { class: "ck-meta-v" }, `${c.author} <${c.email}>`),
    ),
    el("div", { class: "ck-meta" },
      el("span", { class: "ck-meta-k" }, "date"),
      el("span", { class: "ck-meta-v ck-mono" }, c.date),
    ),
  );

  const out: Node[] = [header];

  if (c.body) {
    out.push(el("pre", { class: "ck-body" }, c.body));
  }

  if (c.files.length) {
    const files = el("div", { class: "ck-files" });
    files.append(el("div", { class: "ck-files-title" }, `${c.files.length} file${c.files.length === 1 ? "" : "s"} changed`));
    for (const f of c.files) {
      files.append(el("div", { class: "ck-file" },
        el("span", { class: `ck-status ck-status-${(f.status[0] || "").toLowerCase()}` }, f.status),
        el("span", { class: "ck-path" }, f.path),
      ));
    }
    out.push(files);
  }

  out.push(renderDiff(c.diff));
  checkinEl.replaceChildren(...out);
}

function renderDiff(diff: string): HTMLElement {
  const pre = el("pre", { class: "ck-diff" });
  if (!diff.trim()) {
    pre.append(el("span", { class: "empty" }, "(no diff)"));
    return pre;
  }
  for (const line of diff.split("\n")) {
    const cls = line.startsWith("+++") || line.startsWith("---") ? "d-file"
      : line.startsWith("@@") ? "d-hunk"
      : line.startsWith("diff ") || line.startsWith("index ") ? "d-meta"
      : line.startsWith("+") ? "d-add"
      : line.startsWith("-") ? "d-del"
      : "d-ctx";
    pre.append(el("span", { class: `d-line ${cls}` }, line + "\n"));
  }
  return pre;
}
