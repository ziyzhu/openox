import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Context } from "@earendil-works/chord";
import { createModels, createProvider } from "@earendil-works/pi-ai/models";
import { getCurrentSystemPrompt, getCurrentTools } from "@earendil-works/pi-ai/utils/transcript";
import type { Message, Model, Tool, Api, ModelThinkingLevel } from "@earendil-works/pi-ai";
import { AgentDoc, defineExtension, defineTool, section, type EntryDraft, type UserInput, type ToolExecutionResult, type ToolExecutionMode } from "@earendil-works/pi-durable";
import { openProfileRuntime, type ProfileRuntime, type ConversationReference, type ConversationHistoryCursor,
  type ConversationListCursor, type PresentationChange, installOxProfile, type NormalizedProfileDraft,
  ApplicationPresentation, type ApplicationPresentationChange, ProfileArtifact, ProfileFile, ProfileIndex, canonical, type TextFileMount,
  ConversationApplicationMetadata, ConversationPresentation, type ArtifactFiles, type ArtifactRecord } from "../../index";
import type { CompactionCheckpoint, ConversationId, EntryId, GenerationCheckpoint, HarnessInspection, SubmissionId, TaskId, ToolExecutionApi, ToolTaskInput } from "@earendil-works/pi-durable";
import { ChatBindings } from "../../chat-bindings";
import { artifactPath, artifactRecord } from "../../profile/artifacts";
import { publicDocument, type WorkspaceFile } from "../../profile/workspace";
import { nativeDatabase } from "../../sqlite";
import { native } from "./bridge";
import { nativeStream } from "./native-model";
import { invokeFilesystem, type NativeFileMount } from "./filesystem";
import { resolveFileRequest, validateFileRequest, type FileOperation, type FileRequest } from "../../core/filesystem";
import { nativeArtifacts } from "./artifacts";
import { fileRequest, nativeFiles } from "./files";
import { composeIOSPrompt } from "./prompts";
import { composeTurnContext, type SystemPromptInput, type TurnState } from "../../core/prompts";
import { activeHost, sameScope, type HostScope } from "../../core/host-context";

const context = BACKGROUND_CONTEXT;
interface Config { chatID: string; title?: string; promptState: SystemPromptInput; isolatedWorkspace?: boolean; model: string; contextWindow: number; maxTokens: number;
  reasoning: boolean; tools: (Tool & { executionMode?: ToolExecutionMode })[]; messages: Message[]; toolExecutionMode?: ToolExecutionMode;
  providerID?: string; thinkingLevel?: ModelThinkingLevel | null; nativeReasoningEffort?: string | null }
interface Command extends ApplicationPresentationChange { action: string; draft?: NormalizedProfileDraft; config?: Config; chatID?: string | null; content?: UserInput;
  conversationCount?: number; mounts?: TextFileMount[];
  capability?: string; fileMounts?: NativeFileMount[]; operation?: FileOperation; arguments?: FileRequest;
  promptState?: SystemPromptInput; turnState?: TurnState;
  requestID?: string; submissionID?: SubmissionId; profileID?: string; path?: string; prefix?: string; text?: string; base64?: string; saved?: boolean; artifactFiles?: boolean; workspace?: boolean; prepareWorkspace?: boolean; publicFiles?: boolean; splitStorage?: boolean;
  artifact?: ArtifactRecord & { binary: boolean; saved: boolean }; writes?: { path: string; text: string }[]; removes?: string[]; entries?: EntryDraft[];
  offset?: number; length?: number; byPath?: boolean;
  reference?: ConversationReference | null; limit?: number; historyCursor?: ConversationHistoryCursor | null; listCursor?: ConversationListCursor | null;
  presentation?: PresentationChange | null; lastReadEntryID?: EntryId | null; entryID?: EntryId }
export interface NativeRecoveryPlan {
  scheduling: HarnessInspection["scheduling"];
  tasks: { reference: ConversationReference; taskID: TaskId }[];
  submissions: { reference: ConversationReference; submissionID: SubmissionId; requestID?: string }[];
  unconfigured: { reference: ConversationReference; reason: string }[];
}
const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function decodeBase64(value: string) {
  if (typeof value !== "string" || value.length % 4 !== 0 || value.length > Math.ceil(32 * 1024 * 1024 / 3) * 4 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) throw new Error("Invalid bounded artifact Base64");
  const size = value.length / 4 * 3 - (value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0);
  const bytes = new Uint8Array(size);
  for (let start = 0, offset = 0; start < value.length; start += 4) {
    const bits = (alphabet.indexOf(value[start]!) << 18) | (alphabet.indexOf(value[start + 1]!) << 12)
      | (Math.max(0, alphabet.indexOf(value[start + 2]!)) << 6) | Math.max(0, alphabet.indexOf(value[start + 3]!));
    for (const shift of [16, 8, 0]) if (offset < size) bytes[offset++] = (bits >> shift) & 255;
  }
  return bytes;
}
function encodeBase64(bytes: Uint8Array) {
  const parts: string[] = [];
  let part = "";
  for (let offset = 0; offset < bytes.length; offset += 3) {
    const bits = (bytes[offset]! << 16) | ((bytes[offset + 1] ?? 0) << 8) | (bytes[offset + 2] ?? 0);
    part += alphabet[(bits >> 18) & 63]! + alphabet[(bits >> 12) & 63]!
      + (offset + 1 < bytes.length ? alphabet[(bits >> 6) & 63]! : "=") + (offset + 2 < bytes.length ? alphabet[bits & 63]! : "=");
    if (part.length >= 16_384) { parts.push(part); part = ""; }
  }
  parts.push(part);
  return parts.join("");
}

