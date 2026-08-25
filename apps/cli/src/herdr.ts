import { fail, terminalText, C } from "./lib.ts";
import { startTailscaleServe, type ManagedTailscaleServe } from "./herdr-tailscale.ts";
import { readdir, readFile, realpath, stat } from "node:fs/promises";
import { basename, extname, isAbsolute, relative, resolve, sep } from "node:path";

type JSONObject = Record<string, unknown>;
type HerdrRunner = (args: string[], timeoutMs?: number) => Promise<unknown>;

type ArtifactKind = "image" | "pdf" | "text" | "html" | "file";

type AgentArtifact = {
  target: string;
  path: string;
  filename: string;
  mimeType: string;
  kind: ArtifactKind;
  bytes: number;
  modifiedAt: string;
  fetchable: boolean;
};

type MCPRequest = {
  jsonrpc?: unknown;
  id?: unknown;
  method?: unknown;
  params?: unknown;
};

type ToolDefinition = {
  name: string;
  title: string;
  description: string;
  inputSchema: JSONObject;
  annotations?: JSONObject;
  run: (input: JSONObject, runner: HerdrRunner) => Promise<unknown>;
};

const sources = ["visible", "recent", "recent-unwrapped", "detection"] as const;
const paneSources = ["visible", "recent", "recent-unwrapped"] as const;
const states = ["idle", "working", "blocked", "done", "unknown"] as const;
const agentKinds = [
  "pi", "claude", "codex", "gemini", "cursor", "devin", "agy", "cline", "omp", "mastracode", "opencode",
  "copilot", "kimi", "kiro", "droid", "amp", "grok", "hermes", "kilo", "qodercli", "maki",
] as const;
const notificationPositions = ["top-left", "top-right", "bottom-left", "bottom-right"] as const;
const notificationSounds = ["none", "done", "request"] as const;
const maximumArtifactBytes = 2_500_000;
const maximumArtifactEntries = 10_000;
const maximumArtifactDepth = 8;
const ignoredArtifactDirectories = new Set([
  ".git", ".svn", ".hg", "node_modules", "DerivedData", ".build", "Pods", "vendor",
]);
const artifactTypes = new Map<string, { mimeType: string; kind: ArtifactKind }>([
  [".png", { mimeType: "image/png", kind: "image" }],
  [".jpg", { mimeType: "image/jpeg", kind: "image" }],
  [".jpeg", { mimeType: "image/jpeg", kind: "image" }],
  [".gif", { mimeType: "image/gif", kind: "image" }],
  [".webp", { mimeType: "image/webp", kind: "image" }],
  [".heic", { mimeType: "image/heic", kind: "image" }],
  [".heif", { mimeType: "image/heif", kind: "image" }],
  [".tif", { mimeType: "image/tiff", kind: "image" }],
  [".tiff", { mimeType: "image/tiff", kind: "image" }],
  [".pdf", { mimeType: "application/pdf", kind: "pdf" }],
  [".html", { mimeType: "text/html", kind: "html" }],
  [".htm", { mimeType: "text/html", kind: "html" }],
  [".md", { mimeType: "text/markdown", kind: "text" }],
  [".markdown", { mimeType: "text/markdown", kind: "text" }],
  [".txt", { mimeType: "text/plain", kind: "text" }],
  [".csv", { mimeType: "text/csv", kind: "text" }],
  [".tsv", { mimeType: "text/tab-separated-values", kind: "text" }],
  [".json", { mimeType: "application/json", kind: "text" }],
  [".mov", { mimeType: "video/quicktime", kind: "file" }],
  [".mp4", { mimeType: "video/mp4", kind: "file" }],
  [".m4v", { mimeType: "video/x-m4v", kind: "file" }],
  [".zip", { mimeType: "application/zip", kind: "file" }],
  [".docx", { mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", kind: "file" }],
  [".xlsx", { mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", kind: "file" }],
  [".pptx", { mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation", kind: "file" }],
]);
const destructiveAnnotations = {
  readOnlyHint: false,
  destructiveHint: true,
  idempotentHint: false,
  openWorldHint: false,
};
const readOnlyAnnotations = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
};
const outputSchema = {
  type: "object",
  properties: { result: {} },
  required: ["result"],
  additionalProperties: false,
};

function object(value: unknown): JSONObject {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("arguments must be an object");
  return value as JSONObject;
}

function string(input: JSONObject, name: string, maximum = 100_000): string {
  const value = input[name];
  if (typeof value !== "string" || value.length === 0) throw new Error(`${name} must be a non-empty string`);
  if (value.length > maximum) throw new Error(`${name} must be at most ${maximum} characters`);
  return value;
}

function optionalString(input: JSONObject, name: string, maximum = 500): string | undefined {
  const value = input[name];
  if (value === undefined) return undefined;
  if (typeof value !== "string" || value.length === 0) throw new Error(`${name} must be a non-empty string`);
  if (value.length > maximum) throw new Error(`${name} must be at most ${maximum} characters`);
  return value;
}

function integer(input: JSONObject, name: string, fallback: number, minimum: number, maximum: number): number {
  const value = input[name] ?? fallback;
  if (!Number.isInteger(value) || (value as number) < minimum || (value as number) > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} through ${maximum}`);
  }
  return value as number;
}

function boolean(input: JSONObject, name: string, fallback: boolean): boolean {
  const value = input[name] ?? fallback;
  if (typeof value !== "boolean") throw new Error(`${name} must be a boolean`);
  return value;
}

function requireConfirmation(input: JSONObject): void {
  if (input.confirm !== true) throw new Error("confirm must be true");
}

function enumeration<T extends string>(input: JSONObject, name: string, values: readonly T[], fallback: T): T {
  const value = input[name] ?? fallback;
  if (typeof value !== "string" || !values.includes(value as T)) throw new Error(`${name} must be one of ${values.join(", ")}`);
  return value as T;
}

function requiredEnumeration<T extends string>(input: JSONObject, name: string, values: readonly T[]): T {
  const value = input[name];
  if (typeof value !== "string" || !values.includes(value as T)) throw new Error(`${name} must be one of ${values.join(", ")}`);
  return value as T;
}

function optionalEnumeration<T extends string>(input: JSONObject, name: string, values: readonly T[]): T | undefined {
  const value = input[name];
  if (value === undefined) return undefined;
  if (typeof value !== "string" || !values.includes(value as T)) throw new Error(`${name} must be one of ${values.join(", ")}`);
  return value as T;
}

function enumerations<T extends string>(input: JSONObject, name: string, values: readonly T[]): T[] {
  const value = input[name];
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== "string" || !values.includes(entry as T))) {
    throw new Error(`${name} must contain only ${values.join(", ")}`);
  }
  return value as T[];
}

function readArgs(input: JSONObject, targetName: string): string[] {
  const target = string(input, targetName, 500);
  const source = enumeration(input, "source", sources, "recent");
  const lines = integer(input, "lines", 100, 1, 500);
  return [target, "--source", source, "--lines", String(lines), "--format", "text"];
}

function worktreeContextArgs(input: JSONObject): string[] {
  const workspace = optionalString(input, "workspace");
  const cwd = optionalString(input, "cwd", 4096);
  if (!workspace && !cwd) throw new Error("provide exactly one of workspace or cwd");
  if (workspace && cwd) throw new Error("provide exactly one of workspace or cwd");
  return workspace ? ["--workspace", workspace] : ["--cwd", cwd as string];
}

function nestedObject(value: unknown, name: string): JSONObject {
  try {
    return object(value);
  } catch {
    throw new Error(`Herdr returned no ${name}`);
  }
}

async function agentWorkspace(target: string, runner: HerdrRunner): Promise<string> {
  const response = nestedObject(await runner(["agent", "get", target]), "agent response");
  const result = nestedObject(response.result, "agent result");
  const agent = nestedObject(result.agent, "agent details");
  const cwd = typeof agent.foreground_cwd === "string" ? agent.foreground_cwd : agent.cwd;
  if (typeof cwd !== "string" || !isAbsolute(cwd)) throw new Error("Herdr agent has no absolute working directory");
  return await realpath(cwd);
}

function artifactType(path: string): { mimeType: string; kind: ArtifactKind } {
  const type = artifactTypes.get(extname(path).toLowerCase());
  if (!type) throw new Error(`unsupported artifact type: ${extname(path) || "no extension"}`);
  return type;
}

function artifactRelativePath(root: string, path: string, boundary = "agent working directory"): string {
  const value = relative(root, path);
  if (!value || value === ".." || value.startsWith(`..${sep}`) || isAbsolute(value)) {
    throw new Error(`artifact must be a file inside the ${boundary}`);
  }
  return value.split(sep).join("/");
}

async function resolveAgentPath(root: string, requested: string, allowRoot = false): Promise<{ absolute: string; relative: string }> {
  if (isAbsolute(requested)) throw new Error("path must be relative to the agent working directory");
  const absolute = await realpath(resolve(root, requested));
  if (allowRoot && absolute === root) return { absolute, relative: "." };
  return { absolute, relative: artifactRelativePath(root, absolute) };
}

async function agentArtifactDirectory(root: string): Promise<string> {
  try {
    return await realpath(resolve(root, "artifacts"));
  } catch {
    throw new Error("agent has no artifacts directory; ask it to save the file under artifacts/");
  }
}

async function artifactMetadata(target: string, root: string, absolute: string): Promise<AgentArtifact> {
  const relativePath = artifactRelativePath(root, absolute);
  const details = await stat(absolute);
  if (!details.isFile()) throw new Error("artifact must be a regular file");
  const type = artifactType(absolute);
  return {
    target,
    path: relativePath,
    filename: basename(absolute),
    mimeType: type.mimeType,
    kind: type.kind,
    bytes: details.size,
    modifiedAt: details.mtime.toISOString(),
    fetchable: details.size <= maximumArtifactBytes,
  };
}

async function listAgentArtifacts(
  target: string,
  root: string,
  artifactDirectory: string,
  directory: string,
  limit: number,
): Promise<AgentArtifact[]> {
  const resolved = await resolveAgentPath(root, directory, true);
  if (resolved.absolute !== artifactDirectory) artifactRelativePath(artifactDirectory, resolved.absolute, "agent artifacts directory");
  if (!(await stat(resolved.absolute)).isDirectory()) throw new Error("directory must refer to a directory");
  const artifacts: AgentArtifact[] = [];
  let visited = 0;
  const visit = async (path: string, depth: number): Promise<void> => {
    if (depth > maximumArtifactDepth || visited >= maximumArtifactEntries) return;
    const entries = await readdir(path, { withFileTypes: true });
    for (const entry of entries) {
      if (visited++ >= maximumArtifactEntries) return;
      const child = resolve(path, entry.name);
      if (entry.isDirectory()) {
        if (!entry.name.startsWith(".") && !ignoredArtifactDirectories.has(entry.name)) await visit(child, depth + 1);
      } else if (entry.isFile() && artifactTypes.has(extname(entry.name).toLowerCase())) {
        artifacts.push(await artifactMetadata(target, root, child));
      }
    }
  };
  await visit(resolved.absolute, 0);
  return artifacts
    .sort((left, right) => right.modifiedAt.localeCompare(left.modifiedAt))
    .slice(0, limit);
}

class ArtifactToolResult {
  constructor(readonly result: AgentArtifact, readonly content: JSONObject) {}
}

function artifactURI(artifact: AgentArtifact): string {
  const path = artifact.path.split("/").map(encodeURIComponent).join("/");
  return `herdr-artifact://agent/${encodeURIComponent(artifact.target)}/${path}`;
}

async function fetchAgentArtifact(
  target: string,
  root: string,
  artifactDirectory: string,
  requested: string,
): Promise<ArtifactToolResult> {
  const resolved = await resolveAgentPath(root, requested);
  artifactRelativePath(artifactDirectory, resolved.absolute, "agent artifacts directory");
  const artifact = await artifactMetadata(target, root, resolved.absolute);
  if (!artifact.fetchable) throw new Error(`artifact exceeds the ${maximumArtifactBytes}-byte MCP transfer limit`);
  const data = await readFile(resolved.absolute);
  if (data.byteLength > maximumArtifactBytes) throw new Error(`artifact exceeds the ${maximumArtifactBytes}-byte MCP transfer limit`);
  if (artifact.kind === "image") {
    return new ArtifactToolResult(artifact, { type: "image", data: data.toString("base64"), mimeType: artifact.mimeType });
  }
  const resource: JSONObject = { uri: artifactURI(artifact), mimeType: artifact.mimeType };
  if (artifact.kind === "text" || artifact.kind === "html") resource.text = data.toString("utf8");
  else resource.blob = data.toString("base64");
  return new ArtifactToolResult(artifact, { type: "resource", resource });
}

export const HERDR_TOOLS: ToolDefinition[] = [
  {
    name: "status",
    title: "Herdr status",
    description: "Inspect the installed Herdr client and the selected Herdr server session.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    run: async (_, runner) => runner(["status", "--json"]),
  },
  {
    name: "agent_list",
    title: "List Herdr agents",
    description: "List agents detected in the selected Herdr session and their current states.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    run: async (_, runner) => runner(["agent", "list"]),
  },
  {
    name: "agent_get",
    title: "Inspect Herdr agent",
    description: "Get structured details for one Herdr agent.",
    inputSchema: {
      type: "object",
      properties: { target: { type: "string", minLength: 1, maxLength: 500 } },
      required: ["target"],
      additionalProperties: false,
    },
    run: async (input, runner) => runner(["agent", "get", string(input, "target", 500)]),
  },
  {
    name: "agent_artifact_list",
    title: "List Herdr agent artifacts",
    description: "List recently modified displayable files in an agent's artifacts/ directory. Ask the agent to save outputs there and report workspace-relative paths.",
    inputSchema: {
      type: "object",
      properties: {
        target: { type: "string", minLength: 1, maxLength: 500 },
        directory: { type: "string", minLength: 1, maxLength: 4096 },
        limit: { type: "integer", minimum: 1, maximum: 100 },
      },
      required: ["target"],
      additionalProperties: false,
    },
    annotations: readOnlyAnnotations,
    run: async (input, runner) => {
      const target = string(input, "target", 500);
      const root = await agentWorkspace(target, runner);
      const artifacts = await agentArtifactDirectory(root);
      return await listAgentArtifacts(
        target,
        root,
        artifacts,
        optionalString(input, "directory", 4096) ?? "artifacts",
        integer(input, "limit", 20, 1, 100),
      );
    },
  },
  {
    name: "agent_artifact_get",
    title: "Get Herdr agent artifact",
    description: "Return one file from an agent's artifacts/ directory as MCP media so Ox can import and present it as an artifact. The path is relative to the agent working directory and begins with artifacts/.",
    inputSchema: {
      type: "object",
      properties: {
        target: { type: "string", minLength: 1, maxLength: 500 },
        path: { type: "string", minLength: 1, maxLength: 4096 },
      },
      required: ["target", "path"],
      additionalProperties: false,
    },
    annotations: readOnlyAnnotations,
    run: async (input, runner) => {
      const target = string(input, "target", 500);
      const root = await agentWorkspace(target, runner);
      return await fetchAgentArtifact(target, root, await agentArtifactDirectory(root), string(input, "path", 4096));
    },
  },
  {
    name: "agent_read",
    title: "Read Herdr agent",
    description: "Read bounded recent terminal output from a Herdr agent.",
    inputSchema: {
      type: "object",
      properties: {
        target: { type: "string", minLength: 1, maxLength: 500 },
        source: { type: "string", enum: sources },
        lines: { type: "integer", minimum: 1, maximum: 500 },
      },
      required: ["target"],
      additionalProperties: false,
    },
    run: async (input, runner) => runner(["agent", "read", ...readArgs(input, "target")]),
  },
  {
    name: "agent_explain",
    title: "Explain Herdr agent detection",
    description: "Explain how Herdr detected a target agent and diagnose its state.",
    inputSchema: {
      type: "object",
      properties: { target: { type: "string", minLength: 1, maxLength: 500 } },
      required: ["target"],
      additionalProperties: false,
    },
    run: async (input, runner) => runner(["agent", "explain", string(input, "target", 500), "--json"]),
  },
  {
    name: "agent_start",
    title: "Start Herdr agent",
    description: "Start a supported interactive agent in an existing idle shell pane without arbitrary agent arguments.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", minLength: 1, maxLength: 500 },
        kind: { type: "string", enum: agentKinds },
        pane_id: { type: "string", minLength: 1, maxLength: 500 },
        timeout_ms: { type: "integer", minimum: 1_000, maximum: 300_000 },
      },
      required: ["name", "kind", "pane_id"],
      additionalProperties: false,
    },
    run: async (input, runner) => {
      const timeout = integer(input, "timeout_ms", 30_000, 1_000, 300_000);
      const args = [
        "agent", "start", string(input, "name", 500),
        "--kind", requiredEnumeration(input, "kind", agentKinds),
        "--pane", string(input, "pane_id", 500),
        "--timeout", String(timeout),
      ];
      return runner(args, timeout + 5_000);
    },
  },
  {
    name: "agent_rename",
    title: "Rename Herdr agent",
    description: "Set or clear the display name of one Herdr agent.",
    inputSchema: {
      type: "object",
      properties: {
        target: { type: "string", minLength: 1, maxLength: 500 },
        name: { type: "string", minLength: 1, maxLength: 500 },
        clear: { type: "boolean" },
      },
      required: ["target"],
      additionalProperties: false,
    },
    run: async (input, runner) => {
      const name = optionalString(input, "name");
      const clear = boolean(input, "clear", false);
      if (!name && !clear) throw new Error("provide exactly one of name or clear=true");
      if (name && clear) throw new Error("provide exactly one of name or clear=true");
      return runner(["agent", "rename", string(input, "target", 500), ...(name ? [name] : ["--clear"])]);
    },
  },
  {
    name: "agent_focus",
    title: "Focus Herdr agent",
    description: "Focus one Herdr agent on the Mac for operator handoff.",
    inputSchema: {
      type: "object",
      properties: { target: { type: "string", minLength: 1, maxLength: 500 } },
      required: ["target"],
      additionalProperties: false,
    },
    run: async (input, runner) => runner(["agent", "focus", string(input, "target", 500)]),
  },
  {
    name: "agent_prompt",
    title: "Prompt Herdr agent",
    description: "Send text to a Herdr agent, optionally waiting for a resulting state.",
    inputSchema: {
      type: "object",
      properties: {
        target: { type: "string", minLength: 1, maxLength: 500 },
        text: { type: "string", minLength: 1, maxLength: 100_000 },
        wait: { type: "boolean" },
        until: { type: "array", items: { type: "string", enum: states }, uniqueItems: true },
        timeout_ms: { type: "integer", minimum: 1_000, maximum: 300_000 },
      },
      required: ["target", "text"],
      additionalProperties: false,
    },
    run: async (input, runner) => {
      const wait = boolean(input, "wait", false);
      const until = enumerations(input, "until", states);
      const timeout = integer(input, "timeout_ms", 30_000, 1_000, 300_000);
      if (!wait && (until.length > 0 || input.timeout_ms !== undefined)) throw new Error("until and timeout_ms require wait=true");
      const args = ["agent", "prompt", string(input, "target", 500), string(input, "text")];
      if (wait) {
        args.push("--wait", "--timeout", String(timeout));
        for (const state of until) args.push("--until", state);
      }
      return runner(args, wait ? timeout + 5_000 : undefined);
    },
  },
  {
    name: "agent_wait",
    title: "Wait for Herdr agent",
    description: "Wait for a Herdr agent to reach a settled or requested state.",
    inputSchema: {
      type: "object",
      properties: {
        target: { type: "string", minLength: 1, maxLength: 500 },
        until: { type: "array", items: { type: "string", enum: states }, uniqueItems: true },
        timeout_ms: { type: "integer", minimum: 1_000, maximum: 300_000 },
      },
      required: ["target"],
      additionalProperties: false,
    },
    run: async (input, runner) => {
      const timeout = integer(input, "timeout_ms", 30_000, 1_000, 300_000);
      const args = ["agent", "wait", string(input, "target", 500), "--timeout", String(timeout)];
      for (const state of enumerations(input, "until", states)) args.push("--until", state);
      return runner(args, timeout + 5_000);
    },
  },
  {
    name: "workspace_list",
    title: "List Herdr workspaces",
    description: "List workspaces in the selected Herdr session.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    run: async (_, runner) => runner(["workspace", "list"]),
  },
  {
    name: "workspace_get",
    title: "Inspect Herdr workspace",
    description: "Get structured details for one Herdr workspace.",
    inputSchema: {
      type: "object",
      properties: { workspace_id: { type: "string", minLength: 1, maxLength: 500 } },
      required: ["workspace_id"],
      additionalProperties: false,
    },
    run: async (input, runner) => runner(["workspace", "get", string(input, "workspace_id", 500)]),
  },
  {
    name: "workspace_create",
    title: "Create Herdr workspace",
    description: "Create a non-focusing Herdr workspace at an explicit working directory.",
    inputSchema: {
      type: "object",
      properties: {
        cwd: { type: "string", minLength: 1, maxLength: 4096 },
        label: { type: "string", minLength: 1, maxLength: 500 },
      },
      required: ["cwd"],
      additionalProperties: false,
    },
    run: async (input, runner) => {
      const args = ["workspace", "create", "--cwd", string(input, "cwd", 4096)];
      const label = optionalString(input, "label");
      if (label) args.push("--label", label);
      args.push("--no-focus");
      return runner(args);
    },
  },
  {
    name: "workspace_rename",
    title: "Rename Herdr workspace",
    description: "Rename one Herdr workspace.",
    inputSchema: {
      type: "object",
      properties: {
        workspace_id: { type: "string", minLength: 1, maxLength: 500 },
        label: { type: "string", minLength: 1, maxLength: 500 },
      },
      required: ["workspace_id", "label"],
      additionalProperties: false,
    },
    run: async (input, runner) => runner([
      "workspace", "rename", string(input, "workspace_id", 500), string(input, "label", 500),
    ]),
  },
  {
    name: "workspace_focus",
    title: "Focus Herdr workspace",
    description: "Focus one Herdr workspace on the Mac for operator handoff.",
    inputSchema: {
      type: "object",
      properties: { workspace_id: { type: "string", minLength: 1, maxLength: 500 } },
      required: ["workspace_id"],
      additionalProperties: false,
    },
    run: async (input, runner) => runner(["workspace", "focus", string(input, "workspace_id", 500)]),
  },
  {
    name: "workspace_close",
    title: "Close Herdr workspace",
    description: "Close one Herdr workspace after explicit confirmation.",
    inputSchema: {
      type: "object",
      properties: {
        workspace_id: { type: "string", minLength: 1, maxLength: 500 },
        confirm: { type: "boolean", const: true },
      },
      required: ["workspace_id", "confirm"],
      additionalProperties: false,
    },
    annotations: destructiveAnnotations,
    run: async (input, runner) => {
      requireConfirmation(input);
      return runner(["workspace", "close", string(input, "workspace_id", 500)]);
    },
  },
  {
    name: "tab_list",
    title: "List Herdr tabs",
    description: "List tabs, optionally within one Herdr workspace.",
    inputSchema: {
      type: "object",
      properties: { workspace: { type: "string", minLength: 1, maxLength: 500 } },
      additionalProperties: false,
    },
    run: async (input, runner) => {
      const workspace = optionalString(input, "workspace");
      return runner(workspace ? ["tab", "list", "--workspace", workspace] : ["tab", "list"]);
    },
  },
  {
    name: "tab_get",
    title: "Inspect Herdr tab",
    description: "Get structured details for one Herdr tab.",
    inputSchema: {
      type: "object",
      properties: { tab_id: { type: "string", minLength: 1, maxLength: 500 } },
      required: ["tab_id"],
      additionalProperties: false,
    },
    run: async (input, runner) => runner(["tab", "get", string(input, "tab_id", 500)]),
  },
  {
    name: "tab_create",
    title: "Create Herdr tab",
    description: "Create a non-focusing shell tab in one Herdr workspace.",
    inputSchema: {
      type: "object",
      properties: {
        workspace: { type: "string", minLength: 1, maxLength: 500 },
        cwd: { type: "string", minLength: 1, maxLength: 4096 },
        label: { type: "string", minLength: 1, maxLength: 500 },
      },
      required: ["workspace"],
      additionalProperties: false,
    },
    run: async (input, runner) => {
      const args = ["tab", "create", "--workspace", string(input, "workspace", 500)];
      const cwd = optionalString(input, "cwd", 4096);
      const label = optionalString(input, "label");
      if (cwd) args.push("--cwd", cwd);
      if (label) args.push("--label", label);
      args.push("--no-focus");
      return runner(args);
    },
  },
  {
    name: "tab_rename",
    title: "Rename Herdr tab",
    description: "Rename one Herdr tab.",
    inputSchema: {
      type: "object",
      properties: {
        tab_id: { type: "string", minLength: 1, maxLength: 500 },
        label: { type: "string", minLength: 1, maxLength: 500 },
      },
      required: ["tab_id", "label"],
      additionalProperties: false,
    },
    run: async (input, runner) => runner(["tab", "rename", string(input, "tab_id", 500), string(input, "label", 500)]),
  },
  {
    name: "tab_focus",
    title: "Focus Herdr tab",
    description: "Focus one Herdr tab on the Mac for operator handoff.",
    inputSchema: {
      type: "object",
      properties: { tab_id: { type: "string", minLength: 1, maxLength: 500 } },
      required: ["tab_id"],
      additionalProperties: false,
    },
    run: async (input, runner) => runner(["tab", "focus", string(input, "tab_id", 500)]),
  },
  {
    name: "tab_close",
    title: "Close Herdr tab",
    description: "Close one Herdr tab after explicit confirmation.",
    inputSchema: {
      type: "object",
      properties: {
        tab_id: { type: "string", minLength: 1, maxLength: 500 },
        confirm: { type: "boolean", const: true },
      },
      required: ["tab_id", "confirm"],
      additionalProperties: false,
    },
    annotations: destructiveAnnotations,
    run: async (input, runner) => {
      requireConfirmation(input);
      return runner(["tab", "close", string(input, "tab_id", 500)]);
    },
  },
  {
    name: "worktree_list",
    title: "List Herdr worktrees",
    description: "List Git worktree-backed Herdr workspaces, optionally filtered by workspace or working directory.",
    inputSchema: {
      type: "object",
      properties: {
        workspace: { type: "string", minLength: 1, maxLength: 500 },
        cwd: { type: "string", minLength: 1, maxLength: 4096 },
      },
      additionalProperties: false,
    },
    run: async (input, runner) => {
      const args = ["worktree", "list"];
      const workspace = optionalString(input, "workspace");
      const cwd = optionalString(input, "cwd", 4096);
      if (workspace) args.push("--workspace", workspace);
      if (cwd) args.push("--cwd", cwd);
      return runner(args);
    },
  },
  {
    name: "worktree_create",
    title: "Create Herdr worktree",
    description: "Create a Git worktree and open it as a non-focusing Herdr workspace.",
    inputSchema: {
      type: "object",
      properties: {
        workspace: { type: "string", minLength: 1, maxLength: 500 },
        cwd: { type: "string", minLength: 1, maxLength: 4096 },
        branch: { type: "string", minLength: 1, maxLength: 500 },
        base: { type: "string", minLength: 1, maxLength: 500 },
        path: { type: "string", minLength: 1, maxLength: 4096 },
        label: { type: "string", minLength: 1, maxLength: 500 },
      },
      required: ["branch"],
      additionalProperties: false,
    },
    run: async (input, runner) => {
      const args = ["worktree", "create", ...worktreeContextArgs(input), "--branch", string(input, "branch", 500)];
      const base = optionalString(input, "base");
      const path = optionalString(input, "path", 4096);
      const label = optionalString(input, "label");
      if (base) args.push("--base", base);
      if (path) args.push("--path", path);
      if (label) args.push("--label", label);
      args.push("--no-focus");
      return runner(args);
    },
  },
  {
    name: "worktree_open",
    title: "Open Herdr worktree",
    description: "Open an existing Git worktree as a non-focusing Herdr workspace.",
    inputSchema: {
      type: "object",
      properties: {
        workspace: { type: "string", minLength: 1, maxLength: 500 },
        cwd: { type: "string", minLength: 1, maxLength: 4096 },
        path: { type: "string", minLength: 1, maxLength: 4096 },
        branch: { type: "string", minLength: 1, maxLength: 500 },
        label: { type: "string", minLength: 1, maxLength: 500 },
      },
      additionalProperties: false,
    },
    run: async (input, runner) => {
      const path = optionalString(input, "path", 4096);
      const branch = optionalString(input, "branch");
      if (!path && !branch) throw new Error("provide exactly one of path or branch");
      if (path && branch) throw new Error("provide exactly one of path or branch");
      const args = ["worktree", "open", ...worktreeContextArgs(input)];
      if (path) args.push("--path", path);
      if (branch) args.push("--branch", branch);
      const label = optionalString(input, "label");
      if (label) args.push("--label", label);
      args.push("--no-focus");
      return runner(args);
    },
  },
  {
    name: "worktree_remove",
    title: "Remove Herdr worktree",
    description: "Remove one Herdr worktree without force after explicit confirmation.",
    inputSchema: {
      type: "object",
      properties: {
        workspace: { type: "string", minLength: 1, maxLength: 500 },
        confirm: { type: "boolean", const: true },
      },
      required: ["workspace", "confirm"],
      additionalProperties: false,
    },
    annotations: destructiveAnnotations,
    run: async (input, runner) => {
      requireConfirmation(input);
      return runner(["worktree", "remove", "--workspace", string(input, "workspace", 500)]);
    },
  },
  {
    name: "pane_list",
    title: "List Herdr panes",
    description: "List panes, optionally within one Herdr workspace.",
    inputSchema: {
      type: "object",
      properties: { workspace: { type: "string", minLength: 1, maxLength: 500 } },
      additionalProperties: false,
    },
    run: async (input, runner) => {
      const workspace = optionalString(input, "workspace");
      return runner(workspace ? ["pane", "list", "--workspace", workspace] : ["pane", "list"]);
    },
  },
  {
    name: "pane_get",
    title: "Inspect Herdr pane",
    description: "Get structured details for one Herdr pane.",
    inputSchema: {
      type: "object",
      properties: { pane_id: { type: "string", minLength: 1, maxLength: 500 } },
      required: ["pane_id"],
      additionalProperties: false,
    },
    run: async (input, runner) => runner(["pane", "get", string(input, "pane_id", 500)]),
  },
  {
    name: "pane_process_info",
    title: "Inspect Herdr pane process",
    description: "Inspect the foreground processes and working directory for one Herdr pane.",
    inputSchema: {
      type: "object",
      properties: { pane_id: { type: "string", minLength: 1, maxLength: 500 } },
      required: ["pane_id"],
      additionalProperties: false,
    },
    run: async (input, runner) => runner(["pane", "process-info", "--pane", string(input, "pane_id", 500)]),
  },
  {
    name: "pane_read",
    title: "Read Herdr pane",
    description: "Read bounded recent terminal output from a Herdr pane.",
    inputSchema: {
      type: "object",
      properties: {
        pane_id: { type: "string", minLength: 1, maxLength: 500 },
        source: { type: "string", enum: sources },
        lines: { type: "integer", minimum: 1, maximum: 500 },
      },
      required: ["pane_id"],
      additionalProperties: false,
    },
    run: async (input, runner) => runner(["pane", "read", ...readArgs(input, "pane_id")]),
  },
  {
    name: "pane_wait_output",
    title: "Wait for Herdr pane output",
    description: "Wait for a bounded literal substring to appear in one Herdr pane.",
    inputSchema: {
      type: "object",
      properties: {
        pane_id: { type: "string", minLength: 1, maxLength: 500 },
        match: { type: "string", minLength: 1, maxLength: 500 },
        source: { type: "string", enum: paneSources },
        lines: { type: "integer", minimum: 1, maximum: 500 },
        timeout_ms: { type: "integer", minimum: 1_000, maximum: 300_000 },
      },
      required: ["pane_id", "match"],
      additionalProperties: false,
    },
    run: async (input, runner) => {
      const timeout = integer(input, "timeout_ms", 30_000, 1_000, 300_000);
      const args = [
        "pane", "wait-output", string(input, "pane_id", 500),
        "--match", string(input, "match", 500),
        "--source", enumeration(input, "source", paneSources, "recent"),
        "--lines", String(integer(input, "lines", 100, 1, 500)),
        "--timeout", String(timeout),
      ];
      return runner(args, timeout + 5_000);
    },
  },
  {
    name: "notification_show",
    title: "Show Herdr notification",
    description: "Show a bounded Herdr notification on the Mac.",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string", minLength: 1, maxLength: 500 },
        body: { type: "string", minLength: 1, maxLength: 4_000 },
        position: { type: "string", enum: notificationPositions },
        sound: { type: "string", enum: notificationSounds },
      },
      required: ["title"],
      additionalProperties: false,
    },
    run: async (input, runner) => {
      const args = ["notification", "show", string(input, "title", 500)];
      const body = optionalString(input, "body", 4_000);
      const position = optionalEnumeration(input, "position", notificationPositions);
      const sound = optionalEnumeration(input, "sound", notificationSounds);
      if (body) args.push("--body", body);
      if (position) args.push("--position", position);
      if (sound) args.push("--sound", sound);
      return runner(args);
    },
  },
];

