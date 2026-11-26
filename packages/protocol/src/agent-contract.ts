import { Type, type Static, type TSchema } from "typebox";

export const AGENT_PROTOCOL_VERSION = 1;
export const AGENT_DEFAULT_PORT = 9878;

const S = Type.String;
const B = Type.Boolean;
const I = Type.Integer;
const A = Type.Array;
const R = (name: string) => Type.Ref(name);
const optional = (schema: TSchema) => Type.Optional(schema);
const nullable = (schema: TSchema) => optional(Type.Union([schema, Type.Null()]));
const object = <P extends Record<string, TSchema>>(name: string, properties: P, options = {}) =>
  Type.Object(properties, { $id: name, additionalProperties: true, ...options });
const json = () => Type.Unknown();
const conversationId = () => S({ minLength: 1, maxLength: 200 });

export const AgentSchemas = {
  AgentEmptyRequest: object("AgentEmptyRequest", {}, { additionalProperties: false }),
  AgentEmptyResult: object("AgentEmptyResult", {}),
  AgentContext: object("AgentContext", {
    sections: Type.Record(S(), S(), { description: "Ox system prompt and per-turn sections keyed by section tag, applied with pi's section diffing." }),
  }),
  AgentTool: object("AgentTool", { name: S(), description: S(), parameters: json() }),
  AgentDescription: object("AgentDescription", {
    implementation: Type.Object({ name: S(), version: S() }),
    machine: S(), folder: S(), folders: A(S(), { description: "Allowed workspace roots; new conversations may use any of them or a descendant." }),
    protocols: Type.Record(S(), A(I({ minimum: 1 }))), methods: A(S()),
  }),
  AgentModel: object("AgentModel", {
    provider: S(), id: S(), name: S(), reasoning: B(), contextWindow: optional(I()), maxTokens: optional(I()),
  }),
  AgentModelsResult: object("AgentModelsResult", { models: A(R("AgentModel")), current: nullable(R("AgentModelRef")) }),
  AgentModelRef: object("AgentModelRef", { provider: S(), id: S() }),
  AgentConversationRow: object("AgentConversationRow", {
    id: conversationId(), title: S(), cwd: S(),
    state: Type.Union([Type.Literal("idle"), Type.Literal("running")]),
    origin: Type.Union([Type.Literal("terminal"), Type.Literal("ox")]), updatedAt: S(),
  }),
  AgentConversationsResult: object("AgentConversationsResult", { conversations: A(R("AgentConversationRow")) }),
  AgentNewRequest: object("AgentNewRequest", {
    cwd: nullable(S({ minLength: 1, maxLength: 4096 })), model: nullable(R("AgentModelRef")), thinkingLevel: nullable(S()), context: R("AgentContext"), tools: A(R("AgentTool")),
  }),
  AgentNewResult: object("AgentNewResult", { id: conversationId(), model: nullable(R("AgentModelRef")) }),
  AgentOpenRequest: object("AgentOpenRequest", {
    id: conversationId(), context: R("AgentContext"), tools: A(R("AgentTool")),
    since: optional(I({ minimum: 0, description: "Replay buffered conversations.event notifications with seq greater than this before live events." })),
  }),
  AgentOpenResult: object("AgentOpenResult", {
    messages: A(json(), { description: "pi-ai messages as returned by pi's get_messages." }),
    state: Type.Union([Type.Literal("idle"), Type.Literal("running")]), model: nullable(R("AgentModelRef")),
    thinkingLevel: nullable(S()), title: nullable(S()), seq: I({ minimum: 0, description: "Latest event seq for this conversation." }),
    replay: optional(Type.Union([Type.Literal("complete"), Type.Literal("gap")], { description: "Whether every event after since was still buffered." })),
  }),
  AgentConversationRequest: object("AgentConversationRequest", { id: conversationId() }),
  AgentSendRequest: object("AgentSendRequest", {
    id: conversationId(), text: S(), images: optional(A(Type.Object({ data: S(), mimeType: S() }))),
    delivery: optional(Type.Union([Type.Literal("prompt"), Type.Literal("steer"), Type.Literal("followUp")])),
    context: optional(R("AgentContext")),
  }),
  AgentSendResult: object("AgentSendResult", { disposition: S() }),
  AgentRespondRequest: object("AgentRespondRequest", {
    id: conversationId(), promptId: S(), value: optional(S()), confirmed: optional(B()), cancelled: optional(B()),
  }),
  AgentSetModelRequest: object("AgentSetModelRequest", { id: conversationId(), provider: S(), model: S() }),
  AgentSetThinkingRequest: object("AgentSetThinkingRequest", { id: conversationId(), level: S() }),
  AgentRenameRequest: object("AgentRenameRequest", { id: conversationId(), title: S({ maxLength: 1024 }) }),
  AgentEventNotification: object("AgentEventNotification", {
    id: conversationId(), seq: I({ minimum: 1 }), event: json(),
  }, { description: "One pi RPC session event (agent_start, agent_settled, turn_*, message_*, tool_execution_*, compaction_*, queue_update, ...), unchanged." }),
  AgentPromptNotification: object("AgentPromptNotification", {
    id: conversationId(), promptId: S(),
    method: Type.Union([Type.Literal("confirm"), Type.Literal("select"), Type.Literal("input"), Type.Literal("editor")]),
    title: S(), message: optional(S()), options: optional(A(S())), placeholder: optional(S()), prefill: optional(S()),
    toolCallId: optional(S()), timeout: optional(I()),
  }),
  AgentChangedNotification: object("AgentChangedNotification", {
    id: conversationId(), state: Type.Union([Type.Literal("idle"), Type.Literal("running"), Type.Literal("exited")]),
    title: nullable(S()), error: optional(S()),
  }),
  AgentToolCallRequest: object("AgentToolCallRequest", { id: conversationId(), toolCallId: S(), name: S(), args: json() }),
  AgentToolCallResult: object("AgentToolCallResult", {
    content: A(json(), { description: "pi-ai tool result content blocks: {type:text,text} or {type:image,data,mimeType}." }),
    isError: B(),
  }),
  AgentToolProgressNotification: object("AgentToolProgressNotification", { id: conversationId(), toolCallId: S(), message: S() }),
};

