import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
import { readSkills } from "./server-ir/skills.ts";
import { C, fail, terminalText, type CliContext } from "./lib.ts";

type ProfileConfig = {
  id: string;
  createdAt: string;
  version: string;
};

export type ProfileEntry = ProfileConfig & {
  name: string;
  root: string;
};

type ArtifactEntry = {
  name: string;
  bytes: number;
  modifiedAt: string;
  availability: "local" | "cloudOnly";
};

type ChatSummary = {
  schemaVersion: number;
  id: string;
  createdAt: number;
  lastActivity?: number | null;
  title?: string | null;
  isFavorite?: boolean;
  preview?: string | null;
  [key: string]: unknown;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SKILL_NAME = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

function parseProfileConfig(value: unknown): ProfileConfig | undefined {
  const config = value as Partial<ProfileConfig>;
  if (!UUID.test(config.id ?? "") || typeof config.createdAt !== "string" || typeof config.version !== "string") {
    return undefined;
  }
  return config as ProfileConfig;
}

function profileConfig(root: string): ProfileConfig {
  const path = join(root, "profile.json");
  let value: unknown;
  try {
    value = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      fail(`--root is not a Profile: profile.json not found at ${path}`);
    }
    fail(`could not read ${path}: ${(error as Error).message}`);
  }
  const config = parseProfileConfig(value);
  if (!config) {
    return fail(`--root is not a Profile: invalid profile.json at ${path}`);
  }
  return config;
}

export function iCloudProfileDocuments(
  platform = process.platform,
  userHome = homedir(),
  container = process.env.OX_ICLOUD_CONTAINER ?? "iCloud.ai.openox.local",
): string | undefined {
  if (platform !== "darwin") return undefined;
  return join(userHome, "Library", "Mobile Documents", container.replaceAll(".", "~"), "Documents");
}

export function listProfiles(documents: string): ProfileEntry[] {
  if (!existsSync(documents)) return [];
  const entries: ProfileEntry[] = [];
  for (const entry of readdirSync(documents, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const root = join(documents, entry.name);
    try {
      const config = parseProfileConfig(JSON.parse(readFileSync(join(root, "profile.json"), "utf8")));
      if (config) entries.push({ name: entry.name, root, ...config });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        process.stderr.write(`warning: skipped ${entry.name}: ${(error as Error).message}\n`);
      }
    }
  }
  return entries.sort((left, right) => left.name.localeCompare(right.name));
}

export function iCloudProfileReadError(documents: string, error: unknown): string {
  const code = (error as NodeJS.ErrnoException).code;
  if (code === "EPERM" || code === "EACCES") {
    return `iCloud Profile access is denied at ${documents}. Grant iCloud Drive access to the terminal or agent host in System Settings > Privacy & Security > Files & Folders, then retry`;
  }
  return `could not read iCloud Profiles at ${documents}: ${(error as Error).message}`;
}

export function profileRoot(context: CliContext): string {
  const requested = context.root ?? fail("--root <path> is required for commands that inspect a Profile");
  const root = resolve(requested);
  profileConfig(root);
  return root;
}

function ensureNoArgs(command: string, args: string[]): void {
  if (args.includes("-h") || args.includes("--help")) {
    console.log(`Usage: ox --root <path> ${command}`);
    return;
  }
  if (args.length) fail(`${command} does not accept arguments`);
}

function printTextFile(command: string, fileName: string, args: string[], context: CliContext): void {
  if (args.includes("-h") || args.includes("--help")) {
    console.log(`Usage: ox --root <path> ${command}`);
    return;
  }
  ensureNoArgs(command, args);
  const path = join(profileRoot(context), fileName);
  if (!existsSync(path)) fail(`${fileName} not found at ${path}`);
  const text = readFileSync(path, "utf8");
  process.stdout.write(text.endsWith("\n") ? text : `${text}\n`);
}

function request(args: string[]): { json: boolean; value?: string; help: boolean } {
  let json = false;
  let help = false;
  const positional: string[] = [];
  for (const argument of args) {
    if (argument === "--json") json = true;
    else if (argument === "-h" || argument === "--help") help = true;
    else if (argument.startsWith("-")) fail(`unknown option: ${argument}`);
    else positional.push(argument);
  }
  if (positional.length > 1) fail("expected at most one name or id");
  return { json, value: positional[0], help };
}

function writeJson(value: unknown): void {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

function directChild(root: string, name: string): string {
  if (!name || basename(name) !== name || name === "." || name === "..") fail(`invalid name: ${name}`);
  return join(root, name);
}

function displayDate(value: number): string {
  return new Date((value + 978307200) * 1000).toISOString();
}

function chatTitle(chat: ChatSummary): string {
  return chat.title?.trim() || chat.preview?.trim() || "New chat";
}

export function listArtifacts(root: string): ArtifactEntry[] {
  const directory = join(root, "artifacts");
  if (!existsSync(directory)) return [];
  return readdirSync(directory, { withFileTypes: true })
    .filter((entry) => entry.isFile() && !entry.name.startsWith("."))
    .map((entry) => {
      const path = join(directory, entry.name);
      const stats = statSync(path);
      return {
        name: entry.name,
        bytes: stats.size,
        modifiedAt: stats.mtime.toISOString(),
        availability: artifactAvailability(path),
      };
    })
    .sort((left, right) => left.name.localeCompare(right.name));
}

export function artifactAvailabilityFromFlags(flags: string): ArtifactEntry["availability"] {
  return /(?:^|,)(?:dataless|offline)(?:,|$)/i.test(flags.trim()) ? "cloudOnly" : "local";
}

function artifactAvailability(path: string): ArtifactEntry["availability"] {
  if (process.platform !== "darwin") return "local";
  try {
    return artifactAvailabilityFromFlags(execFileSync("/usr/bin/stat", ["-f", "%Sf", path], { encoding: "utf8" }));
  } catch {
    return "local";
  }
}

export function listChats(root: string): ChatSummary[] {
  const directory = join(root, "chats");
  if (!existsSync(directory)) return [];
  const chats: ChatSummary[] = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    try {
      const value = JSON.parse(readFileSync(join(directory, entry.name, "chat.json"), "utf8")) as Partial<ChatSummary>;
      if (typeof value.schemaVersion !== "number" || !UUID.test(value.id ?? "") || typeof value.createdAt !== "number") continue;
      chats.push(value as ChatSummary);
    } catch (error) {
      process.stderr.write(`warning: skipped ${entry.name}: ${(error as Error).message}\n`);
    }
  }
  return chats.sort((left, right) => (right.lastActivity ?? right.createdAt) - (left.lastActivity ?? left.createdAt));
}

