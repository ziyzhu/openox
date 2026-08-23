import { resolve } from "node:path";
import { ROOT } from "./lib.ts";

export type LocCategory = "source" | "ios" | "registry" | "tests" | "package";

export interface LocSnapshot {
  date: string;
  source: number;
  ios: number;
  registry: number;
  tests: number;
  package: number;
}

const REPORT_PATH = "docs/LOC.html";
const SOURCE_EXTENSIONS = new Set([
  "swift",
  "ts",
  "tsx",
  "js",
  "jsx",
  "mjs",
  "cjs",
  "css",
  "html",
  "sh",
  "json",
  "xcstrings",
  "plist",
  "entitlements",
  "pbxproj",
  "xcworkspacedata",
  "xcscheme",
  "yml",
  "yaml",
]);
const TEST_DATA_EXTENSIONS = new Set(["har", "jsonl", "csv", "txt"]);
const PACKAGE_FILES = new Set([
  "package.json",
  "bun.lock",
  "bun.lockb",
  "package-lock.json",
  "yarn.lock",
  "pnpm-lock.yaml",
  "Package.swift",
  "Package.resolved",
  "Podfile",
  "Podfile.lock",
  "Cartfile",
  "Cartfile.resolved",
  "requirements.txt",
  "pyproject.toml",
  "poetry.lock",
  "Pipfile",
  "Pipfile.lock",
  "Gemfile",
  "Gemfile.lock",
  "Cargo.toml",
  "Cargo.lock",
  "go.mod",
  "go.sum",
]);

export function classifyLocPath(path: string): LocCategory | null {
  if (path === REPORT_PATH) return null;
  const base = path.split("/").at(-1) ?? path;
  if (PACKAGE_FILES.has(base)) return "package";
  const test = /(^|\/)(tests?|__tests__|fixtures)(\/|$)/.test(path) || /\.(test|spec)\.[^.]+$/.test(path);
  const extension = base.includes(".") ? base.split(".").at(-1) ?? "" : "";
  if (test && (SOURCE_EXTENSIONS.has(extension) || TEST_DATA_EXTENSIONS.has(extension))) return "tests";
  const registry = path.startsWith("ox-server-src/") || /^scripts\/registry-[^/]+\.ts$/.test(path);
  const category: LocCategory = path.startsWith("ios/") ? "ios" : registry ? "registry" : "source";
  if (SOURCE_EXTENSIONS.has(extension)) return category;
  return null;
}

export function parseGitGrep(output: string): Omit<LocSnapshot, "date"> {
  const totals = { source: 0, ios: 0, registry: 0, tests: 0, package: 0 };
  for (const line of output.split("\n")) {
    const firstSeparator = line.indexOf(":");
    const lastSeparator = line.lastIndexOf(":");
    if (firstSeparator < 0 || lastSeparator <= firstSeparator) continue;
    const path = line.slice(firstSeparator + 1, lastSeparator);
    const count = Number(line.slice(lastSeparator + 1));
    const category = classifyLocPath(path);
    if (category !== null && Number.isFinite(count)) totals[category] += count;
  }
  return totals;
}

export function dailyCommits(log: string, currentDate: string, head: string): Map<string, string> {
  const commits = new Map<string, string>();
  for (const line of log.split("\n")) {
    const [commit, date] = line.trim().split("\t", 2);
    if (commit && date && !commits.has(date)) commits.set(date, commit);
  }
  commits.set(currentDate, head);
  return new Map([...commits].sort(([left], [right]) => left.localeCompare(right)));
}

export function updateReportData(html: string, snapshots: LocSnapshot[]): string {
  const pattern = /(<script id="loc-data" type="application\/json">)[\s\S]*?(<\/script>)/;
  if (!pattern.test(html)) throw new Error(`Missing loc-data element in ${REPORT_PATH}`);
  return html.replace(pattern, (_match, open: string, close: string) => `${open}${JSON.stringify(snapshots)}${close}`);
}

function git(args: string[]): string {
  const result = Bun.spawnSync({
    cmd: ["git", ...args],
    cwd: ROOT,
    env: { ...process.env, TZ: "America/Los_Angeles" },
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0 && !(args[0] === "grep" && result.exitCode === 1)) {
    throw new Error(new TextDecoder().decode(result.stderr).trim() || `git ${args.join(" ")} failed`);
  }
  return new TextDecoder().decode(result.stdout);
}

function currentPacificDate(now: Date): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Los_Angeles",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(now);
  const value = (type: Intl.DateTimeFormatPartTypes) => parts.find((part) => part.type === type)?.value ?? "";
  return `${value("year")}-${value("month")}-${value("day")}`;
}

export function collectSnapshots(now = new Date()): LocSnapshot[] {
  const log = git(["log", "--first-parent", "--format=%H%x09%cd", "--date=format-local:%Y-%m-%d"]);
  const head = git(["rev-parse", "HEAD"]).trim();
  const commits = dailyCommits(log, currentPacificDate(now), head);
  const totalsByCommit = new Map<string, Omit<LocSnapshot, "date">>();
  return [...commits].map(([date, commit]) => {
    let totals = totalsByCommit.get(commit);
    if (totals === undefined) {
      totals = parseGitGrep(git(["grep", "-I", "-c", "-e", "[^[:space:]]", commit, "--"]));
      totalsByCommit.set(commit, totals);
    }
    return { date, ...totals };
  });
}

export async function updateLocReport(): Promise<boolean> {
  const output = resolve(ROOT, REPORT_PATH);
  const original = await Bun.file(output).text();
  const updated = updateReportData(original, collectSnapshots());
  if (updated === original) return false;
  await Bun.write(output, updated);
  return true;
}

if (import.meta.main) {
  const changed = await updateLocReport();
  console.log(changed ? `Updated ${REPORT_PATH}` : `${REPORT_PATH} is current`);
}
