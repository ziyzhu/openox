import { Type, type Static, type TSchema } from "typebox";

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
const swift = (schema: TSchema, name: string) => Object.assign(schema, { "x-swift-type": name });
const json = () => swift(Type.Unknown(), "JSONValue");
const data = () => swift(S({ contentEncoding: "base64" }), "Data");
const opaque = (name: string, description: string) => object(name, {}, { description });

// Domain payloads remain owned by their existing codecs, not a new persisted format.
export const Schemas = {
  EmptyRequest: object("EmptyRequest", {}, { additionalProperties: false }),
  // Experimental DEBUG Simulator commands. Native controllers own bounded domain validation.
  DurableCommandParameters: object("DurableCommandParameters", { caseID: S(), action: S() }),
  DurableCommandResult: opaque("DurableCommandResult", "Experimental cache-only Pi Durable command result."),
  ProfileRequest: object("ProfileRequest", { profileId: S({ minLength: 36, maxLength: 36 }) }),
  CreateProfileRequest: object("CreateProfileRequest", { name: S({ minLength: 1, maxLength: 100 }) }),
  UpdateProfileRequest: object("UpdateProfileRequest", {
    profileId: S({ minLength: 36, maxLength: 36 }), name: nullable(S({ minLength: 1, maxLength: 100 })),
    memory: nullable(S({ maxLength: 204800 })), soul: nullable(S({ maxLength: 204800 })),
  }),
  FolderProfileRequest: object("FolderProfileRequest", { profileId: nullable(S({ minLength: 36, maxLength: 36 })) }),
  FolderGrantRequest: object("FolderGrantRequest", { grantId: S({ minLength: 1, maxLength: 100 }), profileId: nullable(S({ minLength: 36, maxLength: 36 })) }),
  MountedRepositoryRequest: object("MountedRepositoryRequest", { path: S({ minLength: 1, maxLength: 2048 }) }),
  RepositoryIDRequest: object("RepositoryIDRequest", { repositoryId: S({ minLength: 1, maxLength: 100 }) }),
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
  NewConversationRequest: object("NewConversationRequest", { temporary: nullable(B()), providerId: nullable(S()), modelId: nullable(S()) }),
  SendConversationRequest: object("SendConversationRequest", { sessionId: nullable(S()), text: S(), wait: nullable(B()) }),
  RespondConversationRequest: object("RespondConversationRequest", { sessionId: nullable(S()), promptId: S(), answer: S() }),
  SetKeyRequest: object("SetKeyRequest", {
    providerId: S(), key: nullable(S()), region: nullable(swift(Type.Union([Type.Literal("global"), Type.Literal("china")]), "LLMRegion")),
  }),
  SetRegionRequest: object("SetRegionRequest", { region: S() }),
  BootstrapFileInput: object("BootstrapFileInput", { name: S(), data: data() }),
  BootstrapFilesRequest: object("BootstrapFilesRequest", { artifacts: A(R("BootstrapFileInput")) }),
  WriteFileRequest: object("WriteFileRequest", { name: S(), data: data() }),
  RestoreWebsiteDataRequest: object("RestoreWebsiteDataRequest", { data: data() }),
  SetAttachedServiceRequest: object("SetAttachedServiceRequest", { domain: nullable(S()), domains: nullable(A(S())) }),
  PromptRequest: object("PromptRequest", { prompt: S() }),
  RepositoryGateRequest: object("RepositoryGateRequest", { domain: S(), action: S() }),
  VMRequest: object("VMRequest", { sessionId: nullable(S()) }),
  VMFunctionsRequest: object("VMFunctionsRequest", { function: nullable(S()) }),
  VMCallRequest: object("VMCallRequest", { sessionId: nullable(S()), function: S(), arguments: json() }),
  VMEvalRequest: object("VMEvalRequest", { sessionId: nullable(S()), script: S() }),
  ProviderModel: opaque("ProviderModel", "Existing ProviderModel Codable payload; not a new model catalog format."),
  Message: opaque("Message", "Existing tagged Agent Message Codable payload."),
  Block: opaque("Block", "Existing transcript Block Codable payload."),
  ProfileRow: object("ProfileRow", { id: S(), name: S(), location: S(), version: S(), active: B() }),
  ListProfilesResult: object("ListProfilesResult", { profiles: A(R("ProfileRow")) }),
  ProfileResult: object("ProfileResult", { profile: R("ProfileRow"), memory: optional(S()), soul: optional(S()) }),
  FolderGrantRow: object("FolderGrantRow", { id: S(), name: S() }),
  ListFolderGrantsResult: object("ListFolderGrantsResult", { folders: A(R("FolderGrantRow")), unassignedFolders: optional(A(R("FolderGrantRow"))) }),
  FolderGrantResult: object("FolderGrantResult", { folder: R("FolderGrantRow") }),
  RepositoryRow: object("RepositoryRow", { id: S(), name: S(), provenance: S(), enabled: B(), state: S(), error: optional(S()) }),
  ListRepositoriesResult: object("ListRepositoriesResult", { repositories: A(R("RepositoryRow")) }),
  RepositoryResult: object("RepositoryResult", { repository: R("RepositoryRow") }),
  EmptyResult: object("EmptyResult", {}),
  HostDescription: object("HostDescription", {
    implementation: Type.Object({ name: S(), version: S(), build: S() }),
    protocols: Type.Record(S({ pattern: "^(.*)$" }), A(I({ minimum: 1 }))), methods: A(S()),
  }),
  ConversationRow: object("ConversationRow", {
    id: S(), title: S(), model: Type.Union([S(), Type.Null()]), createdAt: S(),
    lastActivity: Type.Union([S(), Type.Null()]), active: B(),
  }),
  ListConversationsResult: object("ListConversationsResult", { chats: A(R("ConversationRow")) }),
  ConversationTool: object("ConversationTool", { name: S(), description: S(), parameters: Type.Unknown(), strict: B() }),
  ConversationSnapshot: object("ConversationSnapshot", {
    id: S(), model: R("ProviderModel"), systemPrompt: S(), renderedSystemPrompt: S(), soul: S(), memory: S(),
    tools: A(R("ConversationTool")), messages: A(R("Message")), blocks: A(R("Block")),
    isBusy: optional(B()), pendingPrompt: optional(R("PendingConversationPrompt")),
  }),
  PendingConversationPrompt: object("PendingConversationPrompt", {
    id: S(), prompt: S(), options: A(S()), allowsCustomAnswer: B(), requiresApp: B(),
  }),
  RespondConversationResult: object("RespondConversationResult", { chatId: S(), promptId: S() }),
  GetConversationResult: object("GetConversationResult", { data: optional(R("ConversationSnapshot")) }),
  NewConversationResult: object("NewConversationResult", { chatId: S(), temporary: B(), model: S() }),
  SendConversationResult: object("SendConversationResult", { chatId: S(), outcome: S(), text: optional(S()), error: optional(S()) }),
  StopConversationResult: object("StopConversationResult", { chatId: S(), wasRunning: B() }),
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
  BootstrapFilesResult: object("BootstrapFilesResult", { artifacts: optional(A(S())) }),
  WebsiteDataResult: object("WebsiteDataResult", { data: optional(data()), bytes: optional(I()) }),
  RepositorySaveGateResult: object("RepositorySaveGateResult", { entered: optional(B()) }),
};

