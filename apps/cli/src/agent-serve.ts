import { randomBytes } from "node:crypto";
import { mkdir, open, realpath, rename, stat } from "node:fs/promises";
import { homedir, hostname } from "node:os";
import { basename, join, resolve } from "node:path";
import type { ServerWebSocket } from "bun";
import { Value } from "typebox/value";
import {
  AGENT_PROTOCOL_VERSION,
  AgentMethods,
  AgentSchemas,
  type AgentContext,
  type AgentFileWriteRequest,
  type AgentMethodName,
  type AgentModel,
  type AgentModelRef,
  type AgentPromptNotification,
  type AgentPushRegistration,
  type AgentRespondRequest,
  type AgentTool,
} from "@openox/protocol/agent";
import { DEFAULT_EVENT_LIMITS, EventLog, type EventLimits } from "./agent-events.ts";
import { agentLog } from "./agent-log.ts";
import { BRIDGE_ENVIRONMENT, ORIGIN_ENTRY, ORIGIN_ENVIRONMENT, writePiExtension } from "./agent-pi-extension.ts";
import { approvalArguments, exitMessage, PiProcess, piVersion, type Approval, type PiExit, type PiRecord } from "./agent-pi.ts";
import type { PushKind } from "@openox/protocol/push";
import { PushRegistry } from "./agent-push.ts";
import { expandHome, SessionIndex, type Origin } from "./agent-sessions.ts";
import { admission, HEALTH_NAME, type Tailnet } from "./agent-tailscale.ts";
import { ToolBridge } from "./agent-tools.ts";

export type AgentSocket = ServerWebSocket<{ id: string; conversations: Set<string>; via: "loopback" | "tailnet" }>;
export type AgentServeOptions = {
  approval: Approval;
  executable: string;
  stateDirectory: string;
  port: number;
  tailnet?: Tailnet;
  idleCloseMs?: number;
  eventLimits?: EventLimits;
};

type RunState = "idle" | "running";
type ProcessState =
  | { kind: "stopped" }
  | { kind: "starting"; ready: Promise<PiProcess> }
  | { kind: "live"; pi: PiProcess; run: RunState };
type Conversation = {
  id: string;
  cwd: string;
  origin: Origin;
  context: AgentContext;
  tools: AgentTool[];
  title: string | null;
  subscribers: Set<AgentSocket>;
  process: ProcessState;
  prompts: Map<string, AgentPromptNotification>;
  activeTools: Set<string>;
  events: EventLog;
  reply: string;
  idleTimer?: ReturnType<typeof setTimeout>;
};
type PiState = {
  model?: { provider: string; id: string };
  thinkingLevel?: string;
  isStreaming?: boolean;
  sessionId?: string;
  sessionName?: string;
};
type Handler = (params: never, socket: AgentSocket) => Promise<unknown>;
type NewParams = { cwd?: string | null; model?: AgentModelRef | null; thinkingLevel?: string | null; context: AgentContext; tools: AgentTool[] };
type OpenParams = { id: string; context: AgentContext; tools: AgentTool[]; since?: number };
type SendParams = {
  id: string;
  text: string;
  images?: { data: string; mimeType: string }[];
  delivery?: "prompt" | "steer" | "followUp";
  context?: AgentContext;
};

const DIALOG_METHODS = new Set(["select", "confirm", "input", "editor"]);
const IDLE_CLOSE_MS = 10 * 60 * 1000;
const SOCKET_IDLE_SECONDS = 30;
const STARTUP_TIMEOUT_MS = 120 * 1000;
const MODELS_CACHE_MS = 60 * 1000;
const PI_FAILURE = -32000;
const UNKNOWN_CONVERSATION = -32001;
const UNKNOWN_PROMPT = -32002;

class Subscribed {
  readonly complete: (reply: (result: unknown) => void) => void;

  constructor(complete: (reply: (result: unknown) => void) => void) {
    this.complete = complete;
  }
}