function json(value: unknown, status = 200): Response {
  return Response.json(value, { status, headers: { "Cache-Control": "no-store" } });
}

function rpcResult(id: unknown, result: unknown): Response {
  return json({ jsonrpc: "2.0", id, result });
}

function rpcError(id: unknown, code: number, message: string): Response {
  return json({ jsonrpc: "2.0", id: id ?? null, error: { code, message } });
}

function toolResult(result: unknown): JSONObject {
  const value = result instanceof ArtifactToolResult ? result.result : result;
  const structuredContent = { result: value };
  return {
    content: [
      { type: "text", text: JSON.stringify(value) },
      ...(result instanceof ArtifactToolResult ? [result.content] : []),
    ],
    structuredContent,
  };
}

function toolError(error: unknown): JSONObject {
  const message = error instanceof Error ? error.message : String(error);
  return { content: [{ type: "text", text: message }], isError: true };
}

function validateToolArguments(tool: ToolDefinition, input: JSONObject): void {
  const properties = object(tool.inputSchema.properties ?? {});
  const unknown = Object.keys(input).find((name) => properties[name] === undefined);
  if (unknown) throw new Error(`unknown argument: ${unknown}`);
}

export function createHerdrMCPHandler(runner: HerdrRunner): (request: Request) => Promise<Response> {
  return async (request) => {
    const url = new URL(request.url);
    if (url.pathname === "/health") return json({ ok: true, service: "ox-herdr" });
    if (url.pathname !== "/mcp") return json({ error: "not found" }, 404);
    if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
    const contentLength = Number(request.headers.get("content-length") ?? "0");
    if (contentLength > 1_048_576) return json({ error: "request body too large" }, 413);
    let message: MCPRequest;
    try {
      const raw = await request.text();
      if (new TextEncoder().encode(raw).byteLength > 1_048_576) return json({ error: "request body too large" }, 413);
      message = object(JSON.parse(raw)) as MCPRequest;
    } catch {
      return rpcError(null, -32700, "Parse error");
    }
    if (message.jsonrpc !== "2.0" || typeof message.method !== "string") return rpcError(message.id, -32600, "Invalid Request");
    if (message.method === "notifications/initialized") return new Response(null, { status: 202 });
    if (message.method === "initialize") {
      return rpcResult(message.id, {
        protocolVersion: "2025-11-25",
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "Ox Herdr", version: "1" },
        instructions: "Inspect and prompt agents running in Herdr on this Mac. Ask agents to save displayable outputs under artifacts/ in their working directory and report workspace-relative paths, then use agent_artifact_get to return them to Ox. Tool calls execute through the local Herdr CLI.",
      });
    }
    if (message.method === "tools/list") {
      return rpcResult(message.id, {
        tools: HERDR_TOOLS.map(({ run: _, ...tool }) => ({ ...tool, outputSchema })),
      });
    }
    if (message.method === "tools/call") {
      let params: JSONObject;
      try {
        params = object(message.params);
      } catch (error) {
        return rpcResult(message.id, toolError(error));
      }
      const tool = HERDR_TOOLS.find((candidate) => candidate.name === params.name);
      if (!tool) return rpcResult(message.id, toolError(new Error(`unknown tool: ${String(params.name)}`)));
      try {
        const input = object(params.arguments ?? {});
        validateToolArguments(tool, input);
        const result = await tool.run(input, runner);
        return rpcResult(message.id, toolResult(result));
      } catch (error) {
        return rpcResult(message.id, toolError(error));
      }
    }
    return rpcError(message.id, -32601, "Method not found");
  };
}

