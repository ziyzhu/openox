import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Models, AssistantMessage } from "@earendil-works/pi-ai";
import { Harness, createRegistry, watchEvents, type AgentEvent, type AgentEventStream, type ConversationId,
  type Conversation, type HarnessSettings, type InputSubmissionDraft, type Registry, type Submission, type SubmissionId } from "@earendil-works/pi-durable";
import { SqliteStorage, type SqliteDatabase } from "@earendil-works/pi-durable/storage/sqlite";
import { applyChanges } from "./committed-partial";
import { ProfileFiles } from "./profile-files";
import type { ArtifactFiles } from "./artifacts";
import { profileEnv } from "./profile-env";
import { OxConversations, type ConversationReference } from "./conversations";
import { profileTools, type AuthorizeFile } from "./file-tools";

const context = BACKGROUND_CONTEXT;
export type CommittedEvent = AgentEvent & { partial?: AssistantMessage };
export interface SessionOptions {
  database: SqliteDatabase;
  profileID: string;
  models: Models;
  registry?: Registry;
  settings?: HarnessSettings;
  artifacts?: ArtifactFiles;
  /** Only for the explicitly retained, purgeable SQLite-blob fixtures. */
  createBlobID?(): Promise<string>;
  authorizeFile: AuthorizeFile;
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

/** One Profile scope. Pi owns execution; this object owns adapters and committed presentation. */
export class OxAgentSession {
  readonly files: ProfileFiles;
  readonly conversations: OxConversations;
  readonly env: ReturnType<typeof profileEnv>;
  private projections = new Map<ConversationId, Projection>();
  private attaching = new Map<ConversationId, Promise<void>>();
  private closing?: Promise<void>;
  private constructor(readonly harness: Harness, readonly registry: Registry, private options: SessionOptions) {
    this.files = new ProfileFiles(harness, options.database, options.profileID, options.createBlobID, options.artifacts);
    this.conversations = new OxConversations(options.profileID, harness, () => this.ready());
    this.env = profileEnv(this.files, this.conversations);
  }

  static async open(options: SessionOptions) {
    const registry = options.registry ?? createRegistry();
    let session: OxAgentSession | undefined;
    let harness: Harness | undefined;
    try {
      harness = await Harness.open(await SqliteStorage.open(options.database), { models: options.models, registry,
        settings: options.settings, env: () => session!.env, onReport: options.onReport }, context);
      session = new OxAgentSession(harness, registry, options);
      await session.files.initialize();
      registry.install(profileTools(session.files, options.authorizeFile));
      return session;
    } catch (error) {
      try { if (harness) await harness.close(context); else await options.database.close(); }
      finally { await options.artifacts?.close(); }
      throw error;
    }
  }

  private ready() { if (this.closing) throw new Error("Session closed or closing"); }
  private async conversation(id: ConversationId) {
    this.ready();
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
    return { inspection: await this.harness.inspect(context), files: await this.files.index(), usage: await this.harness.usage(context),
      streamEnds: Object.fromEntries([...this.projections].filter(([, projection]) => projection.ending).map(([id, projection]) => [id, projection.ending])),
      messages: id === undefined ? undefined : (await (await this.conversation(id)).context(context)).messages };
  }

  close(): Promise<void> {
    if (!this.closing) this.closing = (async () => {
      await this.files.flush();
      await Promise.allSettled(this.attaching.values());
      await this.harness.close(context);
      await this.files.close();
      await Promise.all([...this.projections.values()].map(projection => projection.stream.closed));
      this.projections.clear();
    })();
    return this.closing;
  }
}

export const openOxAgentSession = (options: SessionOptions) => OxAgentSession.open(options);
