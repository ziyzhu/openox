import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Models, Message } from "@earendil-works/pi-ai";
import { Harness, createRegistry, type ConversationView, type ConversationWatch, type WatchCall, type LiveState, type InboxState, type SettledSubmissionRecord, type ConversationId,
  type Conversation, type EntryDraft, type HarnessSettings, type InputSubmissionDraft, type Registry, type Submission, type SubmissionId } from "@earendil-works/pi-durable";
import { SqliteStorage, type SqliteDatabase } from "@earendil-works/pi-durable/storage/sqlite";
import { ProfileFiles } from "./files";
import type { FilePayloadStore } from "./file-payloads";
import { profileMounts } from "./filesystem";
import { mountedFileSystem, type FileMount, type TextFileMount } from "../core/file-mounts";
import { bundledSkills } from "../core/bundled-skills";
import { OxConversations, type ConversationReference } from "./conversations";
import { ConversationIndexer } from "./conversation-index";
import { profileTools } from "./tools";
import { AgentFileSystem } from "../core/filesystem";
import { type ProfileFileBackend, type ProfileFileRecord } from "./file-store";
import type { FileRecord } from "./file-record";

const context = BACKGROUND_CONTEXT;
export type ConversationUpdate = Extract<WatchCall<ConversationView>, { kind: "value" }>;
export interface ProfileRuntimeOptions {
  database: SqliteDatabase;
  profileID: string;
  models: Models;
  registry?: Registry;
  settings?: HarnessSettings;
  filePayloads?: FilePayloadStore;
  fileStorage?: { kind: "physical" | "prepare"; backend: ProfileFileBackend; publicFiles?: boolean };
  mounts?: readonly FileMount[];
  /** Only for the explicitly retained, purgeable SQLite-blob fixtures. */
  createBlobID?(): Promise<string>;
  decodeConversation?(sources: Record<string, FileRecord>, files: ProfileFileRecord[]): Promise<{ entries: EntryDraft[]; expectedContext: Message[]; payloads: FileRecord[] }>;
  beforeProgress?(reference: ConversationReference): Promise<void>;
  onView?(conversationId: ConversationId, update: ConversationUpdate): Promise<void>;
  onReport?(error: unknown): void;
}
interface Projection {
  stream: ConversationWatch;
  delivered: ConversationView;
  ending?: string;
  waiter?: { receipt?: SettledSubmissionRecord; resolve(): void; reject(error: Error): void };
}
function settleProjection(projection: Projection) {
  const receipt = projection.waiter?.receipt;
  if (!receipt) return;
  const live = projection.delivered.docs["pi.live"] as LiveState | undefined;
  const inbox = projection.delivered.docs["pi.inbox"] as InboxState | undefined;
  const newest = projection.delivered.entries.at(-1)?.id ?? projection.delivered.before ?? 0;
  const delivered = receipt.status === "done"
    ? newest >= (receipt.answer ?? receipt.entry ?? 0)
    : live?.runFailure?.inputs.includes(receipt.id)
      || (newest >= (receipt.entry ?? 0) && !live?.run?.inputs.includes(receipt.id) && !inbox?.items.some(item => item.id === receipt.id));
  if (delivered) projection.waiter!.resolve();
}