class RPCError extends Error {
  readonly code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

export class AgentServer {
  readonly url: string;
  private readonly conversations = new Map<string, Conversation>();
  private readonly tokens = new Map<string, string>();
  private readonly sessions = new SessionIndex();
  private readonly push: PushRegistry;
  private readonly bridge: ToolBridge;
  private readonly bridgeURL: string;
  private readonly server: ReturnType<typeof Bun.serve>;
  private models?: { at: number; value: Promise<{ models: AgentModel[]; current: AgentModelRef | null; thinkingLevel: string | null }> };

  private readonly handlers: Record<AgentMethodName, Handler> = {
    "agent.describe": () => this.describe(),
    "models.list": () => this.listModels(),
    "conversations.list": () => this.listConversations(),
    "conversations.new": (params: NewParams, socket) => this.create(params, socket),
    "conversations.open": (params: OpenParams, socket) => this.open(params, socket),
    "conversations.close": (params: { id: string }, socket) => this.close(params.id, socket),
    "conversations.send": (params: SendParams) => this.send(params),
    "conversations.stop": (params: { id: string }) => this.abort(params.id),
    "conversations.respond": (params: AgentRespondRequest) => this.respond(params),
    "conversations.setModel": (params: { id: string; provider: string; model: string }) =>
      this.command(params.id, "set_model", { provider: params.provider, modelId: params.model }),
    "conversations.setThinking": (params: { id: string; level: string }) => this.command(params.id, "set_thinking_level", { level: params.level }),
    "conversations.compact": (params: { id: string }) => this.command(params.id, "compact"),
    "conversations.rename": (params: { id: string; title: string }) => this.rename(params.id, params.title),
    "files.write": (params: AgentFileWriteRequest) => this.writeFile(params),
    "notifications.register": (params: AgentPushRegistration) => this.push.register(params).then(() => ({})),
    "notifications.unregister": (params: { token: string }) => this.push.unregister(params.token).then(() => ({})),
  };

  private readonly options: AgentServeOptions;
  private readonly version: string;
  private readonly extensionPath: string;
  private readonly home: string;

  private constructor(options: AgentServeOptions, version: string, extensionPath: string, push: PushRegistry, home: string) {
    this.options = options;
    this.version = version;
    this.extensionPath = extensionPath;
    this.push = push;
    this.home = home;
    this.bridge = new ToolBridge((token) => {
      const conversation = this.conversations.get(this.tokens.get(token) ?? "");
      return conversation && { id: conversation.id, context: this.context(conversation), tools: conversation.tools, host: () => [...conversation.subscribers].at(-1) };
    });
    this.bridgeURL = this.bridge.start();
    this.server = Bun.serve({
      hostname: "127.0.0.1",
      port: options.port,
      fetch: (request, server) => {
        const admitted = admission(request.headers, server.port ?? options.port, options.tailnet);
        if (admitted.kind === "rejected") {
          agentLog("connection.rejected", { reason: admitted.reason, path: new URL(request.url).pathname });
          return new Response("Forbidden", { status: 403 });
        }
        if (request.method === "GET" && new URL(request.url).pathname === "/health") {
          return Response.json({ name: HEALTH_NAME, protocol: AGENT_PROTOCOL_VERSION });
        }
        const data = { id: Bun.randomUUIDv7(), conversations: new Set<string>(), via: admitted.via };
        if (server.upgrade(request, { data })) return undefined;
        return new Response("ox agent serve accepts WebSocket JSON-RPC connections", { status: 426 });
      },
      websocket: {
        data: {} as AgentSocket["data"],
        idleTimeout: SOCKET_IDLE_SECONDS,
        open: (socket) => agentLog("connection.open", { connection: socket.data.id, via: socket.data.via }),
        message: (socket, message) => this.receive(socket, typeof message === "string" ? message : new TextDecoder().decode(message)),
        close: (socket, code) => this.disconnect(socket, code),
      },
    });
    this.url = `ws://127.0.0.1:${this.server.port}`;
  }

