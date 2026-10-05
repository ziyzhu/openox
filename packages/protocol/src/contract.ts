import { Type, type Static, type TSchema } from "@sinclair/typebox";

export const RPC_VERSION = 1;
const S = Type.String;
const B = Type.Boolean;
const I = Type.Integer;
const A = Type.Array;
const R = (name: string) => Type.Ref(name);
const optional = (schema: TSchema) => Type.Optional(schema);
// Swift decodeIfPresent accepts both omission and explicit null.
const nullable = (schema: TSchema) => optional(Type.Union([schema, Type.Null()]));
const object = <P extends Record<string, TSchema>>(name: string, properties: P, options = {}) =>
  Type.Object(properties, { $id: name, additionalProperties: true, ...options });
const swift = (schema: TSchema, name: string) => ({ ...schema, "x-swift-type": name });
const json = () => swift(Type.Unknown(), "JSONValue");
const data = () => swift(S({ contentEncoding: "base64" }), "Data");
const opaque = (name: string, description: string) => object(name, {}, { description });

// Domain payloads remain owned by their existing codecs, not a new persisted format.
export const Schemas = {
  EmptyRequest: object("EmptyRequest", {}, { additionalProperties: false }),
  // Experimental DEBUG Simulator commands. Native controllers own bounded domain validation.
  DurableCommandParameters: object("DurableCommandParameters", { caseID: S(), action: S() }),
  DurableCommandResult: opaque("DurableCommandResult", "Experimental cache-only Pi Durable command result."),
  SessionRequest: object("SessionRequest", { sessionId: nullable(S()) }),
  GetLogsRequest: object("GetLogsRequest", {
    limit: nullable(I({ minimum: 1, maximum: 2000 })), cursor: nullable(S({ minLength: 1, maxLength: 2048 })),
    level: nullable(S({ enum: ["debug", "info", "warning", "error"] })),
    category: nullable(S({ minLength: 1, maxLength: 80 })), query: nullable(S({ minLength: 1, maxLength: 200 })),
    since: nullable(S({ minLength: 1, maxLength: 40 })),
  }),
  ActionRequest: object("ActionRequest", { domain: S(), action: S(), args: nullable(json()), approve: nullable(B()) }),
  EvaluateRequest: object("EvaluateRequest", { domain: S(), script: S() }),
  ServiceRequest: object("ServiceRequest", { domain: S() }),
  NewChatRequest: object("NewChatRequest", { temporary: nullable(B()), providerId: nullable(S()), modelId: nullable(S()) }),
  SendChatRequest: object("SendChatRequest", { sessionId: nullable(S()), text: S(), wait: nullable(B()) }),
  RespondChatRequest: object("RespondChatRequest", { sessionId: nullable(S()), promptId: S(), answer: S() }),
  SetKeyRequest: object("SetKeyRequest", {
    providerId: S(), key: nullable(S()), region: nullable(swift(Type.Union([Type.Literal("global"), Type.Literal("china")]), "LLMRegion")),
  }),
  SetRegionRequest: object("SetRegionRequest", { region: S() }),
  BootstrapArtifactInput: object("BootstrapArtifactInput", { name: S(), data: data() }),
  BootstrapArtifactsRequest: object("BootstrapArtifactsRequest", { artifacts: A(R("BootstrapArtifactInput")) }),
  WriteArtifactRequest: object("WriteArtifactRequest", { name: S(), data: data() }),
  RestoreWebsiteDataRequest: object("RestoreWebsiteDataRequest", { data: data() }),
  SetAttachedServiceRequest: object("SetAttachedServiceRequest", { domain: nullable(S()), domains: nullable(A(S())) }),
  PromptRequest: object("PromptRequest", { prompt: S() }),
  RepositoryGateRequest: object("RepositoryGateRequest", { domain: S(), action: S() }),
  VMRequest: object("VMRequest", { sessionId: nullable(S()) }),
  VMFunctionsRequest: object("VMFunctionsRequest", { function: nullable(S()) }),
  VMCallRequest: object("VMCallRequest", { sessionId: nullable(S()), function: S(), arguments: json() }),
  VMEvalRequest: object("VMEvalRequest", { sessionId: nullable(S()), script: S() }),
  EvaluateAgentRequest: object("EvaluateAgentRequest", {
    sessionId: S(), providerId: S(), modelId: S(), prompts: A(S()), fixtures: A(R("AgentEvalFixture")), maxTurns: I(), timeoutMs: I(),
  }),
  AgentEvalFixture: object("AgentEvalFixture", { tool: S(), sourceIncludes: A(S()), text: S(), isError: B(), terminate: B() }),
  ProviderModel: opaque("ProviderModel", "Existing ProviderModel Codable payload; not a new model catalog format."),
  Message: opaque("Message", "Existing tagged Agent Message Codable payload."),
  Block: opaque("Block", "Existing transcript Block Codable payload."),
  EmptyResult: object("EmptyResult", {}),
  HostDescription: object("HostDescription", {
    implementation: Type.Object({ name: S(), version: S(), build: S() }),
    protocols: Type.Record(S(), A(I({ minimum: 1 }))), methods: A(S()),
  }),
  ChatRow: object("ChatRow", {
    id: S(), title: S(), model: Type.Union([S(), Type.Null()]), createdAt: S(),
    lastActivity: Type.Union([S(), Type.Null()]), active: B(),
  }),
  ListChatsResult: object("ListChatsResult", { chats: A(R("ChatRow")) }),
  ChatTool: object("ChatTool", { name: S(), description: S(), parameters: Type.Unknown(), strict: B() }),
  ChatSnapshot: object("ChatSnapshot", {
    id: S(), model: R("ProviderModel"), systemPrompt: S(), renderedSystemPrompt: S(), soul: S(), memory: S(),
    tools: A(R("ChatTool")), messages: A(R("Message")), blocks: A(R("Block")),
    isBusy: optional(B()), pendingPrompt: optional(R("PendingChatPrompt")),
  }),
  PendingChatPrompt: object("PendingChatPrompt", {
    id: S(), prompt: S(), options: A(S()), allowsCustomAnswer: B(), requiresApp: B(),
  }),
  RespondChatResult: object("RespondChatResult", { chatId: S(), promptId: S() }),
  GetChatResult: object("GetChatResult", { data: optional(R("ChatSnapshot")) }),
  NewChatResult: object("NewChatResult", { chatId: S(), temporary: B(), model: S() }),
  SendChatResult: object("SendChatResult", { chatId: S(), outcome: S(), text: optional(S()), error: optional(S()) }),
  StopChatResult: object("StopChatResult", { chatId: S(), wasRunning: B() }),
  ValueResult: object("ValueResult", { value: Type.Unknown() }),
  VMLog: object("VMLog", { level: S(), message: S() }),
  VMControlResult: object("VMControlResult", { value: optional(Type.Unknown()), logs: optional(A(R("VMLog"))) }),
  PageRow: object("PageRow", { url: Type.Unknown(), title: Type.Unknown(), isLoading: B(), progress: Type.Number(), canGoBack: B(), canGoForward: B() }),
  ServiceRow: object("ServiceRow", {
    domain: S(), title: S(), phase: S(), navigation: S(), activeInvocations: I(), queuedInvocations: I(),
    pendingEvaluations: I(), pageCount: I(), signIn: S(), page: optional(R("PageRow")), manifest: optional(Type.Unknown()), favicon: optional(S()),
  }),
  ListServicesResult: object("ListServicesResult", { services: A(R("ServiceRow")) }),
  SyncServicesResult: object("SyncServicesResult", { head: Type.Unknown(), changed: A(S()), services: I() }),
  ModelRow: object("ModelRow", {
    id: S(), providerModelID: S(), variant: optional(S()), displayName: S(), maxTokens: I(), maxContext: I(),
    supportsTools: B(), reasoning: B(), reasoningEfforts: A(S()), selectedReasoningEffort: optional(S()),
    inputModalities: A(S()), outputModalities: A(S()), wireProtocol: optional(S()),
  }),
  ProviderRow: object("ProviderRow", {
    id: S(), displayName: S(), regions: A(S()), supportsTools: B(), reasoningPolicy: S(), promptCacheRouting: optional(S()),
    maxTokensField: optional(S()), credentialID: S(), endpoint: optional(S()), models: A(R("ModelRow")),
  }),
  ListProvidersResult: object("ListProvidersResult", { region: S(), providers: A(R("ProviderRow")) }),
  LogRow: object("LogRow", { seq: I(), time: S(), level: S(), category: S(), thread: S(), location: S(), message: S() }),
  GetLogsResult: object("GetLogsResult", { logs: A(R("LogRow")), nextCursor: optional(S()), hasMore: optional(B()) }),
  ComposerFormattingResult: object("ComposerFormattingResult", {
    text: S(), hasForegroundColor: B(), visibleHasOrangeForeground: B(), visibleHasPrimaryForeground: B(), visibleHasMarkedText: B(),
  }),
  BootstrapArtifactsResult: object("BootstrapArtifactsResult", { artifacts: optional(A(S())) }),
  WebsiteDataResult: object("WebsiteDataResult", { data: optional(data()), bytes: optional(I()) }),
  RepositorySaveGateResult: object("RepositorySaveGateResult", { entered: optional(B()) }),
  EvalTool: object("EvalTool", { name: S(), description: S(), parameters: Type.Unknown() }),
  EvaluateAgentResult: object("EvaluateAgentResult", {
    messages: A(R("Message")), systemPrompt: S(), tools: A(R("EvalTool")), temperature: optional(Type.Number()), maxTokens: optional(I()),
    totalMs: I(), errors: A(S()), executionError: optional(S()),
  }),
};

