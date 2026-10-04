import { Type, type TObject, type TProperties } from "@sinclair/typebox";
import { join } from "node:path";
import { ROOT, checkGenerated, writeGenerated, type Generated } from "./lib.ts";

const object = <T extends TProperties>(properties: T): TObject<T> => Type.Object(properties, { additionalProperties: false });
const text = () => Type.String({ minLength: 1, maxLength: 2048 });
const id = () => Type.String({ minLength: 1, maxLength: 200, pattern: "^[a-zA-Z0-9][a-zA-Z0-9._:@/-]*$" });
const strings = () => Type.Array(text(), { uniqueItems: true, maxItems: 100 });
const stringMap = () => Type.Object({}, { additionalProperties: Type.String() });
const modality = Type.Union(["text", "image", "pdf", "audio", "video"].map(value => Type.Literal(value)));
const oauthCommon = {
  kind: Type.Literal("oauth"),
  clientID: text(),
  scopes: Type.Optional(strings()),
  tokenURL: text(),
  requestEncoding: Type.Optional(Type.Union([Type.Literal("form"), Type.Literal("json")])),
};

const AuthSchema = Type.Union([
  object({ kind: Type.Literal("none") }),
  object({ kind: Type.Literal("bearer"), optional: Type.Optional(Type.Boolean()) }),
  object({ kind: Type.Literal("api-key"), header: text(), optional: Type.Optional(Type.Boolean()) }),
  object({ ...oauthCommon, flow: Type.Literal("authorization-code"), authorizeURL: text(), redirectURI: text(), authorizeParams: Type.Optional(stringMap()) }),
  object({ ...oauthCommon, flow: Type.Literal("device-code"), deviceAuthorizationURL: text() }),
  object({ kind: Type.Literal("custom"), adapter: id() }),
]);

const ModelSchema = object({
  id: text(),
  name: text(),
  wireID: Type.Optional(text()),
  contextTokens: Type.Optional(Type.Integer({ minimum: 1 })),
  outputTokens: Type.Optional(Type.Integer({ minimum: 1 })),
  input: Type.Optional(Type.Array(modality, { uniqueItems: true, minItems: 1 })),
  output: Type.Optional(Type.Array(modality, { uniqueItems: true, minItems: 1 })),
  reasoningEfforts: Type.Optional(strings()),
  options: Type.Optional(object({
    serviceTier: Type.Optional(text()),
    adaptiveThinking: Type.Optional(Type.Boolean()),
    replayReasoning: Type.Optional(Type.Boolean()),
  })),
});

const common = {
  id: id(),
  name: text(),
  url: text(),
  auth: AuthSchema,
  models: Type.Array(ModelSchema, { maxItems: 1000 }),
};
const requestOptions = {
  headers: Type.Optional(stringMap()),
  extraBody: Type.Optional(Type.Object({}, { additionalProperties: Type.Unknown() })),
};

const ProviderSchema = Type.Union([
  object({ ...common, api: Type.Literal("openai-chat-completions"), options: Type.Optional(object({
    ...requestOptions,
    maxTokensField: Type.Optional(Type.Union([Type.Literal("max_tokens"), Type.Literal("max_completion_tokens")])),
    reasoningFormat: Type.Optional(Type.Union(["provider-default", "reasoning_effort", "reasoning_object", "disable-reasoning", "disable-thinking", "disable-chat-template", "disable-qwen"].map(value => Type.Literal(value)))),
    reasoningEffort: Type.Optional(Type.Union(["none", "minimal", "low"].map(value => Type.Literal(value)))),
    cachesSystemPrompt: Type.Optional(Type.Boolean()),
    cacheRouting: Type.Optional(Type.Union([Type.Literal("x-session-id"), Type.Literal("prompt_cache_key")])),
  })) }),
  object({ ...common, api: Type.Literal("openai-responses"), options: Type.Optional(object({
    ...requestOptions,
    sessionHeader: Type.Optional(text()),
    reasoningEffort: Type.Optional(Type.Union(["none", "minimal", "low"].map(value => Type.Literal(value)))),
    streaming: Type.Optional(Type.Union([Type.Literal("sse"), Type.Literal("websocket-with-sse-fallback")])),
    accountHeader: Type.Optional(text()),
  })) }),
  object({ ...common, api: Type.Literal("anthropic-messages"), options: Type.Optional(object({
    ...requestOptions,
    version: Type.Optional(text()),
    beta: Type.Optional(strings()),
  })) }),
  object({ ...common, api: Type.Literal("gemini-generate-content"), options: Type.Optional(object(requestOptions)) }),
  object({ ...common, api: Type.Literal("web") }),
]);

const providerSchemaPath = join(ROOT, "apps/ios/Ox/Host/ModelProviders/provider-definition.schema.json");

export const generated = (): Generated => ({
  [providerSchemaPath]: `${JSON.stringify(ProviderSchema, (key, value) => {
    if (key === "const") return undefined;
    if (value && typeof value === "object" && "const" in value) return { ...value, enum: [value.const] };
    return value;
  }, 2)}\n`,
});

export async function check(): Promise<string> {
  await checkGenerated(generated(), "build:provider-schema");
  return "provider schema";
}

if (import.meta.main) await writeGenerated(generated());
