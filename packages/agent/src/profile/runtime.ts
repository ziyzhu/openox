import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Models, AssistantMessage, Message } from "@earendil-works/pi-ai";
import { Harness, createRegistry, watchEvents, type AgentEvent, type AgentEventStream, type ConversationId,
  type Conversation, type EntryDraft, type HarnessSettings, type InputSubmissionDraft, type Registry, type Submission, type SubmissionId } from "@earendil-works/pi-durable";
import { SqliteStorage, type SqliteDatabase } from "@earendil-works/pi-durable/storage/sqlite";
import { applyChanges } from "./committed-partial";
import { ProfileFiles } from "./files";
import type { FilePayloadStore } from "./file-payloads";
import { profileMounts } from "./filesystem";
import { mountedFileSystem, type FileMount, type TextFileMount } from "../core/file-mounts";
import { bundledSkills } from "../core/bundled-skills";
import { OxConversations, type ConversationReference } from "./conversations";
import { profileTools } from "./tools";
import { AgentFileSystem } from "../core/filesystem";
import { type ProfileFileBackend, type ProfileFileRecord } from "./file-store";
import type { FileRecord } from "./file-record";

const context = BACKGROUND_CONTEXT;
export type CommittedEvent = AgentEvent & { partial?: AssistantMessage };
export interface ProfileRuntimeOptions {
  database: SqliteDatabase;
  profileID: string;
  models: Models;
  registry?: Registry;
  settings?: HarnessSettings;
  artifacts?: FilePayloadStore;
  fileStorage?: { kind: "physical" | "prepare"; backend: ProfileFileBackend; publicFiles?: boolean };
  mounts?: readonly FileMount[];
  /** Only for the explicitly retained, purgeable SQLite-blob fixtures. */
  createBlobID?(): Promise<string>;
  decodeConversation?(sources: Record<string, FileRecord>, files: ProfileFileRecord[]): Promise<{ entries: EntryDraft[]; expectedContext: Message[]; payloads: FileRecord[] }>;
  beforeProgress?(reference: ConversationReference): Promise<void>;
  onEvents?(conversationId: ConversationId, events: CommittedEvent[]): Promise<void>;
  onReport?(error: unknown): void;
}
interface Projection {
  stream: AgentEventStream;
  pending: Set<SubmissionId>;
  partial?: AssistantMessage;
  ending?: string;
  waiter?: { id?: SubmissionId; delivered: Set<SubmissionId>; resolve(): void; reject(error: Error): void };
}

export class ProfileRuntime {
  readonly files: ProfileFiles;
  readonly filesystem = new AgentFileSystem();
  readonly conversations: OxConversations;
  readonly env: ReturnType<typeof mountedFileSystem>;
  get skillPackages() {
    this.ready();
    return { scope: this.options.profileID, skills: bundledSkills };
  }
  get textMounts(): { scope: string; mounts: TextFileMount[] } {
    this.ready();
    return { scope: this.options.profileID, mounts: this.env.mounts.flatMap(mount => mount.source.kind === "text"
      ? [{ path: mount.path, access: "readOnly" as const, files: mount.source.files }] : []) };
  }
  private preparedConversations = new Set<ConversationId>();
  private preparingConversations = new Map<ConversationId, Promise<void>>();
  private projections = new Map<ConversationId, Projection>();
  private attaching = new Map<ConversationId, Promise<void>>();
  private closing?: Promise<void>;
  readonly harness: Harness;
  readonly registry: Registry;
  private options: ProfileRuntimeOptions;

  private constructor(harness: Harness, registry: Registry, options: ProfileRuntimeOptions) {
    this.harness = harness;
    this.registry = registry;
    this.options = options;
    this.files = new ProfileFiles(harness, options.database, options.profileID, options.createBlobID, options.artifacts,
      options.fileStorage?.kind === "prepare" ? "prepare" : options.fileStorage ? "physical" : "legacy", options.fileStorage?.backend, options.fileStorage?.publicFiles);
    this.conversations = new OxConversations(options.profileID, harness, () => this.ready(), reference => this.prepareConversation(reference));
    const mounts = profileMounts(this.files, this.conversations);
    this.env = mountedFileSystem(options.profileID, [...mounts, ...options.mounts ?? []]);
  }

