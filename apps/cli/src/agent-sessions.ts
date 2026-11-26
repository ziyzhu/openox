import { readdir, readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { ORIGIN_ENTRY } from "./agent-pi-extension.ts";

export type Origin = "ox" | "terminal";
export type SessionSummary = { id: string; path: string; cwd: string; title: string; origin: Origin; updatedAt: string };

const TITLE_LIMIT = 80;

export function expandHome(path: string): string {
  return path === "~" || path.startsWith("~/") ? join(homedir(), path.slice(1)) : path;
}

function piAgentDirectory(): string {
  const override = process.env.PI_CODING_AGENT_DIR;
  return override ? resolve(expandHome(override)) : join(homedir(), ".pi", "agent");
}

async function configuredSessionDirectory(): Promise<string | undefined> {
  const override = process.env.PI_CODING_AGENT_SESSION_DIR;
  if (override) return resolve(expandHome(override));
  const settings = await readFile(join(piAgentDirectory(), "settings.json"), "utf8").then(JSON.parse, () => undefined);
  const value = settings && typeof settings === "object" ? (settings as Record<string, unknown>).sessionDir : undefined;
  return typeof value === "string" && value ? resolve(homedir(), expandHome(value)) : undefined;
}

async function sessionDirectories(): Promise<string[]> {
  const configured = await configuredSessionDirectory();
  if (configured) return [configured];
  const parent = join(piAgentDirectory(), "sessions");
  const names = await readdir(parent).catch(() => [] as string[]);
  return names.map((name) => join(parent, name));
}

type Cached = { mtimeMs: number; size: number; summary: SessionSummary | undefined };

export class SessionIndex {
  private readonly cache = new Map<string, Cached>();

  async list(): Promise<SessionSummary[]> {
    const directories = await sessionDirectories();
    const paths = (await Promise.all(directories.map(async (directory) => {
      const names = await readdir(directory).catch(() => [] as string[]);
      return names.filter((name) => name.endsWith(".jsonl")).map((name) => join(directory, name));
    }))).flat();
    const summaries = await Promise.all(paths.map((path) => this.summary(path)));
    return summaries.filter((summary): summary is SessionSummary => summary !== undefined);
  }

  async find(id: string): Promise<SessionSummary | undefined> {
    return (await this.list()).find((summary) => summary.id === id);
  }

  private async summary(path: string): Promise<SessionSummary | undefined> {
    const info = await stat(path).catch(() => undefined);
    if (!info?.isFile()) return undefined;
    const cached = this.cache.get(path);
    if (cached && cached.mtimeMs === info.mtimeMs && cached.size === info.size) return cached.summary;
    const text = await readFile(path, "utf8").catch(() => "");
    const summary = parseSession(path, text, info.mtime.toISOString());
    this.cache.set(path, { mtimeMs: info.mtimeMs, size: info.size, summary });
    return summary;
  }
}

function parseSession(path: string, text: string, updatedAt: string): SessionSummary | undefined {
  const lines = text.split("\n");
  const header = parseLine(lines[0]);
  if (header?.type !== "session" || typeof header.id !== "string" || typeof header.cwd !== "string") return undefined;
  let name: string | undefined;
  let firstPrompt: string | undefined;
  let origin: Origin = "terminal";
  for (const line of lines.slice(1)) {
    const entry = parseLine(line);
    if (entry?.type === "session_info") name = typeof entry.name === "string" && entry.name ? entry.name : undefined;
    else if (entry?.type === "custom" && entry.customType === ORIGIN_ENTRY) origin = "ox";
    else if (!firstPrompt && entry?.type === "message") firstPrompt = userText(entry.message);
  }
  return { id: header.id, path, cwd: header.cwd, title: name ?? truncateTitle(firstPrompt ?? ""), origin, updatedAt };
}

function parseLine(line: string | undefined): Record<string, unknown> | undefined {
  if (!line?.trim()) return undefined;
  try {
    const value = JSON.parse(line.endsWith("\r") ? line.slice(0, -1) : line);
    return value && typeof value === "object" && !Array.isArray(value) ? value : undefined;
  } catch {
    return undefined;
  }
}

function userText(message: unknown): string | undefined {
  if (!message || typeof message !== "object") return undefined;
  const { role, content } = message as { role?: unknown; content?: unknown };
  if (role !== "user") return undefined;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return undefined;
  return content.flatMap((block) => block?.type === "text" && typeof block.text === "string" ? [block.text] : []).join(" ");
}

export function truncateTitle(text: string): string {
  const line = text.replace(/\s+/g, " ").trim();
  return line.length > TITLE_LIMIT ? `${line.slice(0, TITLE_LIMIT - 1)}…` : line;
}
