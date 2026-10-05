import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels, createProvider } from "@earendil-works/pi-ai/models";
import type { Message, Model, Tool, Api } from "@earendil-works/pi-ai";
import { defineExtension, defineTool, section, type UserInput, type ToolExecutionResult } from "@earendil-works/pi-durable";
import { openOxAgentSession, type OxAgentSession, type ConversationReference, type ConversationHistoryCursor,
  type ConversationListCursor, type PresentationChange } from "../../index";
import type { EntryId } from "@earendil-works/pi-durable";
import { ChatBindings, ConversationIdentity } from "../../chat-bindings";
import { nativeDatabase } from "../../sqlite";
import { native } from "./bridge";
import { nativeStream } from "./native-model";
import { nativeArtifacts } from "./artifacts";

const context = BACKGROUND_CONTEXT;
interface Config { chatID: string; title?: string; systemPrompt: string; model: string; contextWindow: number; maxTokens: number;
  reasoning: boolean; tools: Tool[]; messages: Message[] }
interface Command { action: string; config?: Config; chatID?: string | null; content?: UserInput;
  requestID?: string; profileID?: string; path?: string; text?: string; artifactFiles?: boolean;
  reference?: ConversationReference | null; limit?: number; historyCursor?: ConversationHistoryCursor | null; listCursor?: ConversationListCursor | null;
  presentation?: PresentationChange | null; lastReadEntryID?: EntryId | null }

/** JSC command compatibility layer. Only this adapter routes through Ox app chat UUIDs. */
export class IOSAgentAdapter {
  private session?: OxAgentSession;
  private bindings?: ChatBindings;
  private models = createModels();

  async command(args: Command): Promise<unknown> {
    if (args.action === "open") {
      if (this.session) throw new Error("Session already open");
      this.models = createModels();
      const database = nativeDatabase((op, sql, params) => native("sql", { op, sql, params }));
      const session: OxAgentSession = await openOxAgentSession({ database, models: this.models, profileID: args.profileID!,
        artifacts: args.artifactFiles ? nativeArtifacts() : undefined,
        createBlobID: args.artifactFiles ? undefined : () => native<string>("uuid", {}),
        settings: { retry: { enabled: true, maxRetries: 2 }, toolExecution: "sequential", compaction: { backgroundTokens: 0 } },
        authorizeFile: async (id, action, path, signal) => {
          const identity = await session.harness.snapshot(ConversationIdentity, id, context);
          if (!identity?.chatID) throw new Error("Native conversation is not attached");
          await native("filePermission", { chatID: identity.chatID, action, path }, signal);
        },
        onEvents: async (id, events) => {
          const chatID = this.bindings?.chatID(id);
          if (!chatID) throw new Error("Native conversation is not attached");
          await native("agentEvents", { chatID, reference: session.conversations.reference(id), events });
        },
        onReport: error => { void native("report", { message: String(error) }); },
      });
      try {
        const bindings = new ChatBindings(session.harness);
        await bindings.restore();
        this.session = session; this.bindings = bindings;
        return { opened: true };
      } catch (error) { await session.close(); throw error; }
    }
    const session = this.session;
    if (!session || !this.bindings) throw new Error("Session not open");
    // Qualified application identity is checked before even the compatibility UUID lookup.
    if (args.profileID !== undefined && args.profileID !== session.conversations.profileID) throw new Error("Conversation Profile mismatch");
    const qualifiedID = args.reference == null ? undefined : session.conversations.id(args.reference);
    if (args.action === "attach") return this.attach(args.config!, args.reference ?? undefined);
    const conversation = args.chatID ? await this.bindings.forChat(args.chatID) : undefined;
    if (conversation && qualifiedID !== undefined && conversation.id !== qualifiedID) throw new Error("Conversation UUID/reference mismatch");
    const reference = args.reference ?? (conversation ? session.conversations.reference(conversation.id) : undefined);
    const attached = () => {
      if (!reference || !this.bindings!.chatID(reference.conversationID)) throw new Error("Native conversation is not attached");
      return reference;
    };
    switch (args.action) {
      case "conversationList": return session.conversations.list(args.limit, args.listCursor ?? undefined);
      case "conversationMetadata": if (!reference) throw new Error("Conversation reference required"); return session.conversations.metadata(reference);
      case "conversationHistory": if (!reference) throw new Error("Conversation reference required"); return session.conversations.history(reference, args.limit, args.historyCursor ?? undefined);
      case "conversationPresent": if (!reference) throw new Error("Conversation reference required"); await session.conversations.present(reference, args.presentation ?? undefined); return {};
      case "conversationRead": if (!reference) throw new Error("Conversation reference required"); await session.conversations.markRead(reference, args.lastReadEntryID ?? null); return {};
      case "run": return session.run(attached(), { type: "input", content: args.content ?? "", requestId: args.requestID });
      case "abort": await session.abort(attached()); return {};
      case "inspect": {
        const result = await session.inspect(reference);
        return { ...result, conversations: this.bindings.list(), streamEnds: Object.fromEntries(this.bindings.list()
          .filter(({ id }) => result.streamEnds[id]).map(({ id, chatID }) => [chatID, result.streamEnds[id]])) };
      }
      case "fileWrite": await session.files.write(args.path!, args.text!); return {};
      case "fileRead": return { content: await session.files.read(args.path!) };
      case "fileReference": return { content: await session.files.readReference(args.path!) };
      case "fileRemove": await session.files.remove(args.path!); return {};
      case "close": await session.close(); this.session = undefined; this.bindings = undefined; return {};
      default: throw new Error("Unknown agent command");
    }
  }