type AgentSchemaName = keyof typeof AgentSchemas;
const method = (params: AgentSchemaName, result: AgentSchemaName) => ({ params, result });
const notification = (params: AgentSchemaName) => ({ params });

export const AgentMethods = {
  "agent.describe": method("AgentEmptyRequest", "AgentDescription"),
  "models.list": method("AgentEmptyRequest", "AgentModelsResult"),
  "conversations.list": method("AgentEmptyRequest", "AgentConversationsResult"),
  "conversations.new": method("AgentNewRequest", "AgentNewResult"),
  "conversations.open": method("AgentOpenRequest", "AgentOpenResult"),
  "conversations.close": method("AgentConversationRequest", "AgentEmptyResult"),
  "conversations.send": method("AgentSendRequest", "AgentSendResult"),
  "conversations.stop": method("AgentConversationRequest", "AgentEmptyResult"),
  "conversations.respond": method("AgentRespondRequest", "AgentEmptyResult"),
  "conversations.setModel": method("AgentSetModelRequest", "AgentEmptyResult"),
  "conversations.setThinking": method("AgentSetThinkingRequest", "AgentEmptyResult"),
  "conversations.compact": method("AgentConversationRequest", "AgentEmptyResult"),
  "conversations.rename": method("AgentRenameRequest", "AgentEmptyResult"),
} as const;

export const AgentNotifications = {
  "conversations.event": notification("AgentEventNotification"),
  "conversations.prompt": notification("AgentPromptNotification"),
  "conversations.changed": notification("AgentChangedNotification"),
  "tools.progress": notification("AgentToolProgressNotification"),
} as const;

export const AgentHostRequests = {
  "tools.call": method("AgentToolCallRequest", "AgentToolCallResult"),
} as const;

export const AgentRequiredMethods = [
  "agent.describe", "conversations.list", "conversations.new", "conversations.open", "conversations.send",
  "conversations.stop", "conversations.respond",
] as const satisfies readonly (keyof typeof AgentMethods)[];

export type AgentMethodName = keyof typeof AgentMethods;
export type AgentContext = Static<typeof AgentSchemas.AgentContext>;
export type AgentTool = Static<typeof AgentSchemas.AgentTool>;
export type AgentDescription = Static<typeof AgentSchemas.AgentDescription>;
export type AgentModel = Static<typeof AgentSchemas.AgentModel>;
export type AgentModelRef = Static<typeof AgentSchemas.AgentModelRef>;
export type AgentConversationRow = Static<typeof AgentSchemas.AgentConversationRow>;
export type AgentNewRequest = Static<typeof AgentSchemas.AgentNewRequest>;
export type AgentOpenRequest = Static<typeof AgentSchemas.AgentOpenRequest>;
export type AgentOpenResult = Static<typeof AgentSchemas.AgentOpenResult>;
export type AgentSendRequest = Static<typeof AgentSchemas.AgentSendRequest>;
export type AgentRespondRequest = Static<typeof AgentSchemas.AgentRespondRequest>;
export type AgentPromptNotification = Static<typeof AgentSchemas.AgentPromptNotification>;
export type AgentChangedNotification = Static<typeof AgentSchemas.AgentChangedNotification>;
export type AgentToolCallRequest = Static<typeof AgentSchemas.AgentToolCallRequest>;
export type AgentToolCallResult = Static<typeof AgentSchemas.AgentToolCallResult>;