  static async start(options: AgentServeOptions): Promise<AgentServer> {
    const push = new PushRegistry(options.stateDirectory);
    const [version, extensionPath, home] = await Promise.all([piVersion(options.executable), writePiExtension(options.stateDirectory), realpath(homedir()), push.load()]);
    const server = new AgentServer(options, version, extensionPath, push, home);
    agentLog("serve.start", { url: server.url, tailnet: options.tailnet !== undefined, pi: version, approval: options.approval });
    return server;
  }

  async stop(): Promise<void> {
    void this.server.stop(true);
    this.bridge.stop();
    const processes = [...this.conversations.values()].flatMap((conversation) => conversation.process.kind === "live" ? [conversation.process.pi] : []);
    await Promise.all(processes.map((pi) => pi.shutdown()));
    agentLog("serve.stop", { processes: processes.length });
  }

  private receive(socket: AgentSocket, raw: string): void {
    let message: unknown;
    try { message = JSON.parse(raw); }
    catch {
      this.reply(socket, null, { error: { code: -32700, message: "Parse error: message is not JSON" } });
      return;
    }
    if (!message || typeof message !== "object" || Array.isArray(message) || (message as { jsonrpc?: unknown }).jsonrpc !== "2.0") {
      this.reply(socket, null, { error: { code: -32600, message: "Invalid request: expected one JSON-RPC 2.0 object" } });
      return;
    }
    const value = message as Record<string, unknown>;
    const hasId = typeof value.id === "string" || typeof value.id === "number";
    if (typeof value.method === "string" && hasId) void this.request(socket, value.id as string | number, value.method, value.params);
    else if (typeof value.method === "string") this.notification(socket, value.method, value.params);
    else if (hasId) this.bridge.receiveResponse(socket, value);
    else this.reply(socket, null, { error: { code: -32600, message: "Invalid request: missing method" } });
  }

  private async request(socket: AgentSocket, id: string | number, method: string, params: unknown): Promise<void> {
    const started = performance.now();
    const conversation = params && typeof params === "object" && typeof (params as { id?: unknown }).id === "string" ? (params as { id: string }).id : undefined;
    try {
      const result = await this.dispatch(socket, method, params ?? {});
      if (result instanceof Subscribed) result.complete((value) => this.reply(socket, id, { result: value }));
      else this.reply(socket, id, { result });
      const created = method === "conversations.new" ? (result as { id: string }).id : undefined;
      agentLog("rpc.call", { connection: socket.data.id, method, conversation: conversation ?? created, durationMs: Math.round(performance.now() - started), ok: true });
    } catch (error) {
      const code = error instanceof RPCError ? error.code : PI_FAILURE;
      const message = (error as Error).message;
      this.reply(socket, id, { error: { code, message } });
      agentLog("rpc.call", { connection: socket.data.id, method, conversation, durationMs: Math.round(performance.now() - started), ok: false, code, error: message });
    }
  }

  private async dispatch(socket: AgentSocket, method: string, params: unknown): Promise<unknown> {
    if (!Object.hasOwn(this.handlers, method)) throw new RPCError(-32601, `Method not found: ${method}`);
    const name = method as AgentMethodName;
    const schema = AgentSchemas[AgentMethods[name].params];
    if (!Value.Check(AgentSchemas, schema, params)) {
      const [first] = Value.Errors(AgentSchemas, schema, params);
      throw new RPCError(-32602, `Invalid ${method} params${first ? `: ${first.instancePath || "/"} ${first.message}` : ""}`);
    }
    return await (this.handlers[name] as (params: unknown, socket: AgentSocket) => Promise<unknown>)(params, socket);
  }

  private notification(socket: AgentSocket, method: string, params: unknown): void {
    if (method === "tools.progress" && Value.Check(AgentSchemas, AgentSchemas.AgentToolProgressNotification, params)) {
      this.bridge.receiveProgress(socket, params as { id: string; toolCallId: string; message: string });
    } else {
      agentLog("rpc.notification_ignored", { connection: socket.data.id, method });
    }
  }

  private reply(socket: AgentSocket, id: string | number | null, body: { result: unknown } | { error: { code: number; message: string } }): void {
    this.sendText(socket, JSON.stringify({ jsonrpc: "2.0", id, ...body }));
  }