export class IOSAgentAdapter {
  private session?: ProfileRuntime;
  private bindings?: ChatBindings;
  private application?: ApplicationPresentation;
  private artifacts?: ArtifactFiles;
  private preparingWorkspace = false;
  private publicFiles = false;
  private routes = new Map<ConversationId, string>();
  private configured = new Map<ConversationId, { provider: string; modelId: string; thinkingLevel: ModelThinkingLevel;
    nativeProviderID?: string; nativeReasoningEffort?: string; scope?: HostScope }>();
  private providerRoutes = new Map<string, ConversationId>();
  private models = createModels();
  private filesystemCalls = new Map<string, AbortController>();

  async command(args: Command): Promise<unknown> {
    if (args.action === "composePrompt") return composeIOSPrompt(args.promptState!);
    if (args.action === "installProfile") {
      if (this.session || !args.draft) throw new Error("Profile installation requires an unopened staged runtime and normalized draft");
      const count = args.conversationCount;
      if (count !== undefined && (!Number.isSafeInteger(count) || count < 0)) throw new Error("Invalid Profile conversation count");
      async function* conversations() {
        for (let index = 0; index < count!; index++) {
          yield await native<NormalizedProfileDraft["conversations"][number]>("profileInstallConversation", { index });
        }
      }
      return installOxProfile(args.draft, { database: nativeDatabase((op, sql, params) => native("sql", { op, sql, params })),
        artifacts: nativeArtifacts(), conversations: count === undefined ? undefined : conversations() });
    }
    if (args.action === "open") {
      if (this.session) throw new Error("Profile runtime already open");
      this.models = createModels();
      this.routes.clear(); this.configured.clear(); this.providerRoutes.clear();
      this.preparingWorkspace = args.prepareWorkspace === true;
      this.publicFiles = args.publicFiles === true;
      this.artifacts = args.artifactFiles && (!args.workspace || this.preparingWorkspace) ? nativeArtifacts() : undefined;
      const database = nativeDatabase((op, sql, params) => native("sql", { op, sql, params }));
      const session: ProfileRuntime = await openProfileRuntime({ database, models: this.models, profileID: args.profileID!,
        artifacts: this.artifacts, workspace: args.workspace, prepareWorkspace: args.prepareWorkspace, publicFiles: args.publicFiles,
        workspaceBackend: args.workspace || args.prepareWorkspace ? nativeFiles() : undefined,
        mounts: args.mounts?.map(({ path, files, access }) => {
          if (access !== "readOnly") throw new Error("Native text mounts must be read-only");
          return { path, access, source: { kind: "text", files } };
        }),
        createBlobID: args.artifactFiles ? undefined : () => native<string>("uuid", {}),
        settings: { retry: { enabled: true, maxRetries: 2 }, toolExecution: "parallel" },
        beforeProgress: reference => this.guardProgress(reference),
        onEvents: async (id, events) => {
          const chatID = this.routes.get(id);
          if (chatID) await native("agentEvents", { chatID, reference: session.conversations.reference(id), events });
        },
        onReport: error => { void native("report", { message: String(error) }); },
      });
      try {
        const bindings = new ChatBindings(session.harness);
        await bindings.restore();
        this.session = session; this.bindings = bindings; this.application = new ApplicationPresentation(session);
        return { opened: true };
      } catch (error) { await session.close(); throw error; }
    }
    const session = this.session;
    if (!session || !this.bindings) throw new Error("Profile runtime not open");
    if (args.profileID !== undefined && args.profileID !== session.conversations.profileID) throw new Error("Conversation Profile mismatch");
    if (args.action === "filesystemValidate") {
      validateFileRequest(args.operation!, args.arguments!);
      const id = args.reference?.conversationID ?? [...this.routes].find(([, chatID]) => chatID === args.chatID)?.[0];
      const request = session.workspace && id !== undefined ? resolveFileRequest(args.arguments!, `conversations/${id}`) : args.arguments!;
      return validateFileRequest(args.operation!, request);
    }
    if (args.action === "filesystemAbort") { this.filesystemCalls.get(args.capability!)?.abort(); return {}; }
    if (args.action === "filesystem") {
      if (args.reference && session.workspace && (await session.workspace.state()).deletedConversations.includes(args.reference.conversationID)) throw new Error("Conversation not found");
      if (this.filesystemCalls.has(args.capability!)) throw new Error("Filesystem capability already in use");
      const controller = new AbortController();
      this.filesystemCalls.set(args.capability!, controller);
      try { return await invokeFilesystem(session, args.capability!, args.fileMounts!, args.operation!, args.arguments!, controller.signal); }
      finally { this.filesystemCalls.delete(args.capability!); }
    }
    const qualifiedID = args.reference == null ? undefined : session.conversations.id(args.reference);
    if (args.action === "attach") return this.attach(args.config!, args.reference ?? undefined);
    const routeID = args.chatID ? [...this.routes].find(([, chatID]) => chatID === args.chatID)?.[0] : undefined;
    const compatibility = args.chatID && routeID === undefined
      ? args.action === "conversationContext" ? this.bindings.list().find(binding => binding.chatID === args.chatID) : await this.bindings.forChat(args.chatID)
      : undefined;
    const chatID = routeID ?? compatibility?.id;
    if (chatID !== undefined && qualifiedID !== undefined && chatID !== qualifiedID) throw new Error("Conversation UUID/reference mismatch");
    const reference = args.reference ?? (chatID === undefined ? undefined : session.conversations.reference(chatID));
    const required = () => {
      if (!reference) throw new Error("Conversation reference required");
      return reference;
    };
    const attached = () => { const ref = required(); this.route(ref.conversationID); return ref; };
    switch (args.action) {
      case "workspacePrepare": return this.prepareWorkspace();
      case "publicFilesPrepare": return this.preparePublicFiles(args.splitStorage === true);
      case "publicFilesInventory":
        if (!this.preparingWorkspace || !session.workspace) throw new Error("Private inventory requires StorageMigrator admission");
        return { files: Object.values((await session.workspace.state()).files).filter(file => file.hidden) };
      case "conversationCreate": return this.application!.create(args);
      case "conversationPopulate": await this.application!.populate(required(), args.entries!); return {};
      case "conversationFork": return this.fork(required(), args.entryID!, args.title);
      case "applicationLoad": return this.application!.load(required());
      case "applicationList": return this.application!.list(args.limit, args.listCursor ?? undefined);
      case "applicationSave": await this.application!.save(required(), args); return {};
      case "applicationDelete": await this.application!.delete(required()); return {};
      case "conversationList": return session.conversations.list(args.limit, args.listCursor ?? undefined);
      case "conversationMetadata": return session.conversations.metadata(required());
      case "conversationContext": {
        if (!reference) return { messages: [] };
        const conversation = await session.harness.conversation(session.conversations.id(reference), context);
        if (!conversation) throw new Error("Conversation not found");
        return { messages: (await conversation.context(context)).messages.filter(message => message.role !== "system") };
      }
      case "conversationHistory": return session.conversations.history(required(), args.limit, args.historyCursor ?? undefined);
      case "conversationPresent": await session.conversations.present(required(), args.presentation ?? undefined); return {};
      case "conversationRead": await session.conversations.markRead(required(), args.lastReadEntryID ?? null); return {};
      case "observe": await session.observe(attached()); return {};
      case "recoveryPlan": return this.recoveryPlan();
      case "run": {
        const target = attached();
        if (args.turnState?.hostContext) {
          const expected = this.configured.get(target.conversationID)?.scope;
          if (!expected || !sameScope(expected, activeHost(args.turnState.hostContext))) throw new Error("Turn state does not belong to the attached host/Profile scope");
        }
        await this.guardProgress(target);
        const content = args.content ?? "";
        const contextualContent = args.turnState ? [...(typeof content === "string" ? [{ type: "text" as const, text: content }] : content),
          { type: "text" as const, text: composeTurnContext(args.turnState), oxTransientContext: true }] : content;
        return session.run(target, { type: "input", content: contextualContent, requestId: args.requestID });
      }
      case "resumeExisting": return this.resumeExisting(attached(), args.submissionID, args.requestID);
      case "resume": {
        const target = attached();
        await this.guardProgress(target);
        session.harness.resume();
        return { resumed: true };
      }
      case "abort": {
        const target = attached();
        await this.guardProgress(target);
        await session.abort(target);
        return {};
      }
      case "inspect": {
        const result = await session.inspect(reference);
        const conversations = [...new Map([...this.bindings.list().map(({ id, chatID }) => [id, chatID] as const), ...this.routes]).entries()].map(([id, chatID]) => ({ id, chatID }));
        return { ...result, recovery: await this.recoveryPlan(result.inspection), conversations, streamEnds: Object.fromEntries(conversations
          .filter(({ id }) => result.streamEnds[id]).map(({ id, chatID }) => [chatID, result.streamEnds[id]])) };
      }
      case "fileMounts": return session.textMounts;
      case "skillPackages": return session.skillPackages;
      case "fileList": return this.fileList(args.prefix);
      case "fileBatch": await this.fileBatch(args.writes ?? [], args.removes ?? []); return {};
      case "fileSeed": return this.fileSeed(args.path!, args.text!);
      case "fileWrite":
        if (session.workspace && !this.isDocument(args.path!)) await session.workspace.write(args.path!, args.text!);
        else await session.files.write(args.path!, args.text!);
        return this.fileReceipt(args.path!);
      case "fileWriteBinary":
        if (session.workspace) {
          const path = reference && args.path!.startsWith("artifacts/") ? `conversations/${reference.conversationID}/${args.path!.slice(10)}` : args.path!;
          const file = await session.workspace.write(path, decodeBase64(args.base64!));
          return this.fileReceipt(file.path);
        }
        else await session.files.write(artifactPath(canonical(args.path!)), decodeBase64(args.base64!));
        return this.fileReceipt(args.path!);
      case "fileRead": {
        const content = session.workspace && !this.isDocument(args.path!) ? await session.workspace.read(args.path!) : await session.files.read(args.path!);
        return typeof content === "string" ? { content } : { base64: encodeBase64(content), ...await this.fileReceipt(args.path!) };
      }
      case "fileReference": {
        const content = session.workspace ? await session.workspace.read(args.path!, true) : await session.files.readReference(args.path!);
        return typeof content === "string" ? { content } : { base64: encodeBase64(content), ...await this.fileReceipt(args.path!) };
      }
      case "fileReadBinary": {
        const content = session.workspace ? await session.workspace.read(args.path!, true) : await session.files.readReference(args.path!);
        const bytes = typeof content === "string" ? new TextEncoder().encode(content) : content;
        return { base64: encodeBase64(bytes), ...await this.fileReceipt(args.path!) };
      }
      case "fileStat":
      case "fileArtifact": {
        const file = session.workspace ? await session.workspace.record(args.path!, !args.byPath) : await session.harness.snapshot(ProfileArtifact, artifactPath(canonical(args.path!)), context);
        const record = !file || ("hidden" in file && file.hidden) ? null : { ...file, reference: "id" in file ? file.id : file.path };
        return args.action === "fileStat" ? { file: record } : { artifact: record };
      }
      case "fileAdopt": await this.adopt(args.artifact!); return this.fileReceipt(args.artifact!.path);
      case "payloadRead": {
        const path = artifactPath(canonical(args.path!));
        if (session.workspace) {
          const record = await session.workspace.record(path);
          if (!record || !record.hidden || path !== `artifacts/payload-${record.sha256}.json`) throw new Error("Payload is not committed in this Profile");
          return { base64: await session.workspace.readRange(record.id, args.offset!, args.length!) };
        }
        const record = await session.harness.snapshot(ProfileArtifact, path, context);
        if (!this.artifacts?.readPayload || !record || path !== `artifacts/payload-${record.sha256}.json` || !record.binary) throw new Error("Payload is not committed in this Profile");
        return { base64: await this.artifacts.readPayload(record, args.offset!, args.length!) };
      }
      case "fileSaved": await this.fileSaved(args.path!, args.saved!); return {};
      case "fileMove":
        if (!session.workspace) throw new Error("Workspace unavailable");
        await session.workspace.move(args.path!, args.prefix!); return this.fileReceipt(args.prefix!);
      case "fileRemove":
        if (session.workspace && !this.isDocument(args.path!)) {
          const file = await session.workspace.record(args.path!);
          if (!file) throw new Error("File unavailable");
          await session.workspace.remove(file.path);
        } else await session.files.remove(args.path!);
        return {};
      case "close": await session.close(); this.session = undefined; this.bindings = undefined; this.application = undefined; this.artifacts = undefined; this.routes.clear(); this.configured.clear(); this.providerRoutes.clear(); return {};
      default: throw new Error("Unknown agent command");
    }
  }

