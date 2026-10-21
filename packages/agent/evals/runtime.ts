import { Database } from "bun:sqlite";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createRegistry, defineExtension, section, defineTool, type ConversationId } from "@earendil-works/pi-durable";
import { createModels, type Models, type Provider } from "@earendil-works/pi-ai/models";
import { openaiProvider } from "@earendil-works/pi-ai/providers/openai";
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";
import { googleProvider } from "@earendil-works/pi-ai/providers/google";
import { Type } from "typebox";
import { nativeDatabase } from "../src/sqlite";
import { openProfileRuntime, canonical, composeOxPrompt, composeOxTurnSections, renderSections, bundledSkills, executeGuidance, type ProfileRuntime, type FileOperation, type HostContext, type TurnState } from "../src/index";
import { guidanceText } from "../src/core/guidance-texts";
import { memoryFiles } from "./files";
import { execute } from "./execute";
import { catalog, Stubs, StubError, type StubFixture } from "./stubs";

export type Call = { name: string; args: Record<string, unknown>; result?: unknown; error?: { code: string; message: string; recovery: string } };
export type AttachedService = TurnState["attachedServices"][number];
type Messages = Awaited<ReturnType<ProfileRuntime["run"]>>["messages"];
export type Turn = { status: "completed" | "failed" | "timeout"; error?: string; systemPrompt: string; messages: Messages; calls: Call[] };

const namespaces = ["app", "conversation", "provider", "repository", "secret", "service", "user", "web", "fs", "output", "skill", "schedule", "vision"];
const contractCatalog = () => [...namespaces.map(name => `ox.${name} — ${guidanceText(`namespace.${name}`)}`), "", ...Object.entries(catalog).map(([name, contract]) => `${name} — ${contract.description.split(/\s+/).join(" ")}`).sort()].join("\n");

export function evalModels(provider: string): Models {
  const factories: Record<string, () => Provider> = { openai: openaiProvider, anthropic: anthropicProvider, google: googleProvider };
  if (!factories[provider]) throw new Error("Choose a configured direct provider: openai, anthropic, or google. Credentials use the provider's standard environment variables.");
  const models = createModels();
  models.setProvider(factories[provider]!());
  return models;
}

export class EvalRuntime {
  readonly stubs: Stubs;
  private session!: ProfileRuntime;
  private extension!: ReturnType<typeof defineExtension>;
  private calls = new Map<string, Call[]>();
  private prompts = new Map<string, string>();
  private temporary = new Set<string>();
  private readonly hostContext: HostContext = { active: { hostID: "eval", profileID: "eval" }, hosts: [{ hostID: "eval", profileID: "eval", functions: Object.keys(catalog), serviceKinds: ["web", "api", "ios", "mcp"], presentation: "conversation-bubbles", externalFiles: true }] };
  readonly provider: string;
  readonly model: string;
  private readonly attached: AttachedService[];
  private constructor(provider: string, model: string, fixture: StubFixture, attached: AttachedService[]) { this.provider = provider; this.model = model; this.attached = attached; this.stubs = new Stubs(fixture); }

  static async open(provider: string, model: string, fixture: StubFixture = {}, attached: AttachedService[] = [], models = evalModels(provider)) {
    if (!models.getModel(provider, model)) throw new Error(`Unknown model: ${provider}/${model}`);
    const runtime = new EvalRuntime(provider, model, fixture, attached);
    const db = new Database(":memory:");
    runtime.session = await openProfileRuntime({ database: nativeDatabase(async (op, sql, params) => {
      if (op === "close") { db.close(); return null; }
      if (op === "exec") { db.exec(sql); return null; }
      const bindings = params.map(value => value && typeof value === "object" && "blob" in value ? new Uint8Array(value.blob as number[]) : value && typeof value === "object" && "integer" in value ? BigInt(value.integer as string) : value);
      const statement = db.query(sql);
      if (op === "run") { statement.run(...bindings as never[]); return null; }
      return op === "get" ? statement.get(...bindings as never[]) : statement.all(...bindings as never[]);
    }), profileID: "eval", mounts: [{ path: "", access: "readWrite", source: { kind: "backend", backend: memoryFiles(fixture.files) } }], models, registry: createRegistry(), createBlobID: async () => crypto.randomUUID(), settings: { retry: { enabled: false }, compaction: { enabled: false } } });
    try {
      for (const [path, text] of Object.entries({ "MEMORY.md": "", ...fixture.files })) { if (path === "MEMORY.md" || path.startsWith("skills/")) await runtime.session.files.write(path, text); }
      const description = executeGuidance({ catalog: contractCatalog(), variant: "ox", timeoutSeconds: 10, maxLines: 1000, maxBytes: 262144, canCancelLoops: true });
      const parameters = Type.Object({ source: Type.String({ minLength: 1, maxLength: 100000 }) });
      runtime.extension = defineExtension({ name: "eval-ox", sections: [section("ox", input => runtime.prompts.get(String(input.conversationId))!, { tag: false })], tools: [defineTool({ name: "execute", description, parameters, replay: "unsafe",
        execute: async ({ source }, api, context) => {
          const text = await execute(source, (name, args) => runtime.call(String(api.conversationId), name, args), context.abortSignal);
          return { output: [{ type: "text", text }] };
        },
      })] });
      runtime.session.registry.install(runtime.extension);
      return runtime;
    } catch (error) { await runtime.close(); throw error; }
  }

