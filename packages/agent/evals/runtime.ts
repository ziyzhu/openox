import { Database } from "bun:sqlite";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createRegistry, defineExtension, section, defineTool, type ConversationId } from "@earendil-works/pi-durable";
import { createModels, type Models, type Provider } from "@earendil-works/pi-ai/models";
import { openaiProvider } from "@earendil-works/pi-ai/providers/openai";
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";
import { googleProvider } from "@earendil-works/pi-ai/providers/google";
import { Type } from "typebox";
import { nativeDatabase } from "../src/sqlite";
import { openProfileRuntime, canonical, composeOxPrompt, composeTurnContext, bundledSkills, oxScaffold, executeGuidance, defaultSoul, type ProfileRuntime, type FileOperation, type HostContext } from "../src/index";
import { memoryFiles } from "./files";
import { execute } from "./execute";
import { catalog, Stubs, StubError, type StubFixture } from "./stubs";
import type { EvalSnapshot, Invocation, EvalMessage } from "../../../.agents/skills/evals/scripts/types";

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
  private active = "";
  private messages = new Map<string, EvalMessage[]>();
  private receipts = new Map<string, Invocation[]>();
  private busy = new Set<string>();
  private temporary = new Set<string>();
  private choices = new Map<string, Array<{prompt: {id:string;prompt:string;options:string[];allowsCustomAnswer:boolean;requiresApp:boolean};answer:string}>>();
  private hostContext: HostContext = { active: { hostID: "eval", profileID: "eval" }, hosts: [{ hostID: "eval", profileID: "eval", functions: Object.keys(catalog), serviceKinds: ["web", "api", "ios", "mcp"], presentation: "conversation-bubbles", externalFiles: true }] };
  private prompts = new Map<string, {rendered:string;soul:string;memory:string}>();
  private readonly tools: Array<{ name: string; description: string; parameters: unknown }> = [];
  readonly provider: string;
  readonly model: string;
  private extension!: ReturnType<typeof defineExtension>;
  private constructor(provider: string, model: string, fixture: StubFixture, profile: string) { this.provider = provider; this.model = model; this.stubs = new Stubs(fixture, profile); }
  static async open(provider: string, model: string, fixture: StubFixture, profile: string, models = evalModels(provider)) {
    if (!models.getModel(provider, model)) throw new Error(`Unknown model: ${provider}/${model}`);
    const runtime = new EvalRuntime(provider, model, fixture, profile);
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
      for (const [path, text] of Object.entries({ "MEMORY.md": "", "SOUL.md": defaultSoul, ...fixture.files })) { if (["MEMORY.md", "SOUL.md"].includes(path) || path.startsWith("skills/")) await runtime.session.files.write(path, text); }
      const description = executeGuidance({ catalog: Object.keys(catalog).join("\n"), variant: "ox", timeoutSeconds: 10, maxLines: 1000, maxBytes: 262144, canCancelLoops: true });
      const parameters = Type.Object({ source: Type.String({ minLength: 1, maxLength: 100000 }) });
      runtime.tools.push({ name: "execute", description, parameters });
      runtime.extension = defineExtension({ name: "eval-ox", sections: [section("ox", input => runtime.prompts.get(String(input.conversationId))!.rendered, { tag: false })], tools: [defineTool({ name: "execute", description, parameters, replay: "unsafe",
        execute: async ({ source }, api, context) => {
          const text = await execute(source, (name, args) => runtime.call(String(api.conversationId), name, args, true), context.abortSignal);
          return { output: [{ type: "text", text }] };
        },
      })] });
      runtime.session.registry.install(runtime.extension);
      return runtime;
    } catch (error) { await runtime.close(); throw error; }
  }
  recordedChoices(id: string) { return structuredClone(this.choices.get(id) ?? []); }
  async close() { await this.session.close(); }
  private async call(id: string, name: string, args: Record<string, unknown>, record: boolean): Promise<unknown> {
    const invocation: Invocation = { name, args: structuredClone(args), outcome: { running: {} } };
    if (record) this.receipts.get(id)!.push(invocation);
    try {
      this.stubs.validate(name, args);
      const profileMutation = ["ox.skill.create", "ox.skill.copy", "ox.skill.delete"].includes(name) ||
        ["write", "edit", "delete", "mkdir", "rmdir", "move", "copy"].some(operation => name === `ox.fs.${operation}`) &&
        [args.path, args.from, args.to].some(path => typeof path === "string" && /^(MEMORY\.md|SOUL\.md|skills)(\/|$)/.test(canonical(path)));
      if (this.temporary.has(id) && profileMutation) throw new StubError("permission_denied", "Temporary conversations cannot mutate Profile documents");
      let value: unknown;
      if (name.startsWith("ox.fs.") && !this.stubs.rules[name]) {
        const operation = name.slice(6) as FileOperation;
        if (operation === "attach" as string) throw new StubError("stub_unconfigured", "Prepare an attachment result in the fixture");
        value = await this.session.filesystem.invoke(this.session.env, operation, args, BACKGROUND_CONTEXT);
        value = this.stubs.output(name, value);
      } else value = this.stubs.call(name, args);
      if (record && name === "ox.user.choose") this.choices.get(id)!.push({prompt:{id:`choice-${this.choices.get(id)!.length}`,prompt:String(args.body),options:args.options as string[],allowsCustomAnswer:true,requiresApp:false},answer:String(value)});
      invocation.outcome = { succeeded: { _0: value } };
      return value;
    } catch (error) {
      const e = error as Error & { code?: string; recovery?: string };
      const failure = { code: e.code ?? "operation_failed", message: e.message, recovery: e.recovery ?? "Inspect state and function help before retrying." };
      invocation.outcome = { failed: failure };
      throw Object.assign(new Error(e.message), failure);
    }
  }
  private snapshot(id: string): EvalSnapshot | null {
    if (!this.messages.has(id)) return null;
    return { id, isBusy: this.busy.has(id), messages: structuredClone(this.messages.get(id)!), blocks: [{ kind: { type: "thinking", trace: { entries: this.receipts.get(id)!.map(invocation => ({ invocation: structuredClone(invocation) })) } } }], systemPrompt: this.prompts.get(id)!.rendered, renderedSystemPrompt: this.prompts.get(id)!.rendered, soul: this.prompts.get(id)!.soul, memory: this.prompts.get(id)!.memory, tools: this.tools, model: { id: this.model } } as EvalSnapshot;
  }
  readonly request = async <T>(args: string[], conversationId?: string, timeoutMs = 30000): Promise<T> => {
    const id = conversationId ?? this.active;
    const flag = (name: string) => args[args.indexOf(name) + 1];
    let result: unknown;
    if (args[0] === "vm" && args[1] === "call") result = { value: await this.call(id, args[2]!, JSON.parse(flag("--args")!), false) };
    else if (args[0] === "host") result = args[1] === "logs" ? [] : this.stubs.state.providers;
    else if (args[1] === "new") {
      const conversation = await this.session.harness.createConversation({ ownership: { kind: "ownerless" }, agent: { model: { provider: this.provider, modelId: this.model }, extensions: [this.extension] } }, BACKGROUND_CONTEXT);
      this.active = String(conversation.id); this.messages.set(this.active, []); this.receipts.set(this.active, []); this.choices.set(this.active, []); if (args.includes("--temporary")) this.temporary.add(this.active);
      const soul = String(await this.session.files.read("SOUL.md"));
      const memory = String(await this.session.files.read("MEMORY.md"));
      this.prompts.set(this.active, {soul,memory,rendered:composeOxPrompt({hostContext:this.hostContext,soul,memory},false,oxScaffold).rendered});
      result = { conversationId: this.active, temporary: args.includes("--temporary"), model: `${this.provider}:${this.model}` };
    } else if (args[1] === "inspect" || args[1] === "open") result = this.snapshot(id);
    else if (args[1] === "list") result = [...this.messages.keys()].map(id => ({ id }));
    else if (args[1] === "stop") { await this.session.abort({ profileID: "eval", conversationID: Number(id) as ConversationId }); result = {}; }
    else if (args[1] === "send") {
      this.busy.add(id);
      const timer = setTimeout(() => { void this.session.abort({ profileID: "eval", conversationID: Number(id) as ConversationId }); }, timeoutMs);
      try {
        const turn = await this.session.run({ profileID: "eval", conversationID: Number(id) as ConversationId }, { type: "input", content: args[2]! + "\n\n" + composeTurnContext({skills:[...bundledSkills],skillConflicts:[],attachedServices:[],filePaths:[],storageMode:this.temporary.has(id)?"temporary":"persisted",responseLanguage:null,hostContext:this.hostContext}), requestId: crypto.randomUUID() });
        this.messages.set(id, turn.messages.map(message => {
          if (message.role === "assistant") return { type: "assistant", assistant: { content: message.content.map(block => block.type === "text" ? { type: "text", text: { text: block.text } } : block.type === "toolCall" ? { type: "toolCall", toolCall: block } : { type: block.type }), stopReason: message.stopReason, usage: message.usage } };
          if (message.role === "toolResult") return { type: "toolResult", toolResult: { toolCallId: message.toolCallId, toolName: message.toolName, isError: message.isError, content: message.content.map(block => ({ type: block.type, ...(block.type === "text" ? { text: { text: block.text } } : {}) })) } };
          return { type: message.role };
        }) as EvalMessage[]);
        const last = turn.messages.at(-1);
        result = { conversationId: id, outcome: turn.receipt.status === "done" && last?.role === "assistant" && last.stopReason !== "error" && last.stopReason !== "aborted" ? "completed" : "failed", ...(last?.role === "assistant" && last.errorMessage ? { error: last.errorMessage } : {}) };
      } finally { clearTimeout(timer); this.busy.delete(id); }
    } else throw new Error(`Unsupported eval transport command: ${args.slice(0, 2).join(" ")}`);
    return structuredClone(result) as T;
  };
}