  static async open(options: ProfileRuntimeOptions) {
    const registry = options.registry ?? createRegistry();
    let runtime: ProfileRuntime | undefined;
    let harness: Harness | undefined;
    try {
      harness = await Harness.open(await SqliteStorage.open(options.database), { models: options.models, registry,
        settings: options.settings, env: () => runtime!.env, onReport: options.onReport }, context);
      runtime = new ProfileRuntime(harness, registry, options);
      await runtime.files.initialize();
      registry.install(profileTools(runtime.files, runtime.files.physical));
      return runtime;
    } catch (error) {
      try { if (harness) await harness.close(context); else await options.database.close(); }
      finally { await options.artifacts?.close(); await options.fileStorage?.backend.close(); }
      throw error;
    }
  }

  private ready() { if (this.closing) throw new Error("Profile runtime closed or closing"); }
  async prepareConversation(reference: ConversationReference) {
    const id = this.conversations.id(reference);
    if (this.preparedConversations.has(id)) return;
    let pending = this.preparingConversations.get(id);
    if (!pending) {
      pending = this.decodeConversation(id).then(() => { this.preparedConversations.add(id); })
        .finally(() => this.preparingConversations.delete(id));
      this.preparingConversations.set(id, pending);
    }
    await pending;
  }

  private async decodeConversation(id: ConversationId) {
    if ((await this.files.state()).deletedConversations.includes(id)) throw new Error("Conversation not found");
    const conversation = await this.harness.conversation(id, context);
    if (!conversation) throw new Error("Conversation not found");
    const nativeEntries: EntryDraft[] = [];
    let hasModel = false;
    let cursor;
    let newest: number | null = null;
    do {
      const page = await conversation.entries({}, 100, cursor, context);
      newest ??= page.items[0]?.id ?? null;
      for (const entry of page.items) {
        if (entry.kind === "ox.native.metadata") return;
        hasModel ||= !!entry.model?.length;
        if (["ox.native.conversation", "ox.native.transcript", "ox.native.context"].includes(entry.kind)) nativeEntries.push({ kind: entry.kind, data: entry.data });
      }
      cursor = page.next;
    } while (cursor);
    if (!nativeEntries.some(entry => entry.kind === "ox.native.conversation")) return;
    if (hasModel) throw new Error("Native conversation already contains model history without canonical metadata");
    const sources: Record<string, FileRecord> = {};
    for (const entry of nativeEntries) {
      const key = ({ "ox.native.conversation": "metadata", "ox.native.transcript": "transcript", "ox.native.context": "checkpoint" } as Record<string, string>)[entry.kind]!;
      const source = entry.data && typeof entry.data === "object" && !Array.isArray(entry.data) ? entry.data.source : undefined;
      if (!source || typeof source !== "object" || Array.isArray(source) || typeof source.path !== "string"
        || typeof source.size !== "number" || !Number.isSafeInteger(source.size) || source.size < 0 || typeof source.sha256 !== "string"
        || source.path !== `artifacts/payload-${source.sha256}.json` || !/^[0-9a-f]{64}$/.test(source.sha256)) throw new Error("Invalid native conversation source");
      if (sources[key]) throw new Error("Duplicate native conversation source");
      sources[key] = { path: source.path, size: source.size, sha256: source.sha256 };
    }
    if (!this.options.decodeConversation || !this.options.fileStorage) throw new Error("Native conversation decoder is unavailable");
    const decoded = await this.options.decodeConversation(sources, Object.values((await this.files.state()).files));
    if (!decoded.entries.length || decoded.entries[0]?.kind !== "ox.native.metadata"
      || decoded.entries.some(entry => !entry.kind || (entry.head !== undefined && entry.head !== "self") || entry.edits !== undefined)
      || !Array.isArray(decoded.expectedContext) || !Array.isArray(decoded.payloads)) throw new Error("Invalid decoded conversation");
    const payloads: ProfileFileRecord[] = [];
    for (const file of decoded.payloads) {
      if (!Number.isSafeInteger(file.size) || file.size < 0 || !/^[0-9a-f]{64}$/.test(file.sha256)
        || file.path !== `artifacts/payload-${file.sha256}.json`) throw new Error("Invalid decoded conversation payload");
      await this.options.fileStorage.backend.verify(file);
      payloads.push({ ...file, path: `payloads/${file.path.slice(10)}`, aliases: [file.path],
        id: `file-${await this.options.fileStorage.backend.identifier()}.json`, binary: true, saved: false, mtime: 0, owner: id, hidden: true });
    }
    await this.files.publishConversation(id, [...decoded.entries, { kind: "pi.reset", head: "self", model: decoded.expectedContext }], payloads, newest);
  }