  async close() { await this.session.close(); }

  async observe(name: string, args: Record<string, unknown>) { return this.call("", name, { purpose: "Observe eval state", ...args }); }

  async run(text: string, timeoutMs: number, temporary = false): Promise<Turn> {
    const conversation = await this.session.harness.createConversation({ ownership: { kind: "ownerless" }, agent: { model: { provider: this.provider, modelId: this.model }, extensions: [this.extension] } }, BACKGROUND_CONTEXT);
    const id = String(conversation.id);
    const target = { profileID: "eval", conversationID: Number(id) as ConversationId };
    const input = { hostContext: this.hostContext, memory: String(await this.session.files.read("MEMORY.md")) };
    const state: TurnState = { skills: [...bundledSkills], skillConflicts: [], attachedServices: this.attached, filePaths: [], storageMode: temporary ? "temporary" : "persisted", responseLanguage: null, hostContext: this.hostContext };
    const systemPrompt = renderSections({ ...composeOxPrompt(input).sections, ...composeOxTurnSections(state, input) });
    this.prompts.set(id, systemPrompt);
    this.calls.set(id, []);
    if (temporary) this.temporary.add(id);
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; void this.session.abort(target); }, timeoutMs);
    try {
      const turn = await this.session.run(target, { type: "input", content: text, requestId: crypto.randomUUID() });
      const last = turn.messages.at(-1);
      const completed = turn.receipt.status === "done" && last?.role === "assistant" && last.stopReason !== "error" && last.stopReason !== "aborted";
      return { status: completed ? "completed" : timedOut ? "timeout" : "failed", ...(completed ? {} : { error: last?.role === "assistant" && last.errorMessage || ("detail" in turn.receipt ? String(turn.receipt.detail) : turn.receipt.status) }), systemPrompt, messages: turn.messages, calls: structuredClone(this.calls.get(id)!) };
    } finally { clearTimeout(timer); }
  }

  private async call(id: string, name: string, args: Record<string, unknown>): Promise<unknown> {
    const call: Call = { name, args: structuredClone(args) };
    this.calls.get(id)?.push(call);
    try {
      this.stubs.validate(name, args);
      const profileMutation = ["ox.skill.create", "ox.skill.copy", "ox.skill.delete"].includes(name) ||
        ["write", "edit", "rm", "mkdir", "move", "copy"].some(operation => name === `ox.fs.${operation}`) &&
        [args.path, args.from, args.to].some(path => typeof path === "string" && /^(MEMORY\.md|SOUL\.md|skills)(\/|$)/.test(canonical(path)));
      if (this.temporary.has(id) && profileMutation) throw new StubError("permission_denied", "Temporary conversations cannot mutate Profile documents");
      let value: unknown;
      if (name.startsWith("ox.fs.") && !this.stubs.rules[name]) {
        const operation = name.slice(6) as FileOperation;
        if (operation === "attach" as string) throw new StubError("stub_unconfigured", "Prepare an attachment result in the case stubs");
        value = this.stubs.output(name, await this.session.filesystem.invoke(this.session.env, operation, args, BACKGROUND_CONTEXT));
      } else value = this.stubs.call(name, args);
      call.result = structuredClone(value);
      return value;
    } catch (error) {
      const e = error as Error & { code?: string; recovery?: string };
      call.error = { code: e.code ?? "operation_failed", message: e.message, recovery: e.recovery ?? "Inspect state and function help before retrying." };
      throw Object.assign(new Error(e.message), call.error);
    }
  }
}