type SchemaName = keyof typeof Schemas;
const method = (swiftCase: string, params: SchemaName, result: SchemaName) => ({ swiftCase, params, result });
export const Methods = {
  "host.describe": method("describe", "EmptyRequest", "HostDescription"),
  "profiles.list": method("listProfiles", "EmptyRequest", "ListProfilesResult"),
  "profiles.inspect": method("inspectProfile", "ProfileRequest", "ProfileResult"),
  "profiles.create": method("createProfile", "CreateProfileRequest", "ProfileResult"),
  "profiles.select": method("selectProfile", "ProfileRequest", "ProfileResult"),
  "profiles.update": method("updateProfile", "UpdateProfileRequest", "ProfileResult"),
  "files.list": method("listFolderGrants", "FolderProfileRequest", "ListFolderGrantsResult"),
  "files.mount": method("mountFolder", "FolderProfileRequest", "FolderGrantResult"),
  "files.assign": method("assignFolder", "FolderGrantRequest", "EmptyResult"),
  "files.unmount": method("unmountFolder", "FolderGrantRequest", "EmptyResult"),
  "repositories.list": method("listRepositories", "EmptyRequest", "ListRepositoriesResult"),
  "repositories.connectFolder": method("connectRepositoryFolder", "MountedRepositoryRequest", "RepositoryResult"),
  "repositories.disconnectFolder": method("disconnectRepositoryFolder", "RepositoryIDRequest", "EmptyResult"),
  "debug.durable.storage": method("durableStorage", "DurableCommandParameters", "DurableCommandResult"),
  "debug.durable.chat": method("durableConversation", "DurableCommandParameters", "DurableCommandResult"),
  "services.invoke": method("invokeAction", "ActionRequest", "ValueResult"),
  "services.evaluate": method("evaluate", "EvaluateRequest", "ValueResult"),
  "services.reload": method("reloadService", "ServiceRequest", "ValueResult"),
  "services.refreshAuth": method("refreshServiceAuth", "ServiceRequest", "ValueResult"),
  "services.list": method("listServices", "EmptyRequest", "ListServicesResult"),
  "services.sync": method("syncServices", "EmptyRequest", "SyncServicesResult"),
  "chats.list": method("listConversations", "EmptyRequest", "ListConversationsResult"),
  "chats.get": method("getConversation", "SessionRequest", "GetConversationResult"),
  "chats.open": method("openConversation", "SessionRequest", "GetConversationResult"),
  "chats.respond": method("respondConversation", "RespondConversationRequest", "RespondConversationResult"),
  "chats.new": method("newConversation", "NewConversationRequest", "NewConversationResult"),
  "chats.send": method("sendConversation", "SendConversationRequest", "SendConversationResult"),
  "chats.stop": method("stopConversation", "SessionRequest", "StopConversationResult"),
  "providers.list": method("listProviders", "EmptyRequest", "ListProvidersResult"),
  "logs.list": method("getLogs", "GetLogsRequest", "GetLogsResult"),
  "debug.composer.formatting": method("getComposerFormatting", "EmptyRequest", "ComposerFormattingResult"),
  "debug.repositories.saveGate": method("repositoryGate", "RepositoryGateRequest", "RepositorySaveGateResult"),
  "vm.inspect": method("vmInspect", "VMRequest", "VMControlResult"),
  "vm.functions": method("vmFunctions", "VMFunctionsRequest", "VMControlResult"),
  "vm.call": method("vmCall", "VMCallRequest", "VMControlResult"),
  "vm.eval": method("vmEval", "VMEvalRequest", "VMControlResult"),
  "debug.artifacts.bootstrap": method("bootstrapFiles", "BootstrapFilesRequest", "BootstrapFilesResult"),
  "debug.artifacts.write": method("writeFile", "WriteFileRequest", "EmptyResult"),
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
  params: optional(Type.Union([Type.Record(S({ pattern: "^(.*)$" }), Type.Unknown()), A(Type.Unknown(), { maxItems: 0 })])),
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
export type HostConversationRow = Static<typeof Schemas.ConversationRow>;