export class ProfileRuntime {
  readonly files: ProfileFiles;
  readonly filesystem = new AgentFileSystem();
  readonly conversations: OxConversations;
  readonly index: ConversationIndexer;
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
    this.files = new ProfileFiles(harness, options.database, options.profileID, options.createBlobID, options.filePayloads,
      options.fileStorage?.kind === "prepare" ? "prepare" : options.fileStorage ? "physical" : "legacy", options.fileStorage?.backend, options.fileStorage?.publicFiles);
    this.conversations = new OxConversations(options.profileID, harness, () => this.ready(), reference => this.prepareConversation(reference));
    this.index = new ConversationIndexer(harness, options.profileID, error => options.onReport?.(error));
    const mounts = profileMounts(this.files, this.conversations);
    this.env = mountedFileSystem(options.profileID, [...mounts, ...options.mounts ?? []]);
  }

  static async open(options: ProfileRuntimeOptions) {
    const registry = options.registry ?? createRegistry();
    let runtime: ProfileRuntime | undefined;
    let harness: Harness | undefined;
    try {
      harness = await Harness.open(await SqliteStorage.open(options.database), { models: options.models, registry,
        settings: options.settings, env: () => runtime!.env, onReport: report => options.onReport?.(report.error) }, context);
      runtime = new ProfileRuntime(harness, registry, options);
      await runtime.files.initialize();
      registry.install(profileTools(runtime.files, runtime.files.physical));
      return runtime;
    } catch (error) {
      try { if (harness) await harness.close(context); else await options.database.close(); }
      finally { await options.filePayloads?.close(); await options.fileStorage?.backend.close(); }
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
    if (this.files.physical && (await this.files.state()).deletedConversations.includes(id)) throw new Error("Conversation not found");
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
    const stream = await conversation.watch(context);
    const projection: Projection = { stream, delivered: stream.value };
    this.projections.set(id, projection);
    try {
      await this.options.onView?.(id, { kind: "value", value: stream.value, ops: [], retired: false });
    } catch (error) {
      this.projections.delete(id);
      await stream.stop();
      throw error;
    }
    stream.start(async update => {
      if (update.kind === "failed") throw update.error;
      await this.options.onView?.(id, update);
      projection.delivered = update.value;
      settleProjection(projection);
    });
    void stream.closed.then(end => {
      projection.ending = end.kind;
      projection.waiter?.reject(end.kind === "listener_error" ? end.error : new Error(`Conversation projection closed: ${end.kind}`));
      if (end.kind === "listener_error") {
        this.options.onReport?.(end.error);
        void (async () => {
          await this.options.beforeProgress?.(this.conversations.reference(id));
          await conversation.abort(context);
        })().catch(error => this.options.onReport?.(error));
      }
    });
  }

  private async observedSubmission(reference: ConversationId | ConversationReference,
    acquire: (conversation: Conversation, id: ConversationId) => Promise<Submission>) {
    const id = this.scopedID(reference);
    const conversation = await this.conversation(id);
    await this.observe(id);
    const projection = this.projections.get(id)!;
    if (projection.ending) throw new Error(`Conversation projection closed: ${projection.ending}`);
    if (projection.waiter) throw new Error("Conversation already has an observed run");
    const observed = new Promise<void>((resolve, reject) => { projection.waiter = { resolve, reject }; });
    void observed.catch(() => {});
    try {
      const submission = await acquire(conversation, id);
      const observation = this.harness.observeCommits({
        advance: publication => {
          for (const change of publication.changes) {
            if (change.type === "submission" && change.value.id === submission.id
              && (change.value.status === "done" || change.value.status === "unanswered")) {
              projection.waiter!.receipt = change.value;
              settleProjection(projection);
            }
          }
        },
        end: end => {
          if (end.kind === "failed" || end.kind === "listener_error") {
            projection.waiter?.reject(end.error instanceof Error ? end.error : new Error(String(end.error)));
          }
        },
      });
      try {
        const status = await submission.status(context);
        if (status.status === "done" || status.status === "unanswered") projection.waiter!.receipt = status;
        this.harness.resume();
        settleProjection(projection);
        await observed;
        return { receipt: projection.waiter!.receipt!, messages: (await conversation.context(context)).messages.filter(message => message.role !== "system") };
      } finally { observation.detach(); }
    } finally { projection.waiter = undefined; }
  }

  async run(reference: ConversationId | ConversationReference, input: InputSubmissionDraft) {
    return this.observedSubmission(reference, async (conversation, id) => {
      await this.options.beforeProgress?.(this.conversations.reference(id));
      const submission = await conversation.submit(input, context);
      return submission;
    });
  }

  async resumeExisting(reference: ConversationId | ConversationReference, submissionID: SubmissionId) {
    return this.observedSubmission(reference, async (_, id) => {
      const submission = await this.harness.submission(submissionID, context);
      if (!submission) throw new Error("Existing submission not found");
      const existing = await submission.status(context);
      if (existing.conversationId !== id) throw new Error("Submission conversation scope mismatch");
      await this.options.beforeProgress?.(this.conversations.reference(id));
      return submission;
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
      await this.index.close();
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