  private sendText(socket: AgentSocket, text: string): void {
    if (socket.send(text) === 0) agentLog("connection.dropped_message", { connection: socket.data.id, bytes: text.length });
  }

  private notify(conversation: Conversation, method: string, params: Record<string, unknown>): void {
    if (!conversation.subscribers.size) return;
    const text = JSON.stringify({ jsonrpc: "2.0", method, params });
    for (const socket of conversation.subscribers) this.sendText(socket, text);
  }

  private disconnect(socket: AgentSocket, code: number): void {
    agentLog("connection.close", { connection: socket.data.id, code, conversations: socket.data.conversations.size });
    this.bridge.socketClosed(socket);
    for (const id of socket.data.conversations) {
      const conversation = this.conversations.get(id);
      if (conversation) this.unsubscribe(conversation, socket);
    }
  }

  private async describe() {
    return {
      implementation: { name: "pi", version: this.version },
      machine: hostname(),
      cwd: this.home,
      protocols: { agent: [AGENT_PROTOCOL_VERSION] },
      methods: Object.keys(this.handlers),
    };
  }

  private listModels() {
    if (!this.models || Date.now() - this.models.at > MODELS_CACHE_MS) {
      const value = this.fetchModels();
      this.models = { at: Date.now(), value };
      value.catch(() => { if (this.models?.value === value) this.models = undefined; });
    }
    return this.models.value;
  }

  private async fetchModels(): Promise<{ models: AgentModel[]; current: AgentModelRef | null; thinkingLevel: string | null }> {
    const pi = new PiProcess(this.options.executable, ["--no-session", ...approvalArguments(this.options.approval)], { cwd: this.home, label: "models" }, () => {});
    try {
      const [available, state] = await withTimeout(
        Promise.all([pi.command<{ models: Record<string, unknown>[] }>("get_available_models"), pi.command<PiState>("get_state")]),
        STARTUP_TIMEOUT_MS,
        "pi did not report its models in time",
      );
      return { models: withSnapshotNames(available.models.map(toAgentModel)), current: modelRef(state.model), thinkingLevel: state.thinkingLevel ?? null };
    } finally {
      void pi.shutdown();
    }
  }

  private async listConversations() {
    const files = await this.sessions.list();
    const known = new Set(files.map((file) => file.id));
    const rows = files.map((file) => this.row(file.id, file.cwd, file.title, file.origin, file.updatedAt));
    for (const conversation of this.conversations.values()) {
      if (!known.has(conversation.id) && conversation.process.kind !== "stopped") rows.push(this.row(conversation.id, conversation.cwd, "", conversation.origin, new Date().toISOString()));
    }
    rows.sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
    return { conversations: rows };
  }

  private row(id: string, cwd: string, fileTitle: string, origin: Origin, updatedAt: string) {
    const conversation = this.conversations.get(id);
    return {
      id,
      title: conversation?.title ?? fileTitle,
      cwd,
      state: conversation && this.runState(conversation) === "running" ? "running" as const : "idle" as const,
      origin: conversation?.origin ?? origin,
      updatedAt,
    };
  }

  private async create(params: NewParams, socket: AgentSocket) {
    const id = Bun.randomUUIDv7();
    const cwd = params.cwd ? await this.folder(params.cwd) : this.home;
    const conversation = this.register(id, cwd, "ox", params.context, params.tools, null);
    this.subscribe(conversation, socket);
    try {
      const pi = await this.launch(conversation, ["--session-id", id], { [ORIGIN_ENVIRONMENT]: "ox" });
      const model = params.model;
      if (model) await pi.command("set_model", { provider: model.provider, modelId: model.id });
      if (params.thinkingLevel) await pi.command("set_thinking_level", { level: params.thinkingLevel });
      const state = await pi.command<PiState>("get_state");
      if (state.sessionId !== id) throw new Error(`pi started conversation ${state.sessionId ?? "unknown"} instead of ${id}`);
      return { id, model: modelRef(state.model), cwd };
    } catch (error) {
      if (conversation.process.kind === "live") await conversation.process.pi.shutdown();
      this.conversations.delete(id);
      throw error;
    }
  }