export async function memory(args: string[], context: CliContext): Promise<void> {
  printTextFile("memory", "MEMORY.md", args, context);
}

export async function profiles(args: string[]): Promise<void> {
  const parsed = request(args);
  if (parsed.help) {
    console.log("Usage: ox profiles [--json]");
    return;
  }
  if (parsed.value) fail("profiles does not accept a name or id");
  const documents = iCloudProfileDocuments() ?? fail("listing iCloud Profiles is only supported on macOS");
  let entries: ProfileEntry[];
  try {
    entries = listProfiles(documents);
  } catch (error) {
    return fail(iCloudProfileReadError(documents, error));
  }
  if (parsed.json) {
    writeJson(entries);
    return;
  }
  for (const entry of entries) {
    console.log(`${terminalText(entry.name, [C.sky])}  ${terminalText(entry.root, [C.dim])}`);
  }
}

export async function soul(args: string[], context: CliContext): Promise<void> {
  printTextFile("soul", "SOUL.md", args, context);
}

export async function skills(args: string[], context: CliContext): Promise<void> {
  const parsed = request(args);
  if (parsed.help) {
    console.log("Usage: ox --root <path> skills [name] [--json]");
    return;
  }
  const root = profileRoot(context);
  const result = readSkills(root);
  const entries = result.ok ? result.skills : fail(result.error);
  if (parsed.value) {
    if (parsed.json) fail("--json cannot be used when printing a skill");
    if (!SKILL_NAME.test(parsed.value)) fail(`invalid skill name: ${parsed.value}`);
    if (!entries.some((skill) => skill.name === parsed.value)) fail(`skill not found: ${parsed.value}`);
    const text = readFileSync(join(root, "skills", parsed.value, "SKILL.md"), "utf8");
    process.stdout.write(text.endsWith("\n") ? text : `${text}\n`);
    return;
  }
  if (parsed.json) {
    writeJson(entries);
    return;
  }
  for (const skill of entries) {
    console.log(`${terminalText(skill.name, [C.sky])}  ${terminalText(skill.description, [C.dim])}`);
  }
}

export async function artifacts(args: string[], context: CliContext): Promise<void> {
  const parsed = request(args);
  if (parsed.help) {
    console.log("Usage: ox --root <path> artifacts [filename] [--json]");
    return;
  }
  const root = profileRoot(context);
  if (parsed.value) {
    if (parsed.json) fail("--json cannot be used when printing an artifact");
    const path = directChild(join(root, "artifacts"), parsed.value);
    if (!existsSync(path) || !statSync(path).isFile()) fail(`artifact not found: ${parsed.value}`);
    if (artifactAvailability(path) === "cloudOnly") {
      fail(`artifact is in iCloud and has not been downloaded: ${parsed.value}`);
    }
    process.stdout.write(readFileSync(path));
    return;
  }
  const entries = listArtifacts(root);
  if (parsed.json) {
    writeJson(entries);
    return;
  }
  for (const entry of entries) {
    const availability = entry.availability === "cloudOnly" ? "  In iCloud" : "";
    console.log(`${terminalText(entry.name, [C.sky])}  ${terminalText(`${entry.bytes} bytes${availability}`, [C.dim])}`);
  }
}

export async function chats(args: string[], context: CliContext): Promise<void> {
  const parsed = request(args);
  if (parsed.help) {
    console.log("Usage: ox --root <path> chats [id] [--json]");
    return;
  }
  const root = profileRoot(context);
  if (parsed.value) {
    if (!UUID.test(parsed.value)) fail(`invalid chat id: ${parsed.value}`);
    const chat = listChats(root).find((entry) => entry.id.toLowerCase() === parsed.value!.toLowerCase());
    const path = join(root, "chats", chat?.id ?? parsed.value, "turns.jsonl");
    if (!existsSync(path)) fail(`chat transcript not found: ${parsed.value}`);
    const text = readFileSync(path, "utf8");
    if (!parsed.json) {
      process.stdout.write(text.endsWith("\n") ? text : `${text}\n`);
      return;
    }
    const turns = text.split(/\r?\n/).filter(Boolean).map((line, index) => {
      try {
        return JSON.parse(line) as unknown;
      } catch (error) {
        fail(`invalid JSON in ${path} at line ${index + 1}: ${(error as Error).message}`);
      }
    });
    writeJson(turns);
    return;
  }
  const entries = listChats(root);
  if (parsed.json) {
    writeJson(entries);
    return;
  }
  for (const entry of entries) {
    const favorite = entry.isFavorite ? "★ " : "";
    console.log(`${terminalText(entry.id, [C.sky])}  ${favorite}${chatTitle(entry)}  ${terminalText(displayDate(entry.lastActivity ?? entry.createdAt), [C.dim])}`);
  }
}
