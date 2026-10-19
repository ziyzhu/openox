import { Type, type Static } from "typebox";
import { Value } from "typebox/value";
import { dirname, resolve } from "node:path";

const object = <T extends Parameters<typeof Type.Object>[0]>(fields: T) => Type.Object(fields, { additionalProperties: false });
const text = Type.String({ maxLength: 200 * 1024 });
const id = Type.String({ pattern: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$" });
const credentialID = Type.String({ pattern: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$" });
const secretKey = Type.String({ pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$" });
const path = Type.String({ minLength: 1, maxLength: 1024 });
const secret = Type.Union([object({ env: Type.String({ pattern: "^[A-Za-z_][A-Za-z0-9_]*$" }) }), object({ fromFile: path })]);
const content = Type.Union([object({ text }), object({ fromFile: path })]);
const model = object({ provider: credentialID, model: Type.String({ minLength: 1 }), thinking: Type.Optional(Type.String()) });
const preference = Type.Cyclic({ Preference: Type.Union([
  Type.String(), Type.Boolean(), Type.Number(), Type.Array(Type.Ref("Preference")),
  object({ data: Type.String({ pattern: "^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$" }) }),
  object({ date: Type.String({ pattern: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$" }) }),
  object({ dictionary: Type.Record(Type.String(), Type.Ref("Preference")) }),
]) }, "Preference");
const defaults = object({ set: Type.Optional(Type.Record(Type.String({ minLength: 1 }), preference)), remove: Type.Optional(Type.Array(Type.String({ minLength: 1 }), { uniqueItems: true })) });
const file = object({ path, content });
const message = Type.Union([
  object({ role: Type.Literal("user"), text, attachments: Type.Optional(Type.Array(id)) }),
  object({ role: Type.Literal("assistant"), text, reasoning: Type.Optional(text) }),
]);
const conversation = object({
  id, title: Type.String({ maxLength: 60 }), model: Type.Optional(model),
  favorite: Type.Optional(Type.Boolean()), unread: Type.Optional(Type.Boolean()),
  messages: Type.Optional(Type.Array(message, { minItems: 1, maxItems: 10000 })),
  packageFrom: Type.Optional(path),
  files: Type.Optional(Type.Array(object({ id, name: Type.String({ minLength: 1, maxLength: 240 }), content }), { maxItems: 1000 })),
});

export const DeviceTemplateSchema = object({
  version: Type.Literal(1),
  settings: Type.Optional(object({
    language: Type.Optional(Type.Union([Type.Literal("system"), Type.Literal("en"), Type.Literal("zh-Hans")])),
    onboardingCompleted: Type.Optional(Type.Boolean()),
    region: Type.Optional(Type.Union([Type.Literal("global"), Type.Literal("china")])),
    defaultModel: Type.Optional(Type.Union([model, Type.Null()])),
    allowHostConnections: Type.Optional(Type.Boolean()),
  })),
  userDefaults: Type.Optional(object({ app: Type.Optional(defaults), appGroup: Type.Optional(defaults) })),
  keychain: Type.Optional(object({
    providers: Type.Optional(Type.Array(object({ provider: credentialID, secret }), { maxItems: 100 })),
    secrets: Type.Optional(Type.Array(object({ key: secretKey, name: Type.String({ minLength: 1, maxLength: 80 }), secret }), { maxItems: 100 })),
    bindings: Type.Optional(Type.Array(object({
      consumerKind: Type.Union([Type.Literal("provider"), Type.Literal("apiService"), Type.Literal("repositoryPublication")]),
      consumerID: Type.String({ minLength: 1 }), secretKey, destination: Type.String({ minLength: 1 }),
      configurationFingerprint: Type.String(), requiredFields: Type.Array(Type.String(), { uniqueItems: true }),
    }), { maxItems: 100 })),

    entries: Type.Optional(Type.Array(object({ account: Type.String({ minLength: 1 }), secret }), { maxItems: 100 })),
    removeProviders: Type.Optional(Type.Array(credentialID, { uniqueItems: true })),
    removeSecrets: Type.Optional(Type.Array(secretKey, { uniqueItems: true })),
    removeAccounts: Type.Optional(Type.Array(Type.String({ minLength: 1 }), { uniqueItems: true })),
  })),
  profiles: Type.Optional(Type.Array(object({
    id, name: Type.String({ minLength: 1, maxLength: 80, pattern: "^[^/:]+$" }),
    memory: Type.Optional(text), soul: Type.Optional(text),
    files: Type.Optional(Type.Array(file, { maxItems: 10000 })),
    conversations: Type.Optional(Type.Array(conversation, { maxItems: 1000 })),
  }), { maxItems: 100 })),
  websiteState: Type.Optional(object({ restoreFrom: path })),
  storage: Type.Optional(Type.Array(object({
    domain: Type.Union([Type.Literal("documents"), Type.Literal("applicationSupport"), Type.Literal("appGroup"), Type.Literal("caches")]),
    path, from: path,
    provenance: object({ build: Type.String({ minLength: 1 }), storageVersion: Type.String({ minLength: 1 }) }),
  }), { maxItems: 100 })),
  selection: Type.Optional(object({ profile: id, conversation: Type.Optional(id) })),
});

export type DeviceTemplate = Static<typeof DeviceTemplateSchema>;
export type PreparedTemplate = Omit<DeviceTemplate, "keychain" | "websiteState" | "storage" | "profiles"> & {
  runID: string;
  keychain?: {
    providers?: Array<{ provider: string; value: string }>;
    secrets?: Array<{ key: string; name: string; value: string }>;
    bindings?: NonNullable<DeviceTemplate["keychain"]>["bindings"];
    entries?: Array<{ account: string; value: string }>;
    removeProviders?: string[];
    removeSecrets?: string[];
    removeAccounts?: string[];
  };
  websiteState?: { data: string };
  profiles?: Array<Omit<NonNullable<DeviceTemplate["profiles"]>[number], "files" | "conversations"> & {
    files?: Array<{ path: string; data: string }>;
    conversations?: Array<Omit<NonNullable<NonNullable<DeviceTemplate["profiles"]>[number]["conversations"]>[number], "files" | "packageFrom"> & {
      packageData?: string;
      files?: Array<{ id: string; name: string; data: string }>;
    }>;
  }>;
};

export function relativeStoragePath(value: string): string {
  if (value.startsWith("/") || value.includes("\\") || value.includes("\0") || value.split("/").some(part => !part || part === "." || part === "..")) {
    throw new Error(`Invalid relative storage path: ${value}`);
  }
  return value;
}

function unique(values: string[], label: string): void {
  if (new Set(values).size !== values.length) throw new Error(`Duplicate ${label}`);
}

function validatePreference(value: Static<typeof preference>): void {
  if (Array.isArray(value)) value.forEach(validatePreference);
  else if (value && typeof value === "object") {
    if ("date" in value && new Date(value.date).toISOString().replace(".000Z", "Z") !== value.date) throw new Error("Invalid UserDefaults date");
    if ("dictionary" in value) Object.values(value.dictionary).forEach(validatePreference);
  }
}

export function parseTemplate(value: unknown): DeviceTemplate {
  if (!Value.Check(DeviceTemplateSchema, value)) {
    const error = Value.Errors(DeviceTemplateSchema, value)[0];
    throw new Error(`Invalid template at ${error?.instancePath || "/"}: ${error?.message ?? "schema mismatch"}`);
  }
  const template = value;
  const profiles = template.profiles ?? [];
  unique(profiles.map(profile => profile.id), "Profile ID");
  unique(profiles.map(profile => profile.name.toLowerCase()), "Profile name");
  for (const profile of profiles) {
    if (profile.name.trim() !== profile.name || [".", ".."].includes(profile.name)) throw new Error("Invalid Profile name");
    if ([profile.memory, profile.soul].some(text => text !== undefined && new TextEncoder().encode(text).length > 200 * 1024)) throw new Error("Profile document exceeds Ox's text size limit");
    unique((profile.files ?? []).map(file => relativeStoragePath(file.path)), "Profile file path");
    for (const file of profile.files ?? []) {
      if (/^(conversations|history|chats|MEMORY\.md|SOUL\.md)(\/|$)/.test(file.path)) throw new Error("Use conversation files or memory/soul fields for reserved Profile paths");
    }
    unique((profile.conversations ?? []).map(conversation => conversation.id), "conversation ID");
    for (const conversation of profile.conversations ?? []) {
      if ((conversation.messages !== undefined) === (conversation.packageFrom !== undefined) || conversation.packageFrom && conversation.files?.length) throw new Error("Conversation must declare messages or packageFrom, not both");
      const files = conversation.files ?? [];
      unique(files.map(file => file.id), "conversation file ID");
      unique(files.map(file => relativeStoragePath(file.name).toLowerCase()), "conversation filename");
      if (files.some(file => file.name.includes("/"))) throw new Error("Conversation filenames must be basenames");
      for (const message of conversation.messages ?? []) {
        if (message.role === "user" && message.attachments?.some(id => !files.some(file => file.id === id))) throw new Error("Unknown conversation attachment ID");
      }
    }
  }
  if (template.selection) {
    const profile = profiles.find(profile => profile.id === template.selection!.profile);
    if (!profile || template.selection.conversation && !profile.conversations?.some(conversation => conversation.id === template.selection!.conversation)) throw new Error("Unknown selection reference");
  }
  const settingsKeys = { language: ["app", "app.language"], onboardingCompleted: ["app", "app.hasCompletedOnboarding"], region: ["app", "app.region"], defaultModel: ["app", "llm.defaultModel"], allowHostConnections: ["app", "host.allowConnections"] } as const;
  for (const domain of ["app", "appGroup"] as const) {
    const defaults = template.userDefaults?.[domain];
    const keys = [...Object.keys(defaults?.set ?? {}), ...defaults?.remove ?? []];
    Object.values(defaults?.set ?? {}).forEach(validatePreference);
    unique(keys, "UserDefaults operation");
    for (const key of keys) {
      if (key === "storage.activeProfile" && template.selection) throw new Error("Conflicting Profile selection and raw active Profile preference");
      for (const [setting, [owner, preference]] of Object.entries(settingsKeys)) {
        if (domain === owner && key === preference && setting in (template.settings ?? {})) throw new Error(`Conflicting setting and UserDefaults key: ${key}`);
      }
    }
  }
  unique((template.keychain?.providers ?? []).map(item => item.provider), "provider credential");
  unique((template.keychain?.entries ?? []).map(item => item.account), "Keychain account");
  unique((template.keychain?.secrets ?? []).map(item => item.key), "named secret");
  unique((template.keychain?.bindings ?? []).map(item => item.consumerKind + ":" + item.consumerID), "credential binding");
  unique([...(template.keychain?.providers ?? []).map(item => item.provider), ...template.keychain?.removeProviders ?? []], "provider write/remove operation");
  unique([...(template.keychain?.secrets ?? []).map(item => item.key), ...template.keychain?.removeSecrets ?? []], "secret write/remove operation");
  unique([...(template.keychain?.entries ?? []).map(item => item.account), ...template.keychain?.removeAccounts ?? []], "account write/remove operation");
  for (const account of [...(template.keychain?.entries ?? []).map(item => item.account), ...template.keychain?.removeAccounts ?? []]) {
    if (!/^(secret:|oauth:model-provider:|oauth:mcp-service:|oauth:api-service:)/.test(account)) throw new Error("Unsupported Ox Keychain account family");
  }
  for (const entry of template.storage ?? []) {
    relativeStoragePath(entry.path);
    if (/(^|\/)(logs\.jsonl|DeviceTemplates)(\/|$)/.test(entry.path)) throw new Error("Logs and template control files cannot be seeded");
  }
  return template;
}

export async function prepareTemplate(template: DeviceTemplate, source: string, runID: string): Promise<PreparedTemplate> {
  const directory = dirname(resolve(source));
  let bytes = 0;
  const read = async (path: string) => {
    const file = Bun.file(resolve(directory, path));
    if (file.size > 64 * 1024 * 1024) throw new Error("Template input exceeds 64 MiB");
    const data = new Uint8Array(await file.arrayBuffer());
    bytes += data.length;
    if (bytes > 128 * 1024 * 1024) throw new Error("Template inputs exceed 128 MiB");
    return data;
  };
  const data = async (input: Static<typeof content>) => {
    const bytes = "text" in input ? new TextEncoder().encode(input.text) : await read(input.fromFile);
    if (bytes.length > ("text" in input ? 200 * 1024 : 32 * 1024 * 1024)) throw new Error("Template file exceeds Ox's file size limit");
    return bytes.toBase64();
  };
  const value = async (input: Static<typeof secret>) => {
    const result = "env" in input ? Bun.env[input.env] : new TextDecoder("utf-8", { fatal: true }).decode(await read(input.fromFile));
    if (!result?.trim()) throw new Error("Required template secret is missing or empty");
    if (new TextEncoder().encode(result).length > 64 * 1024) throw new Error("Template secret exceeds 64 KiB");
    return result.trim();
  };
  const { storage: _, websiteState, keychain, profiles, ...rest } = template;
  return {
    ...rest, runID,
    keychain: keychain && {
      providers: await Promise.all((keychain.providers ?? []).map(async item => ({ provider: item.provider, value: await value(item.secret) }))),
      entries: await Promise.all((keychain.entries ?? []).map(async item => ({ account: item.account, value: await value(item.secret) }))),
      secrets: await Promise.all((keychain.secrets ?? []).map(async item => {
        const json = await value(item.secret);
        let fields: unknown;
        try { fields = JSON.parse(json); } catch { throw new Error("Named secret is not valid JSON"); }
        if (new TextEncoder().encode(json).length > 16384 || !fields || typeof fields !== "object" || Array.isArray(fields)
          || !Object.keys(fields).length || Object.entries(fields).some(([key, field]) => !key || typeof field !== "string")) throw new Error("Named secrets require a bounded flat JSON object of string fields");
        return { key: item.key, name: item.name, value: json };
      })),
      bindings: keychain.bindings,
      removeProviders: keychain.removeProviders, removeSecrets: keychain.removeSecrets, removeAccounts: keychain.removeAccounts,
    },
    websiteState: websiteState && { data: (await read(websiteState.restoreFrom)).toBase64() },
    profiles: await Promise.all((profiles ?? []).map(async profile => ({
      ...profile,
      files: await Promise.all((profile.files ?? []).map(async file => ({ path: file.path, data: await data(file.content) }))),
      conversations: await Promise.all((profile.conversations ?? []).map(async conversation => {
        const { packageFrom, ...fields } = conversation;
        return {
          ...fields,
          packageData: packageFrom ? (await read(packageFrom)).toBase64() : undefined,
          files: await Promise.all((conversation.files ?? []).map(async file => ({ id: file.id, name: file.name, data: await data(file.content) }))),
        };
      })),
    }))),
  };
}