  private async open(params: OpenParams, socket: AgentSocket) {
    let conversation = this.conversations.get(params.id);
    if (conversation) {
      conversation.context = params.context;
      conversation.tools = params.tools;
    } else {
      const file = await this.sessions.find(params.id);
      if (!file) throw new RPCError(UNKNOWN_CONVERSATION, `Unknown conversation ${params.id}`);
      conversation = this.register(params.id, file.cwd, file.origin, params.context, params.tools, file.title || null);
    }
    const opened = conversation;
    clearTimeout(opened.idleTimer);
    const [{ messages }, state] = await this.ensure(opened)
      .then((pi) => Promise.all([pi.command<{ messages: unknown[] }>("get_messages"), pi.command<PiState>("get_state")]))
      .catch((error: Error) => {
        this.scheduleIdleClose(opened);
        throw error;
      });
    return new Subscribed((reply) => {
      const replay = opened.events.since(params.since ?? opened.events.seq);
      reply({
        messages,
        state: this.runState(opened) === "running" ? "running" : "idle",
        model: modelRef(state.model),
        thinkingLevel: state.thinkingLevel ?? null,
        title: opened.title,
        seq: replay.seq,
        replay: params.since === undefined ? undefined : replay.replay,
      });
      for (const text of replay.texts) this.sendText(socket, text);
      this.subscribe(opened, socket);
      for (const prompt of opened.prompts.values()) this.sendText(socket, JSON.stringify({ jsonrpc: "2.0", method: "conversations.prompt", params: prompt }));
      if (params.since !== undefined) agentLog("conversation.replay", { connection: socket.data.id, conversation: opened.id, events: replay.texts.length, replay: replay.replay });
    });
  }

  private async folder(requested: string): Promise<string> {
    const path = await realpath(resolve(this.home, expandHome(requested))).catch(() => undefined);
    const directory = path && await stat(path).then((info) => info.isDirectory(), () => false);
    if (!path || !directory) throw new RPCError(-32602, "folder does not exist");
    return path;
  }

  private context(conversation: Conversation): AgentContext {
    const workspace = [
      `Working folder on ${hostname()}: ${conversation.cwd}. Create files here unless the user names another place.`,
      "macOS may block protected folders such as Desktop, Documents and Downloads until the user allows access on this Mac; if a read stalls or is denied there, ask the user to allow it on this Mac.",
    ].join("\n\n");
    return { sections: { ...conversation.context.sections, ox_agent_workspace: workspace } };
  }

  private async close(id: string, socket: AgentSocket) {
    const conversation = this.conversations.get(id);
    if (conversation) this.unsubscribe(conversation, socket);
    return {};
  }

  private async send(params: SendParams) {
    const conversation = this.known(params.id);
    if (params.context) conversation.context = params.context;
    const pi = await this.ensure(conversation);
    const images = params.images?.map((image) => ({ type: "image", data: image.data, mimeType: image.mimeType }));
    const command = params.delivery === "steer" ? "steer" : params.delivery === "followUp" ? "follow_up" : "prompt";
    const data = await pi.command<{ disposition?: string } | undefined>(command, { message: params.text, images });
    return { disposition: data?.disposition ?? "queued" };
  }

  private async writeFile(params: AgentFileWriteRequest) {
    this.known(params.id);
    if (basename(params.id) !== params.id || basename(params.name) !== params.name || params.name.startsWith(".")) {
      throw new RPCError(-32602, "files.write needs a plain conversation id and file name");
    }
    const chunk = Buffer.from(params.data, "base64");
    const end = params.offset + chunk.length;
    if (end > params.size) throw new RPCError(-32602, "files.write chunk ends past size");
    const directory = join(this.options.stateDirectory, "conversations", params.id);
    const path = join(directory, params.name);
    const partial = `${path}.part`;
    await mkdir(directory, { recursive: true });
    const written = params.offset === 0 ? 0 : await stat(partial).then((info) => info.size, () => -1);
    if (written !== params.offset) throw new RPCError(-32602, "files.write chunk is out of order; restart at offset 0");
    const handle = await open(partial, params.offset === 0 ? "w" : "r+");
    try {
      await handle.write(chunk, 0, chunk.length, params.offset);
    } finally {
      await handle.close();
    }
    if (end < params.size) return {};
    await rename(partial, path);
    agentLog("files.write", { conversation: params.id, bytes: params.size });
    return { path };
  }