  private isDocument(path: string) {
    return ["MEMORY.md", "SOUL.md", "skill-selections.json"].includes(path) || path.startsWith("skills/");
  }
  private async preparePublicFiles(split: boolean) {
    const session = this.session!;
    if (!this.preparingWorkspace || !session.workspace) throw new Error("Public files preparation requires StorageMigrator admission");
    await session.workspace.flush();
    if (split) await session.workspace.installFileIndex(Object.values((await session.workspace.state()).files).map(file => file.hidden
      ? { ...file, path: "payloads/" + file.path.split("/").at(-1)!, aliases: [...new Set([...(file.aliases ?? []), file.path])] }
      : file));
    await session.workspace.activatePublicFiles();
    const index = await session.files.index();
    for (const path of Object.keys(index).filter(publicDocument)) {
      if (await session.workspace.record(path, false)) continue;
      const content = await session.files.read(path);
      if (typeof content !== "string") throw new Error("Profile document migration requires UTF-8 text");
      await session.workspace.writeDocument(path, content);
    }
    await session.files.bindWorkspace(true);
    session.files.usePublicFiles(session.workspace);
    this.publicFiles = true;
    return { prepared: true, files: (await session.workspace.listFiles()).filter(file => !file.hidden).length };
  }
  private async prepareWorkspace() {
    const session = this.session!;
    if (!this.preparingWorkspace || !session.workspace) throw new Error("File preparation requires StorageMigrator admission");
    const state = await session.workspace.state();
    if (state.pending.some(operation => operation.op === "replace" && !("previous" in operation))) {
      await fileRequest("workspacePreparePending", { operations: state.pending });
    }
    if (state.initialized) {
      const files = Object.values(state.files).map(file => this.normalizedFile(file));
      await session.workspace.installFileIndex(files);
      await session.workspace.assignArchiveOwners(await this.archiveOwners(files));
      await session.files.bindWorkspace();
      await fileRequest("retireLegacyOwner");
      return { prepared: true, files: files.length };
    }
    const backend = nativeFiles();
    const index = await session.files.index(), files: WorkspaceFile[] = [];
    for (const path of await backend.inventory()) {
      const record = await session.harness.snapshot(ProfileArtifact, path, context);
      if (!record?.path) continue;
      files.push(this.normalizedFile({ ...record, id: await backend.identifier(), reference: path,
        mtime: index[path]?.mtime ?? 0, owner: null, hidden: !index[path] }));
    }
    const conversations: number[] = [];
    let cursor;
    do {
      const page = await session.conversations.list(100, cursor);
      conversations.push(...page.items.map(item => item.reference.conversationID)); cursor = page.next;
    } while (cursor);
    await session.workspace.install(files, conversations);
    await session.workspace.assignArchiveOwners(await this.archiveOwners(files));
    await session.files.bindWorkspace();
    await fileRequest("retireLegacyOwner");
    return { prepared: true, files: files.length, conversations: conversations.length };
  }

