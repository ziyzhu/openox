import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Models, AssistantMessage } from "@earendil-works/pi-ai";
import { Harness, createRegistry, watchEvents, type AgentEvent, type AgentEventStream, type ConversationId,
  type Conversation, type HarnessSettings, type InputSubmissionDraft, type Registry, type Submission, type SubmissionId } from "@earendil-works/pi-durable";
import { SqliteStorage, type SqliteDatabase } from "@earendil-works/pi-durable/storage/sqlite";
import { applyChanges } from "./committed-partial";
import { ProfileFiles } from "./files";
import type { ArtifactFiles } from "./artifacts";
import { profileMounts } from "./filesystem";
import { mountedFileSystem, type FileMount, type TextFileMount } from "../core/file-mounts";
import { bundledSkills, skillActivationRequirements } from "../core/bundled-skills";
import { OxConversations, type ConversationReference } from "./conversations";
import { profileTools } from "./tools";
import { AgentFileSystem } from "../core/filesystem";
import { ProfileWorkspace, workspacePath, type WorkspaceBackend } from "./workspace";

const context = BACKGROUND_CONTEXT;
export type CommittedEvent = AgentEvent & { partial?: AssistantMessage };
export interface ProfileRuntimeOptions {
  database: SqliteDatabase;
  profileID: string;
  models: Models;
  registry?: Registry;
  settings?: HarnessSettings;
  artifacts?: ArtifactFiles;
  workspace?: boolean;
  workspaceBackend?: WorkspaceBackend;
  prepareWorkspace?: boolean;
  publicFiles?: boolean;
  mounts?: readonly FileMount[];
  /** Only for the explicitly retained, purgeable SQLite-blob fixtures. */
  createBlobID?(): Promise<string>;
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
  readonly workspace?: ProfileWorkspace;
  readonly filesystem = new AgentFileSystem();
  readonly conversations: OxConversations;
  readonly env: ReturnType<typeof mountedFileSystem>;
  get skillPackages() {
    this.ready();
    return { scope: this.options.profileID, skills: bundledSkills, activationRequirements: skillActivationRequirements };
  }
  get textMounts(): { scope: string; mounts: TextFileMount[] } {
    this.ready();
    return { scope: this.options.profileID, mounts: this.env.mounts.flatMap(mount => mount.source.kind === "text"
      ? [{ path: mount.path, access: "readOnly" as const, files: mount.source.files }] : []) };
  }
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
      options.prepareWorkspace ? "prepare" : options.workspace ? "workspace" : "legacy");
    this.conversations = new OxConversations(options.profileID, harness, () => this.ready());
    if (options.workspace || options.prepareWorkspace) {
      if (!options.workspaceBackend) throw new Error("Physical filesystem backend is required");
      if (options.workspace && !options.prepareWorkspace && options.artifacts) throw new Error("Current filesystem cannot use the legacy artifact backend");
      this.workspace = new ProfileWorkspace(harness, options.workspaceBackend, options.publicFiles);
      if (options.publicFiles) this.files.usePublicFiles(this.workspace);
    }
    const mounts = profileMounts(this.files, this.conversations);
    if (this.workspace) {
      const workspace = this.workspace;
      const backend = {
        id: `workspace:${options.profileID}`, assertWritable: workspacePath,
        info: (path: string) => workspace.info(path), list: (path: string) => workspace.list(path),
        read: (path: string) => workspace.read(path),
        write: async (path: string, content: string | Uint8Array, _context: unknown, expected?: string) => { await workspace.write(path, content, expected); },
        edit: (path: string, edits: { oldText: string; newText: string }[]) => workspace.edit(path, edits),
        remove: (path: string) => workspace.remove(path), flush: () => workspace.flush(),
        createDirectory: (path: string, _context: unknown, recursive?: boolean) => workspace.mkdir(path, recursive),
        removeDirectory: (path: string, recursive: boolean) => workspace.remove(path, true, recursive),
        move: (from: string, to: string) => workspace.move(from, to),
        copy: async (from: string, to: string) => { await workspace.copy(from, to); },
      };
      const history = mounts.find(mount => mount.path === "conversations");
      if (!history || history.source.kind !== "backend") throw new Error("Missing conversation history mount");
      mounts.splice(0, mounts.length, ...mounts.filter(mount => !["artifacts", "conversations"].includes(mount.path)),
        { ...history, path: "history", source: { ...history.source, path: "conversations" } },
        { path: "", access: "readWrite", source: { kind: "backend", backend } });
    }
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
      if (options.workspace && !options.prepareWorkspace) await runtime.workspace!.initialize();
      registry.install(profileTools(runtime.files, !!runtime.workspace));
      return runtime;
    } catch (error) {
      try { if (harness) await harness.close(context); else await options.database.close(); }
      finally { await options.artifacts?.close(); await options.workspaceBackend?.close(); }
      throw error;
    }
  }

  private ready() { if (this.closing) throw new Error("Profile runtime closed or closing"); }
  private async conversation(id: ConversationId) {
    this.ready();
    if (this.workspace && (await this.workspace.state()).deletedConversations.includes(id)) throw new Error("Conversation not found");
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
    return { inspection: await this.harness.inspect(context), files: this.workspace ? await this.workspace.listFiles() : await this.files.index(), usage: await this.harness.usage(context),
      streamEnds: Object.fromEntries([...this.projections].filter(([, projection]) => projection.ending).map(([id, projection]) => [id, projection.ending])),
      messages: id === undefined ? undefined : (await (await this.conversation(id)).context(context)).messages };
  }

  close(): Promise<void> {
    if (!this.closing) this.closing = (async () => {
      await this.filesystem.close();
      await this.files.flush();
      await this.workspace?.flush();
      await Promise.allSettled(this.attaching.values());
      await this.harness.close(context);
      await this.env.cleanup(context);
      await this.files.close();
      await this.options.workspaceBackend?.close();
      await Promise.all([...this.projections.values()].map(projection => projection.stream.closed));
      this.projections.clear();
    })();
    return this.closing;
  }
}

export const openProfileRuntime = (options: ProfileRuntimeOptions) => ProfileRuntime.open(options);