  private async abort(id: string) {
    const conversation = this.known(id);
    if (conversation.process.kind === "live") await conversation.process.pi.command("abort");
    return {};
  }

  private async respond(params: AgentRespondRequest) {
    const conversation = this.known(params.id);
    if (!conversation.prompts.has(params.promptId)) throw new RPCError(UNKNOWN_PROMPT, `Unknown prompt ${params.promptId}`);
    const pi = await this.ensure(conversation);
    const answer = params.cancelled ? { cancelled: true }
      : params.confirmed !== undefined ? { confirmed: params.confirmed }
      : params.value !== undefined ? { value: params.value }
      : undefined;
    if (!answer) throw new RPCError(-32602, "conversations.respond needs value, confirmed or cancelled");
    pi.write({ type: "extension_ui_response", id: params.promptId, ...answer });
    conversation.prompts.delete(params.promptId);
    return {};
  }

  private async rename(id: string, title: string) {
    await this.command(id, "set_session_name", { name: title });
    this.retitle(this.known(id), title);
    return {};
  }

  private async command(id: string, type: string, fields: Record<string, unknown> = {}) {
    const pi = await this.ensure(this.known(id));
    await pi.command(type, fields);
    return {};
  }

  private known(id: string): Conversation {
    const conversation = this.conversations.get(id);
    if (!conversation) throw new RPCError(UNKNOWN_CONVERSATION, `Conversation ${id} is not open; call conversations.open first`);
    return conversation;
  }

  private register(id: string, cwd: string, origin: Origin, context: AgentContext, tools: AgentTool[], title: string | null): Conversation {
    const conversation: Conversation = {
      id, cwd, origin, context, tools, title, subscribers: new Set(), process: { kind: "stopped" }, prompts: new Map(), activeTools: new Set(),
      events: new EventLog(this.options.eventLimits ?? DEFAULT_EVENT_LIMITS), reply: "",
    };
    this.conversations.set(id, conversation);
    return conversation;
  }

  private subscribe(conversation: Conversation, socket: AgentSocket): void {
    clearTimeout(conversation.idleTimer);
    conversation.subscribers.delete(socket);
    conversation.subscribers.add(socket);
    socket.data.conversations.add(conversation.id);
  }

  private unsubscribe(conversation: Conversation, socket: AgentSocket): void {
    conversation.subscribers.delete(socket);
    socket.data.conversations.delete(conversation.id);
    this.scheduleIdleClose(conversation);
  }

  private scheduleIdleClose(conversation: Conversation): void {
    clearTimeout(conversation.idleTimer);
    const process = conversation.process;
    if (conversation.subscribers.size || process.kind !== "live" || process.run !== "idle") return;
    conversation.idleTimer = setTimeout(() => {
      if (conversation.subscribers.size || conversation.process !== process || process.run !== "idle") return;
      agentLog("pi.idle_close", { conversation: conversation.id, pid: process.pi.pid, seq: conversation.events.seq });
      conversation.events.clear();
      void process.pi.shutdown();
    }, this.options.idleCloseMs ?? IDLE_CLOSE_MS);
  }

  private runState(conversation: Conversation): RunState | "exited" {
    const process = conversation.process;
    if (process.kind === "live") return process.run;
    return process.kind === "starting" ? "idle" : "exited";
  }

