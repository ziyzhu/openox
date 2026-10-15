import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Context } from "@earendil-works/chord";
import { createModels, createProvider } from "@earendil-works/pi-ai/models";
import { getCurrentSystemPrompt, getCurrentTools } from "@earendil-works/pi-ai/utils/transcript";
import type { Model, Tool, Api, ModelThinkingLevel } from "@earendil-works/pi-ai";
import { AgentDoc, defineExtension, defineTool, section, type EntryDraft, type UserInput, type ToolExecutionResult, type ToolExecutionMode } from "@earendil-works/pi-durable";
import { openProfileRuntime, type ProfileRuntime, type ConversationReference, type ConversationHistoryCursor,
  type ConversationListCursor, type PresentationChange, installOxProfile, type NormalizedProfileDraft,
  ApplicationPresentation, type ApplicationPresentationChange, LegacyProfileFile, ProfileFile, ProfileIndex, canonical, type TextFileMount,
  ConversationApplicationMetadata, ConversationPresentation, type FilePayloadStore, type FileRecord } from "../../index";
import type { CompactionCheckpoint, ConversationId, EntryId, GenerationCheckpoint, HarnessInspection, SubmissionId, TaskId, ToolExecutionApi, ToolTaskInput } from "@earendil-works/pi-durable";
import { legacyFilePath, validateFileRecord } from "../../profile/file-payloads";
import { publicDocument, type ProfileFileRecord } from "../../profile/file-store";
import { nativeDatabase } from "../../sqlite";
import { native } from "./bridge";
import { nativeStream } from "./native-model";
import { invokeFilesystem, type NativeFileMount } from "./filesystem";
import { resolveFileRequest, validateFileRequest, type FileOperation, type FileRequest } from "../../core/filesystem";
import { nativeFilePayloads } from "./file-payloads";
import { fileRequest, nativeFiles } from "./files";
import { composeIOSPrompt } from "./prompts";
import { composeTurnContext, type SystemPromptInput, type TurnState } from "../../core/prompts";
import { activeHost, sameScope, type HostScope } from "../../core/host-context";

const context = BACKGROUND_CONTEXT;
interface Config { title?: string; promptState: SystemPromptInput; isolatedFiles?: boolean; model: string; contextWindow: number; maxTokens: number;
  reasoning: boolean; tools: (Tool & { executionMode?: ToolExecutionMode })[]; toolExecutionMode?: ToolExecutionMode;
  providerID?: string; thinkingLevel?: ModelThinkingLevel | null; nativeReasoningEffort?: string | null }