  private async conversation(id: ConversationId) {
    this.ready();
    await this.prepareConversation(this.conversations.reference(id));
    if (this.files.physical && (await this.files.state()).deletedConversations.includes(id)) throw new Error("Conversation not found");
    const conversation = await this.harness.conversation(id, context);
    if (!conversation) throw new Error("Conversation not found");
    return conversation;
  }

  /** Numeric IDs remain the low-level Pi/UUID-adapter compatibility path, not application references. */
  private scopedID(reference: ConversationId | ConversationReference) {
    return this.conversations.id(typeof reference === "number" ? { profileID: this.options.profileID, conversationID: reference } : reference);
  }

  async observe(reference: ConversationId | ConversationReference) {
    const id = this.scopedID(reference);
    if (this.projections.has(id)) return;
    let attachment = this.attaching.get(id);
    if (!attachment) {
      attachment = this.attach(id).finally(() => this.attaching.delete(id));
      this.attaching.set(id, attachment);
    }
    return attachment;
  }

  private async attach(id: ConversationId) {
    const conversation = await this.conversation(id);
    if (this.projections.has(id)) return;
    const stream = await watchEvents(this.harness, id, context);
    const projection: Projection = { stream, pending: new Set([...(stream.snapshot.run?.inputs ?? []), ...stream.snapshot.inbox.map(({ id }) => id)]),
      partial: stream.snapshot.generation?.message ? structuredClone(stream.snapshot.generation.message) : undefined };
    this.projections.set(id, projection);
    stream.start(async events => {
      if (events.some(event => event.type === "snapshot")) {
        throw new Error("Committed event overflow requires snapshot rehydration; this isolated rollout cannot continue safely");
      }
      const enriched = events.map(event => {
        if (event.type === "message_start" && event.message.role === "assistant") projection.partial = structuredClone(event.message);
        if (event.type === "message_update" && projection.partial) {
          applyChanges(projection.partial, event);
          return { ...event, partial: structuredClone(projection.partial) };
        }
        return event;
      });
      for (const event of events) if (event.type === "submission") projection.pending.add(event.record.id);
      await this.options.onEvents?.(id, enriched);
      const waiter = projection.waiter;
      for (const event of events) {
        if (event.type === "submission" && (event.record.status === "done" || event.record.status === "unanswered")) {
          projection.pending.delete(event.record.id);
          waiter?.delivered.add(event.record.id);
        }
      }
      if (waiter?.id !== undefined && waiter.delivered.has(waiter.id)) waiter.resolve();
    });
    void stream.closed.then(end => {
      projection.ending = end.reason;
      projection.waiter?.reject(end.reason === "listener_error" ? end.error : new Error(`Committed projection closed: ${end.reason}`));
      if (end.reason === "listener_error") {
        this.options.onReport?.(end.error);
        // A projection failure must stop unobserved effects; orderly close never uses abort.
        void (async () => {
          await this.options.beforeProgress?.(this.conversations.reference(id));
          await conversation.abort(context);
        })().catch(error => this.options.onReport?.(error));
      }
    });
  }