  private async archiveOwners(files: WorkspaceFile[]) {
    const archives = new Map(files.filter(file => file.hidden && file.path === `artifacts/payload-${file.sha256}.json`).map(file => [file.path, file]));
    const owners = new Map<string, Set<number>>();
    if (!archives.size) return new Map<string, number>();
    let cursor;
    do {
      const page = await this.session!.conversations.list(100, cursor);
      for (const item of page.items) {
        let history;
        do {
          const entries = await this.session!.conversations.history(item.reference, 100, history);
          for (const entry of entries.items) {
            if (!["ox.native.metadata", "ox.native.context", "ox.native.turn", "pi.reset"].includes(entry.kind)) continue;
            if (!entry.data || typeof entry.data !== "object" || Array.isArray(entry.data)) continue;
            const source = entry.data.source;
            if (!source || typeof source !== "object" || Array.isArray(source)) continue;
            const descriptor = typeof source.path === "string" ? source : source.source;
            if (!descriptor || typeof descriptor !== "object" || Array.isArray(descriptor) || typeof descriptor.path !== "string") continue;
            const file = archives.get(descriptor.path);
            if (!file || descriptor.size !== file.size || descriptor.sha256 !== file.sha256) continue;
            const ids = owners.get(file.path) ?? new Set<number>();
            ids.add(entry.conversationId); owners.set(file.path, ids);
          }
          history = entries.next;
        } while (history);
      }
      cursor = page.next;
    } while (cursor);
    const active = new Set((await this.session!.workspace!.state()).directories.filter(path => /^conversations\/[0-9]+$/.test(path)).map(path => Number(path.split("/")[1])));
    return new Map([...owners].filter(([, ids]) => ids.size === 1 && active.has([...ids][0]!)).map(([path, ids]) => [path, [...ids][0]!]));
  }
  private normalizedFile(file: WorkspaceFile & { reference?: string }): WorkspaceFile {
    const suffix = file.path.split("/").at(-1)!.split(".").slice(1).at(-1) ?? "";
    const extension = new TextEncoder().encode(suffix).length <= 32 ? suffix : "";
    const id = file.id.startsWith("file-") ? file.id : file.reference?.startsWith("artifacts/file-") ? file.reference.slice(10) : `file-${file.id}${extension ? "." + extension : ""}`;
    const { reference, ...record } = file;
    const aliases = [...new Set([...(file.aliases ?? []), file.id, ...(reference ? [reference, reference.split("/").at(-1)!] : [])])].filter(alias => alias !== id);
    return { ...record, id, aliases };
  }
  private route(id: ConversationId) {
    const chatID = this.routes.get(id);
    if (!chatID) throw new Error("Native conversation is not attached");
    return chatID;
  }
  private async fork(reference: ConversationReference, entryID: EntryId, title?: string) {
    const session = this.session!;
    const id = session.conversations.id(reference);
    if (!Number.isSafeInteger(entryID) || entryID < 0) throw new Error("Invalid fork entry ID");
    if (title !== undefined && (typeof title !== "string" || title.length > 1024)) throw new Error("Invalid conversation title");
    const source = await session.harness.conversation(id, context);
    if (!source) throw new Error("Conversation not found");
    if (!(await source.entries({ minEntryId: entryID, maxEntryId: entryID }, 1, undefined, context)).items.length) throw new Error("Fork entry is not visible in the qualified source history");
    const conversation = await source.fork(entryID, { ownership: { kind: "ownerless" }, init: async (tx, forkID) => {
      const agent = await tx.doc(AgentDoc, forkID);
      const alias = `${session.conversations.profileID}:${forkID}`;
      if (agent.model) {
        const metadata = await tx.doc(ConversationApplicationMetadata, forkID);
        if (!agent.model.provider.startsWith("ox-native:") && typeof metadata.fields.nativeProviderID !== "string") metadata.fields.nativeProviderID = agent.model.provider;
        agent.model.provider = `ox-native:${alias}`;
      }
      if (Array.isArray(agent.extensions)) agent.extensions = agent.extensions.map(name => name.startsWith("ox-chat:") ? `ox-chat:${alias}` : name);
      if (title !== undefined) (await tx.doc(ConversationPresentation, forkID)).title = title;
    } }, context);
    await session.workspace?.createConversation(conversation.id);
    const forkReference = session.conversations.reference(conversation.id);
    return { conversationID: conversation.id, reference: forkReference };
  }
  private async recoveryPlan(inspection?: HarnessInspection, target?: ConversationReference): Promise<NativeRecoveryPlan> {
    const session = this.session!;
    const current = inspection ?? await session.harness.inspect(context);
    const tasks = current.tasks.map(({ record }) => ({ reference: session.conversations.reference(record.conversationId), taskID: record.id }));
    const submissions = current.submissions.map(record => ({ reference: session.conversations.reference(record.conversationId),
      submissionID: record.id, ...(record.requestId === undefined ? {} : { requestID: record.requestId }) }));
    const ids = new Set([...tasks, ...submissions].map(({ reference }) => reference.conversationID));
    if (target) ids.add(session.conversations.id(target));
    const unconfigured: NativeRecoveryPlan["unconfigured"] = [];
    for (const id of ids) {
      let reason: string | undefined;
      const config = this.configured.get(id);
      const agent = await session.harness.snapshot(AgentDoc, id, context);
      const metadata = (await session.harness.snapshot(ConversationApplicationMetadata, id, context))?.fields;
      if (!this.routes.has(id)) reason = "nativeRouteMissing";
      else if (!config) reason = "nativeConfigurationMissing";
      else if (config.provider !== agent?.model?.provider || config.modelId !== agent.model.modelId) reason = "nativeModelConfigurationMismatch";
      else if (config.thinkingLevel !== (agent?.thinkingLevel ?? "off")) reason = "nativeReasoningConfigurationMismatch";
      else if (config.nativeProviderID !== (typeof metadata?.nativeProviderID === "string" ? metadata.nativeProviderID : undefined)
        || config.nativeReasoningEffort !== (typeof metadata?.nativeReasoningEffort === "string" ? metadata.nativeReasoningEffort : undefined)) reason = "nativeOptionsConfigurationMismatch";
      else if (this.providerRoutes.get(config.provider) !== id) reason = "nativeTransportRouteMismatch";
      else if (!this.models.getModel(config.provider, config.modelId)) reason = "nativeModelUnavailable";
      if (!reason && config) {
        for (const { record } of current.tasks.filter(({ record }) => record.conversationId === id)) {
          const checkpoint = record.kind === "pi.generation" ? record.state.checkpoint as GenerationCheckpoint | undefined
            : record.kind === "pi.compaction" ? record.state.checkpoint as CompactionCheckpoint | undefined : undefined;
          if (checkpoint && "model" in checkpoint && (checkpoint.model.provider !== config.provider || checkpoint.model.modelId !== config.modelId
            || !this.models.getModel(checkpoint.model.provider, checkpoint.model.modelId))) {
            reason = "nativeCheckpointModelUnavailable";
            break;
          }
          if (checkpoint && "thinkingLevel" in checkpoint && checkpoint.thinkingLevel !== config.thinkingLevel) {
            reason = "nativeCheckpointReasoningMismatch";
            break;
          }
        }
      }
      if (reason) unconfigured.push({ reference: session.conversations.reference(id), reason });
    }
    return { scheduling: current.scheduling, tasks, submissions, unconfigured };
  }
  private async guardProgress(target?: ConversationReference) {
    if (target && this.session!.workspace && (await this.session!.workspace.state()).deletedConversations.includes(target.conversationID)) throw new Error("Conversation not found");
    const recovery = await this.recoveryPlan(undefined, target);
    if (recovery.unconfigured.length) {
      const missing = recovery.unconfigured.map(({ reference, reason }) => `${reference.profileID}/${reference.conversationID}: ${reason}`).join(", ");
      throw new Error(`Native Profile progress blocked before submit/resume: ${missing}. Call recoveryPlan, attach every recovered conversation with its saved native model configuration, then retry. No input was submitted.`);
    }
  }
  private async resumeExisting(reference: ConversationReference, submissionID?: SubmissionId, requestID?: string) {
    const session = this.session!;
    const id = session.conversations.id(reference);
    if (submissionID !== undefined && (!Number.isSafeInteger(submissionID) || submissionID < 0)) throw new Error("Invalid submission ID");
    const record = submissionID === undefined && requestID !== undefined ? await session.harness.commit(tx => tx.submissionByRequest(id, requestID), context) : undefined;
    const existingID = submissionID ?? record?.id;
    if (existingID === undefined) throw new Error("Existing submission ID or request ID required");
    const submission = await session.harness.submission(existingID, context);
    if (!submission) throw new Error("Existing submission not found");
    const status = await submission.status(context);
    if (status.conversationId !== id || (requestID !== undefined && status.requestId !== requestID)) throw new Error("Submission conversation/request scope mismatch");
    await this.guardProgress(reference);
    return session.resumeExisting(reference, existingID);
  }
  private async executeNativeTool(name: string, arguments_: unknown, api: ToolExecutionApi, ctx: Context) {
    const session = this.session!;
    const task = await api.getTask(api.taskId, ctx);
    if (!task || task.kind !== "pi.tool" || task.conversationId !== api.conversationId) throw new Error("Native tool requires its authoritative Pi task");
    const input = task.input as ToolTaskInput;
    if (input.callId !== api.callId) throw new Error("Native tool task/call mismatch");
    const conversation = await session.harness.conversation(api.conversationId, ctx);
    if (!conversation) throw new Error("Native tool conversation not found");
    const active = await conversation.context(ctx);
    const entry = active.entries.find(entry => entry.id === input.assistant);
    const assistant = entry?.model?.find(message => message.role === "assistant" && message.content.some(block => block.type === "toolCall" && block.id === api.callId));
    if (assistant?.role !== "assistant") throw new Error("Native tool recovery requires its committed Pi assistant in active context");
    const call = assistant.content.find(block => block.type === "toolCall" && block.id === api.callId);
    const ordered = (value: unknown) => JSON.stringify(value, (_, item) => item && typeof item === "object" && !Array.isArray(item)
      ? Object.fromEntries(Object.entries(item).sort(([a], [b]) => a.localeCompare(b))) : item);
    if (call?.type !== "toolCall" || call.name !== name || ordered(call.arguments) !== ordered(arguments_)) throw new Error("Native tool name/arguments do not match its committed Pi generation");
    const boundary = active.messages.indexOf(assistant);
    if (boundary < 0) throw new Error("Native tool assistant is not present in canonical Pi model context");
    const prefix = active.messages.slice(0, boundary);
    return native<ToolExecutionResult>("nativeTool", { chatID: this.route(api.conversationId), reference: session.conversations.reference(api.conversationId),
      callID: api.callId, taskID: api.taskId, name, arguments: arguments_, assistantEntryID: input.assistant, assistant, toolCall: call,
      systemPrompt: getCurrentSystemPrompt(prefix), tools: getCurrentTools(prefix), contextMessages: prefix.filter(message => message.role !== "system") }, ctx.abortSignal);
  }
  private async fileReceipt(path: string) {
    const session = this.session!;
    path = canonical(path);
    if (session.workspace) {
      const file = await session.workspace.record(path, false);
      return file ? { ...file, file: { ...file, reference: file.id }, reference: { oxAttachment: file.id, oxProfileID: session.conversations.profileID } } : {};
    }
    if (!path.startsWith("artifacts/")) return {};
    const artifact = await session.harness.snapshot(ProfileArtifact, artifactPath(path), context);
    return artifact?.path ? { ...artifact, artifact, reference: { oxAttachment: path.slice(10), oxProfileID: session.conversations.profileID } } : {};
  }
  private async fileList(prefix?: string) {
    const session = this.session!;
    const root = canonical(prefix?.endsWith("/") ? prefix.slice(0, -1) : prefix ?? "");
    const entries = Object.entries(await session.files.index()).filter(([path]) => !root || path === root || path.startsWith(`${root}/`));
    const files = await Promise.all(entries.map(async ([path, metadata]) => {
      const artifact = this.artifacts && path.startsWith("artifacts/") ? await session.harness.snapshot(ProfileArtifact, path, context) : undefined;
      const file = artifact ? undefined : await session.harness.snapshot(ProfileFile, path, context);
      return { path, ...metadata, saved: artifact?.saved ?? file?.saved ?? false, ...(artifact ? { sha256: artifact.sha256 } : {}) };
    }));
    if (session.workspace) {
      const working = (await session.workspace.listFiles()).filter(file => !file.hidden && (!root || file.path === root || file.path.startsWith(root + "/"))).map(file => ({ ...file, reference: file.id }));
      const physical = new Set(working.map(file => file.path));
      return { files: [...files.filter(file => this.isDocument(file.path) && !physical.has(file.path)), ...working].sort((a, b) => a.path.localeCompare(b.path)) };
    }
    return { files: files.sort((a, b) => a.path.localeCompare(b.path)) };
  }
  private documentPath(path: string) {
    const name = canonical(path);
    if (!["MEMORY.md", "SOUL.md", "skill-selections.json"].includes(name) && !name.startsWith("skills/")) throw new Error("Operation requires Profile text documents, never artifacts");
    return name;
  }
  private async fileSeed(path: string, text: string) {
    path = this.documentPath(path);
    if (typeof text !== "string") throw new Error("Profile documents require UTF-8 text");
    const size = new TextEncoder().encode(text).length;
    if (size > 200 * 1024) throw new Error("Profile document exceeds size limit");
    if (this.publicFiles && publicDocument(path)) return this.session!.workspace!.seedDocument(path, text);
    return this.session!.harness.commit(async tx => {
      const index = await tx.doc(ProfileIndex);
      const existing = index.files[path];
      if (existing && existing.binary !== false) throw new Error("Existing Profile file is not text");
      const file = await tx.doc(ProfileFile, path, null);
      if (file.blob || typeof file.text !== "string") throw new Error("Existing Profile document is not text");
      if (existing) return { content: file.text };
      if (Object.keys(index.files).length >= 10_000) throw new Error("Profile file count limit reached");
      file.text = text; file.blob = ""; file.saved = false;
      index.files[path] = { size, mtime: Date.now(), binary: false };
      return { content: text };
    }, context);
  }
  private async fileBatch(writes: { path: string; text: string }[], removes: string[]) {
    if (!Array.isArray(writes) || !Array.isArray(removes)) throw new Error("Invalid Profile document batch");
    let changes = writes.map(({ path, text }) => {
      if (typeof text !== "string") throw new Error("Profile documents require UTF-8 text");
      const size = new TextEncoder().encode(text).length;
      if (size > 200 * 1024) throw new Error("Profile document exceeds size limit");
      return { path: this.documentPath(path), text, size };
    });
    const names = new Set(changes.map(({ path }) => path));
    if (names.size !== changes.length) throw new Error("Duplicate batch write path");
    let deleted = [...new Set(removes.map(path => this.documentPath(path)))].filter(path => !names.has(path));
    if (this.publicFiles) {
      await this.session!.workspace!.documentBatch(changes.filter(file => publicDocument(file.path)), deleted.filter(publicDocument));
      changes = changes.filter(file => !publicDocument(file.path)); deleted = deleted.filter(path => !publicDocument(path));
      if (!changes.length && !deleted.length) return;
    }
    await this.session!.harness.commit(async tx => {
      const index = await tx.doc(ProfileIndex);
      const remaining = new Set([...Object.keys(index.files).filter(path => !deleted.includes(path)), ...names]);
      if (remaining.size > 10_000) throw new Error("Profile file count limit reached");
      for (const path of deleted) {
        delete index.files[path];
        await tx.retireDoc(ProfileFile, path);
      }
      const mtime = Date.now();
      for (const { path, text, size } of changes) {
        const file = await tx.doc(ProfileFile, path, null);
        file.text = text; file.blob = ""; file.saved = false;
        index.files[path] = { size, mtime, binary: false };
      }
    }, context);
  }
  private async fileSaved(path: string, saved: boolean) {
    path = canonical(path);
    if (typeof saved !== "boolean") throw new Error("Saved flag must be Boolean");
    if (this.session!.workspace) { await this.session!.workspace.saved(path, saved); return; }
    if (!path.startsWith("artifacts/") || typeof saved !== "boolean") throw new Error("Saved flags require an artifact and Boolean");
    artifactPath(path);
    await this.session!.harness.commit(async tx => {
      const index = await tx.doc(ProfileIndex);
      if (!index.files[path]) throw new Error("Artifact is not visible");
      if (this.artifacts) (await tx.doc(ProfileArtifact, path, null)).saved = saved;
      else (await tx.doc(ProfileFile, path, null)).saved = saved;
    }, context);
  }
  private async adopt(file: ArtifactRecord & { binary: boolean; saved: boolean }) {
    if (!this.artifacts || !file || typeof file.binary !== "boolean" || typeof file.saved !== "boolean" || !Number.isSafeInteger(file.size) || file.size < 0 || file.size > (file.binary ? 32 * 1024 * 1024 : 200 * 1024)) throw new Error("Invalid file-backed artifact adoption");
    artifactRecord(file, file.path, file.size);
    const bytes = await this.artifacts.read(file);
    if (!file.binary) new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    await this.artifacts.flush(file.path);
    await this.session!.harness.commit(async tx => {
      const record = await tx.doc(ProfileArtifact, file.path, null);
      const index = await tx.doc(ProfileIndex);
      if (record.path) throw new Error("Artifact references are immutable; choose a distinct filename");
      if (Object.keys(index.files).length >= 10_000) throw new Error("Profile file count limit reached");
      Object.assign(record, file);
      index.files[file.path] = { size: file.size, mtime: Date.now(), binary: file.binary };
    }, context);
  }