type CommandScope = { profileID?: string; conversationID?: ConversationId; reference?: ConversationReference | null };
type Command = CommandScope & (
  | { action: "composePrompt"; promptState: SystemPromptInput }
  | { action: "installProfile"; draft: NormalizedProfileDraft; conversationCount?: number }
  | { action: "open"; profileID: string; mounts?: TextFileMount[]; artifactFiles?: boolean; physicalFiles?: boolean; prepareFiles?: boolean; publicFiles?: boolean }
  | { action: "attach"; config: Config }
  | { action: "filesystemValidate"; operation: FileOperation; arguments: FileRequest }
  | { action: "filesystemAbort"; capability: string }
  | { action: "filesystem"; capability: string; fileMounts: NativeFileMount[]; operation: FileOperation; arguments: FileRequest }
  | { action: "publicFilesPrepare"; splitStorage?: boolean }
  | { action: "profileImportIdentity"; identity: string }
  | ({ action: "conversationCreate"; entries?: EntryDraft[] } & ApplicationPresentationChange)
  | ({ action: "applicationSave" } & ApplicationPresentationChange)
  | { action: "conversationPopulate"; entries: EntryDraft[] }
  | { action: "conversationFork"; entryID: EntryId; title?: string }
  | { action: "applicationList" | "conversationList"; limit?: number; listCursor?: ConversationListCursor | null }
  | { action: "conversationHistory"; limit?: number; historyCursor?: ConversationHistoryCursor | null }
  | { action: "conversationPresent"; presentation?: PresentationChange | null }
  | { action: "conversationRead"; lastReadEntryID?: EntryId | null }
  | { action: "run"; content?: UserInput; turnState?: TurnState; requestID?: string }
  | { action: "resumeExisting"; submissionID?: SubmissionId; requestID?: string }
  | { action: "fileList"; prefix?: string; limit?: number; fileCursor?: string | null }
  | { action: "fileResolve"; paths: string[] }
  | { action: "fileWriteStaged"; path: string; file: FileRecord }
  | { action: "fileBatch"; writes?: { path: string; text: string }[]; removes?: string[] }
  | { action: "fileSeed" | "fileWrite"; path: string; text: string }
  | { action: "fileWriteBinary"; path: string; base64: string }
  | { action: "fileRead" | "fileReference" | "fileReadBinary" | "fileRemove"; path: string }
  | { action: "fileStat"; path: string; byPath?: boolean }
  | { action: "fileAdopt"; artifact: FileRecord & { binary: boolean; saved: boolean } }
  | { action: "fileSaved"; path: string; saved: boolean }
  | { action: "fileMove"; path: string; prefix: string }
  | { action: "filesPrepare" | "publicFilesInventory" | "applicationLoad" | "applicationDelete" | "conversationMetadata" | "conversationContext"
      | "profileExportCheck" | "observe" | "recoveryPlan" | "resume" | "abort" | "inspect" | "fileMounts" | "skillPackages" | "close" }
);
interface OpenedSession {
  session: ProfileRuntime;
  application: ApplicationPresentation;
  artifacts?: FilePayloadStore;
  preparingFiles: boolean;
  publicFiles: boolean;
}
interface NativeConfiguration {
  provider: string;
  modelId: string;
  thinkingLevel: ModelThinkingLevel;
  nativeProviderID?: string;
  nativeReasoningEffort?: string;
  scope?: HostScope;
}
type NativeAttachment = (
  | { status: "attaching" }
  | { status: "attached"; configuration: NativeConfiguration }
);
export interface NativeRecoveryPlan {
  scheduling: HarnessInspection["scheduling"];
  tasks: { reference: ConversationReference; taskID: TaskId }[];
  submissions: { reference: ConversationReference; submissionID: SubmissionId; requestID?: string }[];
  unconfigured: { reference: ConversationReference; reason: string }[];
}
const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function decodeBase64(value: string) {
  if (typeof value !== "string" || value.length % 4 !== 0 || value.length > Math.ceil(32 * 1024 * 1024 / 3) * 4 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) throw new Error("Invalid bounded file Base64");
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
  private opened?: OpenedSession;
  private get current(): OpenedSession {
    if (!this.opened) throw new Error("Profile runtime not open");
    return this.opened;
  }
  private attachments = new Map<ConversationId, NativeAttachment>();
  private providerRoutes = new Map<string, ConversationId>();
  private models = createModels();
  private filesystemCalls = new Map<string, AbortController>();
  private fileListing?: { root: string; files: Awaited<ReturnType<IOSAgentAdapter["listedFiles"]>> };

  async command(args: Command): Promise<unknown> {
    if (args.action === "composePrompt") return composeIOSPrompt(args.promptState);
    if (args.action === "installProfile") {
      if (this.opened || !args.draft) throw new Error("Profile installation requires an unopened staged runtime and normalized draft");
      const count = args.conversationCount;
      if (count !== undefined && (!Number.isSafeInteger(count) || count < 0)) throw new Error("Invalid Profile conversation count");
      async function* conversations() {
        for (let index = 0; index < count!; index++) {
          yield await native<NormalizedProfileDraft["conversations"][number]>("profileInstallConversation", { index });
        }
      }
      return installOxProfile(args.draft, { database: nativeDatabase((op, sql, params) => native("sql", { op, sql, params })),
        artifacts: nativeFilePayloads(), conversations: count === undefined ? undefined : conversations() });
    }
    if (args.action === "open") {
      if (this.opened) throw new Error("Profile runtime already open");
      this.models = createModels();
      this.attachments.clear(); this.providerRoutes.clear();
      const preparingFiles = args.prepareFiles === true;
      const artifacts = args.artifactFiles && (!args.physicalFiles || preparingFiles) ? nativeFilePayloads() : undefined;
      const database = nativeDatabase((op, sql, params) => native("sql", { op, sql, params }));
      const session: ProfileRuntime = await openProfileRuntime({ database, models: this.models, profileID: args.profileID,
        artifacts,
        fileStorage: args.physicalFiles || args.prepareFiles ? { kind: preparingFiles ? "prepare" : "physical", backend: nativeFiles(), publicFiles: args.publicFiles } : undefined,
        mounts: args.mounts?.map(({ path, files, access }) => {
          if (access !== "readOnly") throw new Error("Native text mounts must be read-only");
          return { path, access, source: { kind: "text", files } };
        }),
        createBlobID: args.artifactFiles ? undefined : () => native<string>("uuid", {}),
        settings: { retry: { enabled: true, maxRetries: 2 }, toolExecution: "parallel" },
        decodeConversation: (sources, files) => fileRequest("conversationDecode", { profileID: args.profileID, sources,
          names: files.filter(file => !file.hidden).flatMap(file => [file.path.split("/").at(-1)!, ...(file.aliases ?? []).map(alias => alias.replace(/^artifacts\//, ""))]) }),
        beforeProgress: reference => this.guardProgress(reference),
        onEvents: async (id, events) => {
          if (this.attachments.has(id)) await native("agentEvents", { conversationID: id, reference: session.conversations.reference(id), events });
        },
        onReport: error => { void native("report", { message: String(error) }); },
      });
      try {
        this.opened = { session, application: new ApplicationPresentation(session), artifacts, preparingFiles, publicFiles: args.publicFiles === true };
        return { opened: true };
      } catch (error) { await session.close(); throw error; }
    }
    const { session, application } = this.current;
    if (args.profileID !== undefined && args.profileID !== session.conversations.profileID) throw new Error("Conversation Profile mismatch");
    const reference = args.reference ?? (args.conversationID === undefined ? undefined : session.conversations.reference(args.conversationID));
    if (reference) {
      const id = session.conversations.id(reference);
      if (args.conversationID !== undefined && id !== args.conversationID) throw new Error("Conversation identity mismatch");
    }
    if (args.action === "filesystemValidate") {
      validateFileRequest(args.operation, args.arguments);
      const id = reference?.conversationID;
      const request = session.files.physical && id !== undefined ? resolveFileRequest(args.arguments, `conversations/${id}`) : args.arguments;
      return validateFileRequest(args.operation, request);
    }
    if (args.action === "filesystemAbort") { this.filesystemCalls.get(args.capability)?.abort(); return {}; }
    if (args.action === "filesystem") {
      if (args.reference && session.files.physical && (await session.files.state()).deletedConversations.includes(args.reference.conversationID)) throw new Error("Conversation not found");
      if (this.filesystemCalls.has(args.capability)) throw new Error("Filesystem capability already in use");
      const controller = new AbortController();
      this.filesystemCalls.set(args.capability, controller);
      try { return await invokeFilesystem(session, args.capability, args.fileMounts, args.operation, args.arguments, controller.signal); }
      finally { this.filesystemCalls.delete(args.capability); }
    }
    if (args.action === "attach") {
      if (!reference) throw new Error("Pi conversation identity required before attachment");
      return this.attach(args.config, reference);
    }
    const required = () => {
      if (!reference) throw new Error("Conversation reference required");
      return reference;
    };
    const attached = () => { const ref = required(); this.route(ref.conversationID); return ref; };
    switch (args.action) {
      case "profileExportCheck": {
        const inspection = await session.harness.inspect(context);
        if (inspection.tasks.length || inspection.submissions.length) throw new Error("Stop running conversations and finish queued messages before exporting this Profile");
        if (session.files.physical && (await session.files.state()).pending.length) throw new Error("Finish pending file changes before exporting this Profile");
        await session.files.flush();
        return {};
      }
      case "profileImportIdentity": {
        if (!this.current.preparingFiles || !/^[0-9a-f-]{36}$/i.test(args.identity)) throw new Error("Profile import requires isolated storage preparation");
        const inspection = await session.harness.inspect(context);
        if (inspection.tasks.length || inspection.submissions.length) throw new Error("Backups containing pending actions cannot be imported");
        if ((await session.files.state()).pending.length) throw new Error("Backups containing pending file changes cannot be imported");
        await session.harness.commit(async tx => { (await tx.doc(ProfileIndex)).identity = args.identity; }, context);
        return {};
      }
      case "filesPrepare": return this.prepareFiles();
      case "publicFilesPrepare": return this.preparePublicFiles(args.splitStorage === true);
      case "publicFilesInventory":
        if (!this.current.preparingFiles || !session.files.physical) throw new Error("Private inventory requires StorageMigrator admission");
        return { files: Object.values((await session.files.state()).files).filter(file => file.hidden) };
      case "conversationCreate": return application.create(args);
      case "conversationPopulate": await application.populate(required(), args.entries); return {};
      case "conversationFork": return this.fork(required(), args.entryID, args.title);
      case "applicationLoad": return application.load(required());
      case "applicationList": return application.list(args.limit, args.listCursor ?? undefined);
      case "applicationSave": await application.save(required(), args); return {};
      case "applicationDelete": await application.delete(required()); return {};
      case "conversationList": return session.conversations.list(args.limit, args.listCursor ?? undefined);
      case "conversationMetadata": return session.conversations.metadata(required());
      case "conversationContext": {
        if (!reference) return { messages: [] };
        await session.prepareConversation(reference);
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
          const attachment = this.attachments.get(target.conversationID);
          const expected = attachment?.status === "attached" ? attachment.configuration.scope : undefined;
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
        const conversations = [...this.attachments.keys()].map(id => ({ id }));
        return { ...result, recovery: await this.recoveryPlan(result.inspection), conversations, streamEnds: Object.fromEntries(conversations
          .filter(({ id }) => result.streamEnds[id]).map(({ id }) => [id, result.streamEnds[id]])) };
      }
      case "fileMounts": return session.textMounts;
      case "skillPackages": return session.skillPackages;
      case "fileList": return this.fileList(args.prefix, args.limit, args.fileCursor ?? undefined);
      case "fileResolve": {
        if (!Array.isArray(args.paths) || args.paths.length > 100 || args.paths.some(path => typeof path !== "string")) throw new Error("Invalid file reference batch");
        const files = await session.files.records(args.paths);
        return { files: files.map(file => !file || file.hidden ? null : { ...file, reference: file.id }) };
      }
      case "fileWriteStaged": await session.files.writeStaged(args.path, args.file); return this.fileReceipt(args.path);
      case "fileBatch": await this.fileBatch(args.writes ?? [], args.removes ?? []); return {};
      case "fileSeed": return this.fileSeed(args.path, args.text);
      case "fileWrite":
        await session.files.write(args.path, args.text);
        return this.fileReceipt(args.path);
      case "fileWriteBinary":
        if (session.files.physical) {
          const path = reference && args.path.startsWith("artifacts/") ? `conversations/${reference.conversationID}/${args.path.slice(10)}` : args.path;
          await session.files.write(path, decodeBase64(args.base64));
          return this.fileReceipt(path);
        }
        else await session.files.write(legacyFilePath(canonical(args.path)), decodeBase64(args.base64));
        return this.fileReceipt(args.path);
      case "fileRead": {
        const content = await session.files.read(args.path);
        return typeof content === "string" ? { content } : { base64: encodeBase64(content), ...await this.fileReceipt(args.path) };
      }
      case "fileReference": {
        const content = await session.files.readReference(args.path);
        return typeof content === "string" ? { content } : { base64: encodeBase64(content), ...await this.fileReceipt(args.path) };
      }
      case "fileReadBinary": {
        const content = await session.files.readReference(args.path);
        const bytes = typeof content === "string" ? new TextEncoder().encode(content) : content;
        return { base64: encodeBase64(bytes), ...await this.fileReceipt(args.path) };
      }
      case "fileStat": {
        const file = session.files.physical ? await session.files.record(args.path, !args.byPath) : await session.harness.snapshot(LegacyProfileFile, legacyFilePath(canonical(args.path)), context);
        const record = !file || ("hidden" in file && file.hidden) ? null : { ...file, reference: "id" in file ? file.id : file.path };
        return { file: record };
      }
      case "fileAdopt": await this.adopt(args.artifact); return this.fileReceipt(args.artifact.path);
      case "fileSaved": await this.fileSaved(args.path, args.saved); return {};
      case "fileMove":
        await session.files.move(args.path, args.prefix); return this.fileReceipt(args.prefix);
      case "fileRemove":
        if (session.files.physical && !this.isDocument(args.path)) {
          const file = await session.files.record(args.path);
          if (!file) throw new Error("File unavailable");
          await session.files.remove(file.path);
        } else await session.files.remove(args.path);
        return {};
      case "close": await session.close(); this.opened = undefined; this.attachments.clear(); this.providerRoutes.clear(); this.fileListing = undefined; return {};
      default: throw new Error("Unknown agent command");
    }
  }

  private isDocument(path: string) {
    return ["MEMORY.md", "SOUL.md", "skill-selections.json"].includes(path) || path.startsWith("skills/");
  }
  private async preparePublicFiles(split: boolean) {
    const session = this.current.session;
    if (!this.current.preparingFiles || !session.files.physical) throw new Error("Public files preparation requires StorageMigrator admission");
    await session.files.flush();
    if (split) await session.files.installFileIndex(Object.values((await session.files.state()).files).map(file => file.hidden
      ? { ...file, path: "payloads/" + file.path.split("/").at(-1)!, aliases: [...new Set([...(file.aliases ?? []), file.path])] }
      : file));
    await session.files.activatePublicFiles();
    const index = await session.files.index();
    for (const path of Object.keys(index).filter(publicDocument)) {
      if (await session.files.record(path, false)) continue;
      const content = await session.files.read(path);
      if (typeof content !== "string") throw new Error("Profile document migration requires UTF-8 text");
      await session.files.writeDocument(path, content);
    }
    await session.files.bindPhysicalFiles(true);
    session.files.usePublicFiles();
    this.current.publicFiles = true;
    return { prepared: true, files: (await session.files.listFiles()).filter(file => !file.hidden).length };
  }
  private async prepareFiles() {
    const session = this.current.session;
    if (!this.current.preparingFiles || !session.files.physical) throw new Error("File preparation requires StorageMigrator admission");
    const state = await session.files.state();
    if (state.pending.some(operation => operation.op === "replace" && !("previous" in operation))) {
      await fileRequest("filesPreparePending", { operations: state.pending });
    }
    if (state.initialized) {
      const files = Object.values(state.files).map(file => this.normalizedFile(file));
      await session.files.installFileIndex(files);
      await session.files.assignArchiveOwners(await this.archiveOwners(files));
      await session.files.bindPhysicalFiles();
      return { prepared: true, files: files.length };
    }
    const backend = nativeFiles();
    const index = await session.files.index(), files: ProfileFileRecord[] = [];
    for (const path of await backend.inventory()) {
      const record = await session.harness.snapshot(LegacyProfileFile, path, context);
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
    await session.files.install(files, conversations);
    await session.files.assignArchiveOwners(await this.archiveOwners(files));
    await session.files.bindPhysicalFiles();
    return { prepared: true, files: files.length, conversations: conversations.length };
  }

  private async archiveOwners(files: ProfileFileRecord[]) {
    const archives = new Map(files.filter(file => file.hidden && file.path === `artifacts/payload-${file.sha256}.json`).map(file => [file.path, file]));
    const owners = new Map<string, Set<number>>();
    if (!archives.size) return new Map<string, number>();
    let cursor;
    do {
      const page = await this.current.session.conversations.list(100, cursor);
      for (const item of page.items) {
        let history;
        do {
          const conversation = await this.current.session.harness.conversation(item.reference.conversationID, context);
          if (!conversation) throw new Error("Conversation not found");
          const entries = await conversation.entries({}, 100, history, context);
          for (const entry of entries.items) {
            if (!["ox.native.conversation", "ox.native.transcript", "ox.native.metadata", "ox.native.context", "ox.native.turn", "pi.reset"].includes(entry.kind)) continue;
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
    const active = new Set((await this.current.session.files.state()).directories.filter(path => /^conversations\/[0-9]+$/.test(path)).map(path => Number(path.split("/")[1])));
    return new Map([...owners].filter(([, ids]) => ids.size === 1 && active.has([...ids][0]!)).map(([path, ids]) => [path, [...ids][0]!]));
  }
  private normalizedFile(file: ProfileFileRecord & { reference?: string }): ProfileFileRecord {
    const suffix = file.path.split("/").at(-1)!.split(".").slice(1).at(-1) ?? "";
    const extension = new TextEncoder().encode(suffix).length <= 32 ? suffix : "";
    const id = file.id.startsWith("file-") ? file.id : file.reference?.startsWith("artifacts/file-") ? file.reference.slice(10) : `file-${file.id}${extension ? "." + extension : ""}`;
    const { reference, ...record } = file;
    const aliases = [...new Set([...(file.aliases ?? []), file.id, ...(reference ? [reference, reference.split("/").at(-1)!] : [])])].filter(alias => alias !== id);
    return { ...record, id, aliases };
  }
  private route(id: ConversationId) {
    if (!this.attachments.has(id)) throw new Error("Native conversation is not attached");
  }
  private async fork(reference: ConversationReference, entryID: EntryId, title?: string) {
    const session = this.current.session;
    const id = session.conversations.id(reference);
    if (!Number.isSafeInteger(entryID) || entryID < 0) throw new Error("Invalid fork entry ID");
    if (title !== undefined && (typeof title !== "string" || title.length > 1024)) throw new Error("Invalid conversation title");
    await session.prepareConversation(reference);
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
      if (Array.isArray(agent.extensions)) agent.extensions = agent.extensions.map(name => name !== "ox-profile-files" && name.includes(":")
        ? `${name.slice(0, name.indexOf(":") + 1)}${alias}` : name);
      if (title !== undefined) (await tx.doc(ConversationPresentation, forkID)).title = title;
    } }, context);
    await session.files.createConversation(conversation.id);
    const forkReference = session.conversations.reference(conversation.id);
    return { conversationID: conversation.id, reference: forkReference };
  }
  private async recoveryPlan(inspection?: HarnessInspection, target?: ConversationReference): Promise<NativeRecoveryPlan> {
    const session = this.current.session;
    const current = inspection ?? await session.harness.inspect(context);
    const tasks = current.tasks.map(({ record }) => ({ reference: session.conversations.reference(record.conversationId), taskID: record.id }));
    const submissions = current.submissions.map(record => ({ reference: session.conversations.reference(record.conversationId),
      submissionID: record.id, ...(record.requestId === undefined ? {} : { requestID: record.requestId }) }));
    const ids = new Set([...tasks, ...submissions].map(({ reference }) => reference.conversationID));
    if (target) ids.add(session.conversations.id(target));
    const unconfigured: NativeRecoveryPlan["unconfigured"] = [];
    for (const id of ids) {
      let reason: string | undefined;
      const attachment = this.attachments.get(id);
      const config = attachment?.status === "attached" ? attachment.configuration : undefined;
      const agent = await session.harness.snapshot(AgentDoc, id, context);
      const metadata = (await session.harness.snapshot(ConversationApplicationMetadata, id, context))?.fields;
      if (!attachment) reason = "nativeRouteMissing";
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
    if (target && this.current.session.files.physical && (await this.current.session.files.state()).deletedConversations.includes(target.conversationID)) throw new Error("Conversation not found");
    const recovery = await this.recoveryPlan(undefined, target);
    if (recovery.unconfigured.length) {
      const missing = recovery.unconfigured.map(({ reference, reason }) => `${reference.profileID}/${reference.conversationID}: ${reason}`).join(", ");
      throw new Error(`Native Profile progress blocked before submit/resume: ${missing}. Call recoveryPlan, attach every recovered conversation with its saved native model configuration, then retry. No input was submitted.`);
    }
  }
  private async resumeExisting(reference: ConversationReference, submissionID?: SubmissionId, requestID?: string) {
    const session = this.current.session;
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
    const session = this.current.session;
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
    return native<ToolExecutionResult>("nativeTool", { conversationID: api.conversationId, reference: session.conversations.reference(api.conversationId),
      callID: api.callId, taskID: api.taskId, name, arguments: arguments_, assistantEntryID: input.assistant, assistant, toolCall: call,
      systemPrompt: getCurrentSystemPrompt(prefix), tools: getCurrentTools(prefix), contextMessages: prefix.filter(message => message.role !== "system") }, ctx.abortSignal);
  }
  private async fileReceipt(path: string) {
    const session = this.current.session;
    path = canonical(path);
    if (session.files.physical) {
      const file = await session.files.record(path, false);
      return file ? { ...file, file: { ...file, reference: file.id }, reference: { oxAttachment: file.id, oxProfileID: session.conversations.profileID } } : {};
    }
    if (!path.startsWith("artifacts/")) return {};
    const artifact = await session.harness.snapshot(LegacyProfileFile, legacyFilePath(path), context);
    return artifact?.path ? { ...artifact, artifact, reference: { oxAttachment: path.slice(10), oxProfileID: session.conversations.profileID } } : {};
  }
  private async fileList(prefix?: string, limit?: number, cursor?: string) {
    if (limit !== undefined && (!Number.isSafeInteger(limit) || limit < 1 || limit > 200)) throw new Error("Invalid file page size");
    if (cursor !== undefined && (limit === undefined || typeof cursor !== "string")) throw new Error("Invalid file cursor");
    const root = canonical(prefix?.endsWith("/") ? prefix.slice(0, -1) : prefix ?? "");
    const matching = (path: string) => !root || path === root || path.startsWith(`${root}/`);
    if (cursor !== undefined && (!matching(canonical(cursor)) || canonical(cursor) !== cursor)) throw new Error("File cursor belongs to another prefix");
    const listed = cursor !== undefined && this.fileListing?.root === root ? this.fileListing.files : await this.listedFiles(root);
    if (limit === undefined) return { files: listed };
    const remaining = cursor === undefined ? listed : listed.filter(file => file.path.localeCompare(cursor) > 0);
    const page = remaining.slice(0, limit);
    const next = remaining.length > limit ? page.at(-1)!.path : null;
    this.fileListing = next === null ? undefined : { root, files: listed };
    return { files: page, next };
  }
  private async listedFiles(root: string) {
    const session = this.current.session;
    const matching = (path: string) => !root || path === root || path.startsWith(`${root}/`);
    const index = session.files.physical ? (await session.harness.snapshot(ProfileIndex, context))?.files ?? {} : await session.files.index();
    const entries = Object.entries(index).filter(([path]) => matching(path));
    const files = await Promise.all(entries.map(async ([path, metadata]) => {
      const artifact = this.current.artifacts && path.startsWith("artifacts/") ? await session.harness.snapshot(LegacyProfileFile, path, context) : undefined;
      const file = artifact ? undefined : await session.harness.snapshot(ProfileFile, path, context);
      return { path, ...metadata, saved: artifact?.saved ?? file?.saved ?? false, ...(artifact ? { sha256: artifact.sha256 } : {}) };
    }));
    let listed = files;
    if (session.files.physical) {
      const working = (await session.files.listFiles(root)).filter(file => !file.hidden && matching(file.path)).map(file => ({ ...file, reference: file.id }));
      const physical = new Set(working.map(file => file.path));
      listed = [...files.filter(file => this.isDocument(file.path) && !physical.has(file.path)), ...working];
    }
    listed.sort((a, b) => a.path.localeCompare(b.path));
    return listed;
  }
  private documentPath(path: string) {
    const name = canonical(path);
    if (!["MEMORY.md", "SOUL.md", "skill-selections.json"].includes(name) && !name.startsWith("skills/")) throw new Error("Operation requires MEMORY.md, SOUL.md, skill-selections.json, or a skill file");
    return name;
  }
  private async fileSeed(path: string, text: string) {
    path = this.documentPath(path);
    if (typeof text !== "string") throw new Error("Profile documents require UTF-8 text");
    const size = new TextEncoder().encode(text).length;
    if (size > 200 * 1024) throw new Error("Profile document exceeds size limit");
    if (this.current.publicFiles && publicDocument(path)) return this.current.session.files.seedDocument(path, text);
    return this.current.session.harness.commit(async tx => {
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
    if (this.current.publicFiles) {
      await this.current.session.files.documentBatch(changes.filter(file => publicDocument(file.path)), deleted.filter(publicDocument));
      changes = changes.filter(file => !publicDocument(file.path)); deleted = deleted.filter(path => !publicDocument(path));
      if (!changes.length && !deleted.length) return;
    }
    await this.current.session.harness.commit(async tx => {
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
    if (this.current.session.files.physical) { await this.current.session.files.saved(path, saved); return; }
    if (!path.startsWith("artifacts/") || typeof saved !== "boolean") throw new Error("Saved flags require a legacy file and Boolean");
    legacyFilePath(path);
    await this.current.session.harness.commit(async tx => {
      const index = await tx.doc(ProfileIndex);
      if (!index.files[path]) throw new Error("File is not visible");
      if (this.current.artifacts) (await tx.doc(LegacyProfileFile, path, null)).saved = saved;
      else (await tx.doc(ProfileFile, path, null)).saved = saved;
    }, context);
  }
  private async adopt(file: FileRecord & { binary: boolean; saved: boolean }) {
    const { artifacts, session } = this.current;
    if (!artifacts || !file || typeof file.binary !== "boolean" || typeof file.saved !== "boolean" || !Number.isSafeInteger(file.size) || file.size < 0 || file.size > (file.binary ? 32 * 1024 * 1024 : 200 * 1024)) throw new Error("Invalid file-backed adoption");
    validateFileRecord(file, file.path, file.size);
    const bytes = await artifacts.read(file);
    if (!file.binary) new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    await artifacts.flush(file.path);
    await session.harness.commit(async tx => {
      const record = await tx.doc(LegacyProfileFile, file.path, null);
      const index = await tx.doc(ProfileIndex);
      if (record.path) throw new Error("Legacy file references are immutable; choose a distinct filename");
      if (Object.keys(index.files).length >= 10_000) throw new Error("Profile file count limit reached");
      Object.assign(record, file);
      index.files[file.path] = { size: file.size, mtime: Date.now(), binary: file.binary };
    }, context);
  }

  private async attach(config: Config, reference: ConversationReference) {
    if (!config) throw new Error("Native configuration required");
    const prompt = composeIOSPrompt(config.promptState, config.isolatedFiles);
    if (config.toolExecutionMode !== undefined && !["parallel", "sequential"].includes(config.toolExecutionMode)) throw new Error("Invalid tool execution mode");
    if (config.providerID !== undefined && (typeof config.providerID !== "string" || !config.providerID)) throw new Error("Invalid native credential provider ID");
    if (config.thinkingLevel != null && !["off", "minimal", "low", "medium", "high", "xhigh", "max"].includes(config.thinkingLevel)) throw new Error("Invalid Pi thinking level");
    if (config.nativeReasoningEffort != null && typeof config.nativeReasoningEffort !== "string") throw new Error("Invalid native reasoning effort");
    const { session, application } = this.current;
    const conversation = await session.harness.conversation(session.conversations.id(reference), context);
    if (!conversation) throw new Error("Conversation not found");
    const metadata = await session.conversations.metadata(reference);
    let alias = metadata.agent?.model?.provider;
    if (!alias?.startsWith("ox-native:") && !metadata.record?.parent) {
      const loaded = await application.load(reference);
      const assistant = loaded?.entries.flatMap(entry => entry.model ?? []).find(message => message.role === "assistant" && message.provider.startsWith("ox-native:"));
      alias = assistant?.role === "assistant" ? assistant.provider : undefined;
    }
    alias = alias?.startsWith("ox-native:") ? alias : `ox-native:${reference.profileID}:${conversation.id}`;
    const extensions = metadata.agent?.extensions;
    const extensionName = Array.isArray(extensions) ? extensions.find(name => name !== "ox-profile-files") : undefined;
    const stream = (model: Model<Api>, transcript: Parameters<typeof nativeStream>[2], options?: Parameters<typeof nativeStream>[3]) => nativeStream(reference, model, transcript, options);
    const previous = this.attachments.get(conversation.id);
    if (previous) this.attachments.set(conversation.id, { status: "attaching" });
    this.providerRoutes.set(alias, conversation.id);
    this.models.setProvider(createProvider({ id: alias, auth: { apiKey: { name: "Native credentials", resolve: async () => ({ auth: {} }) } },
      models: [{ id: config.model, provider: alias, api: "ox-native", name: config.model, baseUrl: "", reasoning: config.reasoning,
        input: ["text"], contextWindow: config.contextWindow, maxTokens: config.maxTokens,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }], api: { stream, streamSimple: stream } }));
    const sections = Object.entries(prompt.sections).map(([key, text]) => section(key, () => text, { tag: false }));
    if (session.files.physical) sections.push(section("working_directory", () => `Your working directory is conversations/${conversation.id}/. Relative file paths resolve there. Use / for the Profile root and absolute paths such as /reports/report.md for shared files. Mounted resource paths such as skills/ and services/ remain Profile-relative.`, { tag: false }));
    const extension = defineExtension({ name: extensionName ?? `ox-conversation:${alias.slice(10)}`, sections,
      tools: config.tools.map(tool => defineTool({ ...tool, replay: "unsafe", executionMode: config.toolExecutionMode === "sequential" ? "sequential" : tool.executionMode ?? config.toolExecutionMode ?? "sequential",
        execute: async (arguments_, api, ctx) => this.executeNativeTool(tool.name, arguments_, api, ctx) })) });
    session.registry.install(extension);
    this.attachments.set(conversation.id, { status: "attaching" });
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
      await session.files.createConversation(conversation.id);
      await session.observe(reference);
      const saved = (await session.harness.snapshot(ConversationApplicationMetadata, conversation.id, context))?.fields;
      this.attachments.set(conversation.id, { status: "attached", configuration: { provider: alias, modelId: config.model,
        scope: config.promptState.hostContext ? { ...config.promptState.hostContext.active } : undefined,
        thinkingLevel: config.thinkingLevel === undefined ? metadata.agent?.thinkingLevel ?? "off" : config.thinkingLevel ?? "off",
        nativeProviderID: config.providerID ?? (typeof saved?.nativeProviderID === "string" ? saved.nativeProviderID : undefined),
        nativeReasoningEffort: config.nativeReasoningEffort === undefined ? typeof saved?.nativeReasoningEffort === "string" ? saved.nativeReasoningEffort : undefined : config.nativeReasoningEffort ?? undefined } });
      return { conversationID: conversation.id, reference };
    } catch (error) {
      if (previous) this.attachments.set(conversation.id, { status: "attaching" }); else this.attachments.delete(conversation.id);
      throw error;
    }
  }
}