function herdrEnvironment(session: string | undefined): Record<string, string> {
  const environment = Object.fromEntries(Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined));
  if (session) environment.HERDR_SESSION = session;
  return environment;
}

async function runProcess(args: string[], session: string | undefined, timeoutMs: number): Promise<{ code: number; stdout: string; stderr: string }> {
  const binary = process.env.OX_HERDR_BIN ?? "herdr";
  const child = Bun.spawn({
    cmd: [binary, ...args],
    env: herdrEnvironment(session),
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const timer = setTimeout(() => child.kill(), timeoutMs);
  try {
    const [code, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ]);
    return { code, stdout: stdout.trim(), stderr: stderr.trim() };
  } finally {
    clearTimeout(timer);
  }
}

export function createHerdrRunner(session?: string): HerdrRunner {
  return async (args, timeoutMs = 30_000) => {
    const result = await runProcess(args, session, timeoutMs);
    let value: unknown;
    try {
      value = JSON.parse(result.stdout);
    } catch {
      value = result.stdout ? { text: result.stdout } : {};
    }
    const error = typeof value === "object" && value !== null && !Array.isArray(value) ? (value as JSONObject).error : undefined;
    if (error && typeof error === "object" && !Array.isArray(error)) {
      const body = error as JSONObject;
      throw new Error(typeof body.message === "string" ? body.message : JSON.stringify(error));
    }
    if (result.code !== 0) throw new Error(result.stderr || result.stdout || `herdr exited with status ${result.code}`);
    return value;
  };
}

async function verifyHerdr(session: string | undefined): Promise<string> {
  const result = await runProcess(["--version"], session, 5_000);
  if (result.code !== 0) throw new Error(result.stderr || result.stdout || "herdr is unavailable");
  return result.stdout;
}

type HerdrOptions = { port: number; localOnly: boolean; herdrSession?: string };

function parseOptions(args: string[]): HerdrOptions | undefined {
  let port = 8787;
  let localOnly = false;
  let herdrSession: string | undefined;
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--port") port = Number(args[++index]);
    else if (argument.startsWith("--port=")) port = Number(argument.slice("--port=".length));
    else if (argument === "--herdr-session") {
      herdrSession = args[++index];
      if (!herdrSession) fail("--herdr-session requires a name");
    }
    else if (argument.startsWith("--herdr-session=")) herdrSession = argument.slice("--herdr-session=".length);
    else if (argument === "--local-only") localOnly = true;
    else if (argument === "-h" || argument === "--help") {
      console.log("Usage: ox herdr [--port 8787] [--herdr-session <name>] [--local-only]");
      console.log("       Connect Ox to local Herdr agents through Tailscale Serve.");
      return undefined;
    } else fail(`unknown herdr option: ${argument}`);
  }
  if (!Number.isInteger(port) || port < 1 || port > 65_535) fail("--port must be an integer from 1 through 65535");
  if (herdrSession === "") fail("--herdr-session requires a name");
  return { port, localOnly, ...(herdrSession ? { herdrSession } : {}) };
}