  private async observedSubmission(reference: ConversationId | ConversationReference,
    acquire: (conversation: Conversation, id: ConversationId) => Promise<{ submission: Submission; settled: boolean }>) {
    const id = this.scopedID(reference);
    const conversation = await this.conversation(id);
    await this.observe(id);
    const projection = this.projections.get(id)!;
    if (projection.ending) throw new Error(`Committed projection closed: ${projection.ending}`);
    if (projection.waiter) throw new Error("Conversation already has an observed run");
    const observed = new Promise<void>((resolve, reject) => { projection.waiter = { delivered: new Set(), resolve, reject }; });
    void observed.catch(() => {});
    try {
      const { submission, settled } = await acquire(conversation, id);
      projection.waiter!.id = submission.id;
      if (projection.waiter!.delivered.has(submission.id)) projection.waiter!.resolve();
      const receipt = await submission.wait(context);
      if (!settled || projection.pending.has(submission.id)) await observed;
      return { receipt, messages: (await conversation.context(context)).messages.filter(message => message.role !== "system") };
    } finally { projection.waiter = undefined; }
  }

  async run(reference: ConversationId | ConversationReference, input: InputSubmissionDraft) {
    return this.observedSubmission(reference, async (conversation, id) => {
      const existing = input.requestId === undefined ? undefined : await this.harness.commit(
        tx => tx.submissionByRequest(id, input.requestId!), context);
      await this.options.beforeProgress?.(this.conversations.reference(id));
      const submission = await conversation.submit(input, context);
      return { submission, settled: existing?.status === "done" || existing?.status === "unanswered" };
    });
  }

  async resumeExisting(reference: ConversationId | ConversationReference, submissionID: SubmissionId) {
    return this.observedSubmission(reference, async (_, id) => {
      const submission = await this.harness.submission(submissionID, context);
      if (!submission) throw new Error("Existing submission not found");
      const existing = await submission.status(context);
      if (existing.conversationId !== id) throw new Error("Submission conversation scope mismatch");
      await this.options.beforeProgress?.(this.conversations.reference(id));
      return { submission, settled: existing.status === "done" || existing.status === "unanswered" };
    });
  }

  async abort(reference: ConversationId | ConversationReference) {
    const id = this.scopedID(reference);
    const conversation = await this.conversation(id);
    await this.options.beforeProgress?.(this.conversations.reference(id));
    await conversation.abort(context);
  }
  /** Diagnostic `messages` retains its active-context compatibility contract, not full scrollback. */
  async inspect(reference?: ConversationId | ConversationReference) {
    const id = reference === undefined ? undefined : this.scopedID(reference);
    this.ready();
    return { inspection: await this.harness.inspect(context), files: this.files.physical ? await this.files.listFiles() : await this.files.index(), usage: await this.harness.usage(context),
      streamEnds: Object.fromEntries([...this.projections].filter(([, projection]) => projection.ending).map(([id, projection]) => [id, projection.ending])),
      messages: id === undefined ? undefined : (await (await this.conversation(id)).context(context)).messages };
  }

  close(): Promise<void> {
    if (!this.closing) this.closing = (async () => {
      await this.filesystem.close();
      await Promise.allSettled(this.preparingConversations.values());
      await this.files.flush();
      await Promise.allSettled(this.attaching.values());
      await this.harness.close(context);
      await this.env.cleanup(context);
      await this.files.close();
      await Promise.all([...this.projections.values()].map(projection => projection.stream.closed));
      this.projections.clear();
    })();
    return this.closing;
  }
}

export const openProfileRuntime = (options: ProfileRuntimeOptions) => ProfileRuntime.open(options);