  private async ensure(conversation: Conversation): Promise<PiProcess> {
    const process = conversation.process;
    if (process.kind === "live") return process.pi;
    if (process.kind === "starting") return await process.ready;
    const file = await this.sessions.find(conversation.id);
    if (!file) throw new RPCError(UNKNOWN_CONVERSATION, `Conversation ${conversation.id} has no saved history and is no longer running`);
    return await this.launch(conversation, ["--session", file.path]);
  }

  private launch(conversation: Conversation, sessionArguments: string[], env: Record<string, string> = {}): Promise<PiProcess> {
    const token = randomBytes(32).toString("hex");
    const pi: PiProcess = new PiProcess(
      this.options.executable,
      [...sessionArguments, "-e", this.extensionPath, ...approvalArguments(this.options.approval)],
      { cwd: conversation.cwd, env: { ...env, [BRIDGE_ENVIRONMENT]: `${this.bridgeURL}/${token}` }, label: conversation.id },
      (record) => this.receivePi(conversation, pi, record),
    );
    this.tokens.set(token, conversation.id);
    void pi.exited.then((exit) => this.exited(conversation, pi, token, exit));
    const ready = withTimeout(pi.command<PiState>("get_state"), STARTUP_TIMEOUT_MS, "pi did not start in time").then((state) => {
      if (conversation.process.kind === "starting" && conversation.process.ready === ready) {
        conversation.process = { kind: "live", pi, run: state.isStreaming ? "running" : "idle" };
      }
      if (state.sessionName) conversation.title = state.sessionName;
      this.scheduleIdleClose(conversation);
      return pi;
    }, async (error) => {
      await pi.shutdown();
      throw error;
    });
    conversation.process = { kind: "starting", ready };
    return ready;
  }

  private exited(conversation: Conversation, pi: PiProcess, token: string, exit: PiExit): void {
    this.tokens.delete(token);
    const process = conversation.process;
    const current = process.kind === "live" ? process.pi === pi : process.kind === "starting";
    if (!current) return;
    clearTimeout(conversation.idleTimer);
    conversation.process = { kind: "stopped" };
    conversation.prompts.clear();
    conversation.activeTools.clear();
    const error = exit.requested ? undefined : exitMessage(exit);
    this.notify(conversation, "conversations.changed", { id: conversation.id, state: "exited", title: conversation.title, error });
    if (error) this.pushUnwatched(conversation, "failed", error);
  }

  private receivePi(conversation: Conversation, pi: PiProcess, record: PiRecord): void {
    if (record.type === "extension_ui_request") {
      this.extensionRequest(conversation, record);
      return;
    }
    if (record.type === "entry_appended" && (record.entry as { customType?: unknown } | undefined)?.customType === ORIGIN_ENTRY) return;
    const text = conversation.events.append((seq) => JSON.stringify({ jsonrpc: "2.0", method: "conversations.event", params: { id: conversation.id, seq, event: record } }));
    for (const socket of conversation.subscribers) this.sendText(socket, text);
    if (record.type === "agent_start") this.setRun(conversation, pi, "running");
    else if (record.type === "agent_settled") this.setRun(conversation, pi, "idle");
    else if (record.type === "session_info_changed") this.retitle(conversation, typeof record.name === "string" ? record.name : null);
    else if (record.type === "tool_execution_start") conversation.activeTools.add(String(record.toolCallId));
    else if (record.type === "tool_execution_end") conversation.activeTools.delete(String(record.toolCallId));
    else if (record.type === "message_end") conversation.reply = assistantText(record) ?? conversation.reply;
  }

  private setRun(conversation: Conversation, pi: PiProcess, run: RunState): void {
    const process = conversation.process;
    if (process.kind !== "live" || process.pi !== pi || process.run === run) return;
    process.run = run;
    this.notify(conversation, "conversations.changed", { id: conversation.id, state: run, title: conversation.title });
    if (run === "running") conversation.reply = "";
    else this.pushUnwatched(conversation, "completed", conversation.reply || "Finished");
    this.scheduleIdleClose(conversation);
  }