type SchemaName = keyof typeof Schemas;
const method = (swiftCase: string, params: SchemaName, result: SchemaName) => ({ swiftCase, params, result });
export const Methods = {
  "host.describe": method("describe", "EmptyRequest", "HostDescription"),
  "debug.durable.storage": method("durableStorage", "DurableCommandParameters", "DurableCommandResult"),
  "debug.durable.chat": method("durableChat", "DurableCommandParameters", "DurableCommandResult"),
  "services.invoke": method("invokeAction", "ActionRequest", "ValueResult"),
  "services.evaluate": method("evaluate", "EvaluateRequest", "ValueResult"),
  "services.reload": method("reloadService", "ServiceRequest", "ValueResult"),
  "services.refreshAuth": method("refreshServiceAuth", "ServiceRequest", "ValueResult"),
  "services.list": method("listServices", "EmptyRequest", "ListServicesResult"),
  "services.sync": method("syncServices", "EmptyRequest", "SyncServicesResult"),
  "chats.list": method("listChats", "EmptyRequest", "ListChatsResult"),
  "chats.get": method("getChat", "SessionRequest", "GetChatResult"),
  "chats.open": method("openChat", "SessionRequest", "GetChatResult"),
  "chats.respond": method("respondChat", "RespondChatRequest", "RespondChatResult"),
  "chats.new": method("newChat", "NewChatRequest", "NewChatResult"),
  "chats.send": method("sendChat", "SendChatRequest", "SendChatResult"),
  "chats.stop": method("stopChat", "SessionRequest", "StopChatResult"),
  "providers.list": method("listProviders", "EmptyRequest", "ListProvidersResult"),
  "logs.list": method("getLogs", "GetLogsRequest", "GetLogsResult"),
  "debug.composer.formatting": method("getComposerFormatting", "EmptyRequest", "ComposerFormattingResult"),
  "debug.repositories.saveGate": method("repositoryGate", "RepositoryGateRequest", "RepositorySaveGateResult"),
  "agents.evaluate": method("evaluateAgent", "EvaluateAgentRequest", "EvaluateAgentResult"),
  "vm.inspect": method("vmInspect", "VMRequest", "VMControlResult"),
  "vm.functions": method("vmFunctions", "VMFunctionsRequest", "VMControlResult"),
  "vm.call": method("vmCall", "VMCallRequest", "VMControlResult"),
  "vm.eval": method("vmEval", "VMEvalRequest", "VMControlResult"),
  "debug.artifacts.bootstrap": method("bootstrapArtifacts", "BootstrapArtifactsRequest", "BootstrapArtifactsResult"),
  "debug.artifacts.write": method("writeArtifact", "WriteArtifactRequest", "EmptyResult"),
  "debug.websiteData.export": method("exportWebsiteData", "EmptyRequest", "WebsiteDataResult"),
  "debug.websiteData.restore": method("restoreWebsiteData", "RestoreWebsiteDataRequest", "WebsiteDataResult"),
  "debug.providers.setKey": method("setKey", "SetKeyRequest", "EmptyResult"),
  "debug.region.set": method("setRegion", "SetRegionRequest", "EmptyResult"),
  "debug.chats.attachServices": method("setAttachedService", "SetAttachedServiceRequest", "EmptyResult"),
  "debug.composer.setDraft": method("setComposerDraft", "PromptRequest", "EmptyResult"),
  "debug.composer.setMarkedText": method("setComposerMarkedText", "PromptRequest", "EmptyResult"),
  "debug.pasteboard.setImage": method("setPasteboardImage", "EmptyRequest", "EmptyResult"),
  "debug.pasteboard.setRichText": method("setPasteboardRichText", "PromptRequest", "EmptyResult"),
  "debug.share.stageNote": method("stageSharedNote", "PromptRequest", "EmptyResult"),
  "debug.chat.setEditDraft": method("setEditDraft", "PromptRequest", "EmptyResult"),
} as const;

const id = Type.Union([S(), Type.Number(), Type.Null()]);
export const RequestSchema = object("Request", {
  jsonrpc: Type.Literal("2.0"), id: optional(id), method: S(),
  params: optional(Type.Union([Type.Record(S(), Type.Unknown()), A(Type.Unknown(), { maxItems: 0 })])),
});
export const ErrorSchema = object("Error", { code: I(), message: S(), data: optional(Type.Unknown()) });
export const ResponseSchema = Type.Union([
  object("SuccessResponse", { jsonrpc: Type.Literal("2.0"), id, result: Type.Unknown(), error: optional(Type.Never()) }),
  object("ErrorResponse", { jsonrpc: Type.Literal("2.0"), id, error: ErrorSchema, result: optional(Type.Never()) }),
], { $id: "Response" });
export const RequestBatchSchema = A(RequestSchema, { $id: "RequestBatch", minItems: 1, maxItems: 64 });
export const ResponseBatchSchema = A(ResponseSchema, { $id: "ResponseBatch", minItems: 1 });

export type MethodName = keyof typeof Methods;
export type HostDescription = Static<typeof Schemas.HostDescription>;
export type HostChatRow = Static<typeof Schemas.ChatRow>;