  private async attach(config: Config, requestedReference?: ConversationReference) {
    const session = this.session!;
    // A reference can reattach its existing UUID route, never manufacture a new native binding.
    if (requestedReference && session.conversations.id(requestedReference) !== (await this.bindings!.forChat(config.chatID)).id) {
      throw new Error("Conversation UUID/reference mismatch");
    }
    // These names are persisted by Pi. Preserve them while changing code boundaries.
    const alias = `ox-native:${config.chatID}`;
    const stream = (model: Model<Api>, transcript: Parameters<typeof nativeStream>[2], options?: Parameters<typeof nativeStream>[3]) => nativeStream(config.chatID, model, transcript, options);
    this.models.setProvider(createProvider({ id: alias, auth: { apiKey: { name: "Native credentials", resolve: async () => ({ auth: {} }) } },
      models: [{ id: config.model, provider: alias, api: "ox-native", name: config.model, baseUrl: "", reasoning: config.reasoning,
        input: ["text"], contextWindow: config.contextWindow, maxTokens: config.maxTokens,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }], api: { stream, streamSimple: stream } }));
    const extension = defineExtension({ name: `ox-chat:${config.chatID}`, sections: [section("ox", () => config.systemPrompt, { tag: false })],
      tools: config.tools.map(tool => defineTool({ ...tool, replay: "unsafe", execute: async (arguments_, api, ctx) =>
        native<ToolExecutionResult>("nativeTool", { chatID: config.chatID, callID: api.callId, taskID: api.taskId,
          name: tool.name, arguments: arguments_ }, ctx.abortSignal) })) });
    session.registry.install(extension);
    const conversation = await this.bindings!.attach(config.chatID, config.messages);
    await conversation.configure({ model: { provider: alias, modelId: config.model }, extensions: [extension, session.registry.snapshot().extension("ox-profile-files")!] }, context);
    const reference = session.conversations.reference(conversation.id);
    if (!(await session.conversations.metadata(reference)).presentation) {
      await session.conversations.present(reference, { visible: true, title: config.title ?? "" });
    }
    await session.observe(reference);
    return { conversationID: conversation.id, reference };
  }
}