  private retitle(conversation: Conversation, title: string | null): void {
    if (conversation.title === title) return;
    conversation.title = title;
    this.notify(conversation, "conversations.changed", { id: conversation.id, state: this.runState(conversation), title });
  }

  private extensionRequest(conversation: Conversation, record: PiRecord): void {
    const method = String(record.method);
    if (!DIALOG_METHODS.has(method) || typeof record.id !== "string") {
      agentLog("pi.ui", { conversation: conversation.id, method });
      return;
    }
    const promptId = record.id;
    const toolCallId = conversation.activeTools.size === 1 ? [...conversation.activeTools][0] : undefined;
    const timeout = typeof record.timeout === "number" ? record.timeout : undefined;
    const prompt = {
      id: conversation.id,
      promptId,
      method,
      title: typeof record.title === "string" ? record.title : "",
      message: optionalString(record.message),
      options: Array.isArray(record.options) ? record.options.map(String) : undefined,
      placeholder: optionalString(record.placeholder),
      prefill: optionalString(record.prefill),
      toolCallId,
      timeout,
    } as AgentPromptNotification;
    conversation.prompts.set(promptId, prompt);
    if (timeout) setTimeout(() => conversation.prompts.delete(promptId), timeout);
    agentLog("pi.prompt", { conversation: conversation.id, method, toolCall: toolCallId !== undefined });
    this.notify(conversation, "conversations.prompt", prompt);
    this.pushUnwatched(conversation, "needsAttention", optionalString(record.title) || optionalString(record.message) || "Waiting for your answer");
  }

  private pushUnwatched(conversation: Conversation, kind: PushKind, body: string): void {
    if (conversation.subscribers.size > 0) return;
    this.push.send({ kind, conversation: conversation.id, title: conversation.title ?? "Ox", body });
  }
}

function assistantText(record: PiRecord): string | undefined {
  const message = record.message as { role?: unknown; content?: unknown } | undefined;
  if (message?.role !== "assistant" || !Array.isArray(message.content)) return undefined;
  const text = message.content
    .flatMap((block: { type?: unknown; text?: unknown }) => block.type === "text" && typeof block.text === "string" ? [block.text] : [])
    .join(" ")
    .replace(/\s+/g, " ")
    .trim();
  return text || undefined;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function modelRef(model: { provider?: unknown; id?: unknown } | undefined): AgentModelRef | null {
  return model && typeof model.provider === "string" && typeof model.id === "string" ? { provider: model.provider, id: model.id } : null;
}

function withSnapshotNames(models: AgentModel[]): AgentModel[] {
  const aliases = new Set(models.map((model) => `${model.provider}/${model.id}`));
  return models.map((model) => {
    const name = model.name.replace(/ \(latest\)$/, "");
    const snapshot = /^(.+)-(\d{4})(\d{2})(\d{2})$/.exec(model.id);
    return snapshot && aliases.has(`${model.provider}/${snapshot[1]}`)
      ? { ...model, name: `${name} (${snapshot[2]}-${snapshot[3]}-${snapshot[4]})` }
      : { ...model, name };
  });
}

function toAgentModel(model: Record<string, unknown>): AgentModel {
  return {
    provider: String(model.provider),
    id: String(model.id),
    name: typeof model.name === "string" ? model.name : String(model.id),
    reasoning: model.reasoning === true,
    contextWindow: Number.isInteger(model.contextWindow) ? model.contextWindow as number : undefined,
    maxTokens: Number.isInteger(model.maxTokens) ? model.maxTokens as number : undefined,
    thinkingLevels: supportedThinkingLevels(model),
  };
}

const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;

function supportedThinkingLevels(model: Record<string, unknown>): string[] {
  if (model.reasoning !== true) return ["off"];
  const map = model.thinkingLevelMap && typeof model.thinkingLevelMap === "object" ? model.thinkingLevelMap as Record<string, unknown> : {};
  return THINKING_LEVELS.filter((level) => map[level] !== null && (level === "xhigh" || level === "max" ? map[level] !== undefined : true));
}

function withTimeout<T>(promise: Promise<T>, ms: number, message: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error(message)), ms); });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}