  private async attach(config: Config, requestedReference?: ConversationReference) {
    if (!config?.chatID) throw new Error("A native route identity is required");
    const prompt = composeIOSPrompt(config.promptState, config.isolatedWorkspace);
    if (config.toolExecutionMode !== undefined && !["parallel", "sequential"].includes(config.toolExecutionMode)) throw new Error("Invalid tool execution mode");
    if (config.providerID !== undefined && (typeof config.providerID !== "string" || !config.providerID)) throw new Error("Invalid native credential provider ID");
    if (config.thinkingLevel != null && !["off", "minimal", "low", "medium", "high", "xhigh", "max"].includes(config.thinkingLevel)) throw new Error("Invalid Pi thinking level");
    if (config.nativeReasoningEffort != null && typeof config.nativeReasoningEffort !== "string") throw new Error("Invalid native reasoning effort");
    const session = this.session!;
    const existing = [...this.routes].find(([, chatID]) => chatID === config.chatID)?.[0]
      ?? this.bindings!.list().find(({ chatID }) => chatID === config.chatID)?.id;
    if (requestedReference && existing !== undefined && session.conversations.id(requestedReference) !== existing) throw new Error("Conversation UUID/reference mismatch");
    const conversation = requestedReference ? await session.harness.conversation(session.conversations.id(requestedReference), context)
      : await this.bindings!.attach(config.chatID, config.messages);
    if (!conversation) throw new Error("Conversation not found");
    const reference = session.conversations.reference(conversation.id);
    const metadata = await session.conversations.metadata(reference);
    let alias = metadata.agent?.model?.provider;
    if (!alias?.startsWith("ox-native:") && !metadata.record?.parent) {
      const loaded = requestedReference ? await this.application!.load(reference) : undefined;
      const assistant = loaded?.entries.flatMap(entry => entry.model ?? []).find(message => message.role === "assistant" && message.provider.startsWith("ox-native:"));
      alias = assistant?.role === "assistant" ? assistant.provider : undefined;
    }
    alias = alias?.startsWith("ox-native:") ? alias : `ox-native:${requestedReference ? `${reference.profileID}:${conversation.id}` : config.chatID}`;
    const extensions = metadata.agent?.extensions;
    const extensionName = Array.isArray(extensions) ? extensions.find(name => name.startsWith("ox-chat:")) : undefined;
    const stream = (model: Model<Api>, transcript: Parameters<typeof nativeStream>[2], options?: Parameters<typeof nativeStream>[3]) => nativeStream(this.route(conversation.id), model, transcript, options, reference);
    this.configured.delete(conversation.id);
    this.providerRoutes.set(alias, conversation.id);
    this.models.setProvider(createProvider({ id: alias, auth: { apiKey: { name: "Native credentials", resolve: async () => ({ auth: {} }) } },
      models: [{ id: config.model, provider: alias, api: "ox-native", name: config.model, baseUrl: "", reasoning: config.reasoning,
        input: ["text"], contextWindow: config.contextWindow, maxTokens: config.maxTokens,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }], api: { stream, streamSimple: stream } }));
    const sections = Object.entries(prompt.sections).map(([key, text]) => section(key, () => text, { tag: false }));
    if (session.workspace) sections.push(section("working_directory", () => `Your working directory is conversations/${conversation.id}/. Relative workspace paths resolve there. Use / for the Profile root and absolute paths such as /reports/report.md for shared files. Mounted resource paths such as skills/ and services/ remain Profile-relative.`, { tag: false }));
    const extension = defineExtension({ name: extensionName ?? `ox-chat:${alias.slice(10)}`, sections,
      tools: config.tools.map(tool => defineTool({ ...tool, replay: "unsafe", executionMode: config.toolExecutionMode === "sequential" ? "sequential" : tool.executionMode ?? config.toolExecutionMode ?? "sequential",
        execute: async (arguments_, api, ctx) => this.executeNativeTool(tool.name, arguments_, api, ctx) })) });
    session.registry.install(extension);
    const previous = this.routes.get(conversation.id);
    this.routes.set(conversation.id, config.chatID);
    try {
      await conversation.commit(async tx => {
        const agent = await tx.doc(AgentDoc, conversation.id);
        agent.model = { provider: alias, modelId: config.model };
        agent.extensions = [extension.name, session.registry.snapshot().extension("ox-profile-files")!.name];
        if (config.thinkingLevel !== undefined) {
          if (config.thinkingLevel === null) delete agent.thinkingLevel; else agent.thinkingLevel = config.thinkingLevel;
        }
        if (config.providerID !== undefined || config.nativeReasoningEffort !== undefined) {
          const metadata = await tx.doc(ConversationApplicationMetadata, conversation.id);
          if (config.providerID !== undefined) metadata.fields.nativeProviderID = config.providerID;
          if (config.nativeReasoningEffort !== undefined) {
            if (config.nativeReasoningEffort === null) delete metadata.fields.nativeReasoningEffort;
            else metadata.fields.nativeReasoningEffort = config.nativeReasoningEffort;
          }
        }
      }, context);
      if (!metadata.presentation) await session.conversations.present(reference, { visible: true, title: config.title ?? "" });
      await session.workspace?.createConversation(conversation.id);
      await session.observe(reference);
      const saved = (await session.harness.snapshot(ConversationApplicationMetadata, conversation.id, context))?.fields;
      this.configured.set(conversation.id, { provider: alias, modelId: config.model,
        scope: config.promptState.hostContext ? { ...config.promptState.hostContext.active } : undefined,
        thinkingLevel: config.thinkingLevel === undefined ? metadata.agent?.thinkingLevel ?? "off" : config.thinkingLevel ?? "off",
        nativeProviderID: config.providerID ?? (typeof saved?.nativeProviderID === "string" ? saved.nativeProviderID : undefined),
        nativeReasoningEffort: config.nativeReasoningEffort === undefined ? typeof saved?.nativeReasoningEffort === "string" ? saved.nativeReasoningEffort : undefined : config.nativeReasoningEffort ?? undefined });
      return { conversationID: conversation.id, reference };
    } catch (error) {
      if (previous) this.routes.set(conversation.id, previous); else this.routes.delete(conversation.id);
      throw error;
    }
  }
}