async function waitForShutdown(server: ReturnType<typeof Bun.serve>, tailscale?: ManagedTailscaleServe): Promise<void> {
  let stopping = false;
  let resolveSignal: () => void = () => {};
  const signal = new Promise<void>((resolve) => { resolveSignal = resolve; });
  const stop = () => {
    stopping = true;
    resolveSignal();
  };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  try {
    if (!tailscale) {
      await signal;
      return;
    }
    const outcome = await Promise.race([
      signal.then(() => undefined),
      tailscale.exited,
    ]);
    await Bun.sleep(0);
    if (!stopping && outcome !== undefined) {
      const detail = await tailscale.exitMessage();
      throw new Error(detail || `Tailscale Serve exited with status ${outcome}`);
    }
  } finally {
    process.off("SIGINT", stop);
    process.off("SIGTERM", stop);
    await tailscale?.stop();
    server.stop(true);
  }
}

export async function herdr(args: string[]): Promise<void> {
  const options = parseOptions(args);
  if (!options) return;
  const version = await verifyHerdr(options.herdrSession).catch((error) => fail((error as Error).message));
  const hostname = "127.0.0.1";
  const server = Bun.serve({ hostname, port: options.port, fetch: createHerdrMCPHandler(createHerdrRunner(options.herdrSession)) });
  console.log(`${terminalText("Ox Herdr MCP", [C.bold, C.harvest])} · ${version}`);
  if (options.localOnly) {
    console.log(`MCP endpoint: ${terminalText(`http://${hostname}:${server.port}/mcp`, [C.sky])}`);
    console.log(`Health:       http://${hostname}:${server.port}/health`);
    await waitForShutdown(server);
    return;
  }
  console.log("Starting private HTTPS through Tailscale Serve…");
  const tailscale = await startTailscaleServe(options.port).catch((error) => {
    server.stop(true);
    return fail((error as Error).message);
  });
  console.log(`MCP endpoint: ${terminalText(tailscale.endpoint, [C.bold, C.sky])}`);
  console.log("Keep this command running while Ox uses Herdr. Press Ctrl+C to stop sharing.");
  await waitForShutdown(server, tailscale).catch((error) => fail((error as Error).message));
}
