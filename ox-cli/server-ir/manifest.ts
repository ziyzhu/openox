import { Type, type Static, type TSchema } from "@sinclair/typebox";
import { Value } from "@sinclair/typebox/value";
import type { SkillMeta } from "./skills.ts";

const HOST_RE = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;
const IDENT_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
export const HOST_PATTERN = HOST_RE;

export function matchesServiceDomain(host: string, domain: string): boolean {
  const normalizedHost = host.toLowerCase();
  const normalizedDomain = domain.toLowerCase();
  return normalizedHost === normalizedDomain || normalizedHost.endsWith(`.${normalizedDomain}`);
}

const JSONSchemaSchema = Type.Object({}, { additionalProperties: true });
export type JSONSchema = Record<string, unknown>;

const SCHEMA_KEYS = new Set([
  "$ref", "type", "properties", "required", "additionalProperties", "items",
  "oneOf", "anyOf", "allOf", "enum", "minimum", "maximum", "minLength",
  "maxLength", "pattern", "default", "description",
]);

const JSON_TYPES = new Set(["object", "array", "string", "number", "integer", "boolean", "null"]);

export function validateJSONSchemaProfile(
  input: unknown,
  path: string,
  defs?: Record<string, JSONSchema>,
): string[] {
  const errors: string[] = [];
  validateProfile(input, path, defs, errors);
  return errors;
}

export function validateConcreteOutputSchema(
  schema: JSONSchema,
  path: string,
  defs: Record<string, JSONSchema> = {},
): string[] {
  const errors: string[] = [];
  const visited = new Set<string>();
  const walk = (candidate: JSONSchema, candidatePath: string) => {
    const value = candidate as Record<string, unknown>;
    if (typeof value.$ref === "string") {
      const name = value.$ref.match(/^#\/\$defs\/(.+)$/)?.[1];
      if (name && defs[name] && !visited.has(name)) {
        visited.add(name);
        walk(defs[name], `${candidatePath}.$ref`);
      }
      return;
    }
    for (const key of ["oneOf", "anyOf", "allOf"] as const) {
      const branches = value[key];
      if (Array.isArray(branches)) {
        branches.forEach((branch, index) => walk(branch as JSONSchema, `${candidatePath}.${key}[${index}]`));
      }
    }
    const types = Array.isArray(value.type) ? value.type : value.type ? [value.type] : [];
    if (types.includes("object")) {
      if (value.additionalProperties !== false
        && !(value.additionalProperties && typeof value.additionalProperties === "object")) {
        errors.push(`${candidatePath}: object output must define additionalProperties`);
      }
      for (const [name, property] of Object.entries((value.properties ?? {}) as Record<string, JSONSchema>)) {
        walk(property, `${candidatePath}.properties.${name}`);
      }
      if (value.additionalProperties && typeof value.additionalProperties === "object") {
        walk(value.additionalProperties as JSONSchema, `${candidatePath}.additionalProperties`);
      }
    }
    if (types.includes("array")) {
      if (!value.items || typeof value.items !== "object") {
        errors.push(`${candidatePath}: array output must define items`);
      } else {
        walk(value.items as JSONSchema, `${candidatePath}.items`);
      }
    }
    if (types.length === 0
      && value.$ref === undefined
      && value.oneOf === undefined
      && value.anyOf === undefined
      && value.allOf === undefined
      && value.enum === undefined) {
      errors.push(`${candidatePath}: output schema must define a type or composition`);
    }
  };
  walk(schema, path);
  return errors;
}

function validateProfile(
  input: unknown,
  path: string,
  defs: Record<string, JSONSchema> | undefined,
  errors: string[],
): void {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    errors.push(`${path}: schema must be an object`);
    return;
  }
  const schema = input as Record<string, unknown>;
  for (const key of Object.keys(schema)) {
    if (!SCHEMA_KEYS.has(key)) errors.push(`${path}.${key}: unsupported schema keyword`);
  }
  if (schema.$ref !== undefined) {
    if (typeof schema.$ref !== "string") errors.push(`${path}.$ref: must be a string`);
    else {
      const match = /^#\/\$defs\/(.+)$/.exec(schema.$ref);
      const name = match?.[1]?.replace(/~1/g, "/").replace(/~0/g, "~");
      if (!name || !defs?.[name]) errors.push(`${path}.$ref: unresolved local reference ${JSON.stringify(schema.$ref)}`);
    }
  }
  if (schema.type !== undefined) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!types.length || types.some((type) => typeof type !== "string" || !JSON_TYPES.has(type))) {
      errors.push(`${path}.type: unsupported JSON type`);
    }
  }
  if (schema.properties !== undefined) {
    if (!schema.properties || typeof schema.properties !== "object" || Array.isArray(schema.properties)) {
      errors.push(`${path}.properties: must be an object`);
    } else {
      for (const [name, property] of Object.entries(schema.properties)) {
        validateProfile(property, `${path}.properties.${name}`, defs, errors);
      }
    }
  }
  if (schema.required !== undefined
    && (!Array.isArray(schema.required) || schema.required.some((name) => typeof name !== "string"))) {
    errors.push(`${path}.required: must be an array of strings`);
  }
  if (schema.additionalProperties !== undefined && typeof schema.additionalProperties !== "boolean") {
    validateProfile(schema.additionalProperties, `${path}.additionalProperties`, defs, errors);
  }
  if (schema.items !== undefined) validateProfile(schema.items, `${path}.items`, defs, errors);
  for (const key of ["oneOf", "anyOf", "allOf"] as const) {
    const variants = schema[key];
    if (variants === undefined) continue;
    if (!Array.isArray(variants) || variants.length === 0) {
      errors.push(`${path}.${key}: must be a non-empty array`);
      continue;
    }
    variants.forEach((variant, index) => validateProfile(variant, `${path}.${key}[${index}]`, defs, errors));
  }
  if (schema.enum !== undefined && (!Array.isArray(schema.enum) || schema.enum.length === 0)) {
    errors.push(`${path}.enum: must be a non-empty array`);
  }
  for (const key of ["minimum", "maximum", "minLength", "maxLength"] as const) {
    if (schema[key] !== undefined && typeof schema[key] !== "number") {
      errors.push(`${path}.${key}: must be a number`);
    }
  }
  if (schema.pattern !== undefined) {
    if (typeof schema.pattern !== "string") errors.push(`${path}.pattern: must be a string`);
    else {
      try { new RegExp(schema.pattern); }
      catch { errors.push(`${path}.pattern: invalid regular expression`); }
    }
  }
}

const ActionSchema = Type.Object({
  id: Type.String({ pattern: IDENT_RE.source }),
  label: Type.String({ minLength: 1 }),
  description: Type.Optional(Type.String()),
  baseUrl: Type.Optional(Type.String({ minLength: 1 })),
  blocking: Type.Optional(Type.Boolean()),
  inputSchema: JSONSchemaSchema,
  outputSchema: JSONSchemaSchema,
  defaultArgs: Type.Optional(Type.Unknown()),
  requireApproval: Type.Boolean(),
  requireAuth: Type.Boolean(),
}, { additionalProperties: false });

export const SIGN_IN_URL_ACTION_ID = "getSignInUrl";
export const SIGN_IN_STATE_ACTION_ID = "getSignInState";
export const BOT_CONTROL_URL_ACTION_ID = "getBotControlUrl";
export const BOT_CONTROL_STATE_ACTION_ID = "getBotControlState";
export const PAYMENT_URL_ACTION_ID = "getPaymentUrl";
export const PAYMENT_STATE_ACTION_ID = "getPaymentState";
export const PAYMENT_STATUSES = ["none", "pending", "completed"] as const;

const LocaleOverlaySchema = Type.Object({
  name: Type.Optional(Type.String({ minLength: 1 })),
  description: Type.Optional(Type.String()),
  actions: Type.Optional(Type.Record(Type.String(), Type.Object({
    label: Type.Optional(Type.String({ minLength: 1 })),
    description: Type.Optional(Type.String()),
  }, { additionalProperties: false }))),
}, { additionalProperties: false });

export const ServiceManifestSchema = Type.Object({
  domain: Type.String({ pattern: HOST_RE.source }),
  name: Type.String({ minLength: 1 }),
  description: Type.Optional(Type.String()),
  baseUrl: Type.String({ minLength: 1 }),
  $defs: Type.Optional(Type.Record(Type.String(), JSONSchemaSchema)),
  actions: Type.Array(ActionSchema),
  locales: Type.Optional(Type.Record(Type.String(), LocaleOverlaySchema)),
}, { additionalProperties: false });

export type Action = Static<typeof ActionSchema>;
export type ServiceManifest = Static<typeof ServiceManifestSchema>;
export type LocaleOverlay = Static<typeof LocaleOverlaySchema>;

export type Manifest = ServiceManifest & {
  faviconUrl?: string;
  skills?: SkillMeta[];
};

const requiresAuth = (x: { requireAuth: boolean }) => x.requireAuth;

type StandardAction = Pick<Action, "id" | "requireAuth" | "requireApproval" | "inputSchema" | "outputSchema">;

export function validateStandardActions(actions: StandardAction[]): string[] {
  const errors: string[] = [];
  const at = (path: string, msg: string) => errors.push(`${path}: ${msg}`);
  const idx = (id: string) => actions.findIndex((a) => a.id === id);

  const pairRules = (urlId: string, stateId: string, banApproval: boolean) => {
    const urlIdx = idx(urlId);
    const stateIdx = idx(stateId);
    if (urlIdx >= 0 && stateIdx < 0) at("actions", `"${urlId}" action requires a paired "${stateId}" action`);
    if (stateIdx >= 0 && urlIdx < 0) at("actions", `"${stateId}" action requires a paired "${urlId}" action`);
    for (const i of [urlIdx, stateIdx]) {
      if (i < 0) continue;
      const a = actions[i]!;
      if (requiresAuth(a)) at(`actions[${i}].requireAuth`, `"${a.id}" cannot itself require auth`);
      if (banApproval && a.requireApproval) at(`actions[${i}].requireApproval`, `"${a.id}" cannot require approval`);
    }
    return { urlIdx, stateIdx };
  };

  const auth = pairRules(SIGN_IN_URL_ACTION_ID, SIGN_IN_STATE_ACTION_ID, true);
  if (auth.urlIdx < 0 && actions.some(requiresAuth)) {
    at("actions", `manifest declares requireAuth actions but no "${SIGN_IN_URL_ACTION_ID}" action`);
  }
  for (const i of [auth.urlIdx, auth.stateIdx]) {
    if (i >= 0 && !hasExactClosedObjectShape(actions[i]!.inputSchema, {})) {
      at(`actions[${i}].inputSchema`, "must be a closed object with no properties");
    }
  }
  if (auth.urlIdx >= 0 && !hasExactClosedObjectShape(actions[auth.urlIdx]!.outputSchema, { url: "string" })) {
    at(`actions[${auth.urlIdx}].outputSchema`, 'must be a closed object requiring only string "url"');
  }
  if (auth.stateIdx >= 0 && !hasExactClosedObjectShape(actions[auth.stateIdx]!.outputSchema, { signedIn: "boolean" })) {
    at(`actions[${auth.stateIdx}].outputSchema`, 'must be a closed object requiring only boolean "signedIn"');
  }

  const botControl = pairRules(BOT_CONTROL_URL_ACTION_ID, BOT_CONTROL_STATE_ACTION_ID, true);
  if (botControl.stateIdx >= 0) {
    const action = actions[botControl.stateIdx]!;
    const input = action.inputSchema as Record<string, unknown>;
    const inputProperties = (input.properties ?? {}) as Record<string, unknown>;
    const inputRequired = new Set(Array.isArray(input.required) ? input.required as string[] : []);
    if ((inputProperties.pageUrl as Record<string, unknown> | undefined)?.type !== "string") {
      at(`actions[${botControl.stateIdx}]`, "inputSchema.properties.pageUrl must be a string");
    }
    if (!inputRequired.has("pageUrl")) {
      at(`actions[${botControl.stateIdx}]`, 'inputSchema.required must include "pageUrl"');
    }
    const output = action.outputSchema as Record<string, unknown>;
    const outputProperties = (output.properties ?? {}) as Record<string, unknown>;
    const outputRequired = new Set(Array.isArray(output.required) ? output.required as string[] : []);
    if ((outputProperties.ok as Record<string, unknown> | undefined)?.type !== "boolean") {
      at(`actions[${botControl.stateIdx}]`, "outputSchema.properties.ok must be a boolean");
    }
    if (!outputRequired.has("ok")) {
      at(`actions[${botControl.stateIdx}]`, 'outputSchema.required must include "ok"');
    }
  }

  const payment = pairRules(PAYMENT_URL_ACTION_ID, PAYMENT_STATE_ACTION_ID, true);
  if (payment.stateIdx >= 0) {
    for (const msg of paymentStateShapeErrors(actions[payment.stateIdx]!.outputSchema)) {
      at(`actions[${payment.stateIdx}]`, msg);
    }
  }

  return errors;
}

function hasExactClosedObjectShape(schema: JSONSchema, expected: Record<string, string>): boolean {
  const value = schema as Record<string, unknown>;
  if (value.type !== "object" || value.additionalProperties !== false) return false;
  const properties = value.properties === undefined
    ? {}
    : value.properties as Record<string, unknown>;
  if (!properties || typeof properties !== "object" || Array.isArray(properties)) return false;
  const expectedKeys = Object.keys(expected).sort();
  const propertyKeys = Object.keys(properties).sort();
  if (expectedKeys.length !== propertyKeys.length
    || expectedKeys.some((key, index) => key !== propertyKeys[index])) return false;
  const required = value.required === undefined ? [] : value.required;
  if (!Array.isArray(required)) return false;
  const requiredKeys = [...required].sort();
  if (expectedKeys.length !== requiredKeys.length
    || expectedKeys.some((key, index) => key !== requiredKeys[index])) return false;
  return expectedKeys.every((key) => {
    const property = properties[key];
    return !!property
      && typeof property === "object"
      && !Array.isArray(property)
      && (property as Record<string, unknown>).type === expected[key];
  });
}

function paymentStateShapeErrors(schema: JSONSchema): string[] {
  const errors: string[] = [];
  const s = schema as Record<string, unknown>;
  const props = (s.properties ?? {}) as Record<string, unknown>;
  const required = new Set(Array.isArray(s.required) ? (s.required as string[]) : []);
  const statusEnum = (props.status as Record<string, unknown> | undefined)?.enum;
  const statusOk = Array.isArray(statusEnum)
    && statusEnum.length === PAYMENT_STATUSES.length
    && PAYMENT_STATUSES.every((v) => statusEnum.includes(v));
  if (!statusOk) {
    errors.push(`outputSchema.properties.status must be an enum of ${JSON.stringify(PAYMENT_STATUSES)}`);
  }
  if (!isStringOrNullSchema(props.reference)) {
    errors.push(`outputSchema.properties.reference must allow exactly string or null`);
  }
  for (const key of ["status", "reference"]) {
    if (!required.has(key)) errors.push(`outputSchema.required must include "${key}"`);
  }
  return errors;
}

function isStringOrNullSchema(schema: unknown): boolean {
  const collect = (node: unknown): string[] | null => {
    if (!node || typeof node !== "object") return null;
    const s = node as Record<string, unknown>;
    if (typeof s.type === "string") return [s.type];
    if (Array.isArray(s.type)) return s.type as string[];
    const variants = s.oneOf ?? s.anyOf;
    if (Array.isArray(variants)) {
      const types: string[] = [];
      for (const variant of variants) {
        const t = collect(variant);
        if (!t) return null;
        types.push(...t);
      }
      return types;
    }
    return null;
  };
  const types = collect(schema);
  return !!types
    && new Set(types).size === 2
    && types.includes("string")
    && types.includes("null");
}

export type ValidateServiceResult =
  | { ok: true; manifest: ServiceManifest }
  | { ok: false; errors: string[] };

export function validateServiceManifest(input: unknown): ValidateServiceResult {
  const errors: string[] = [];
  const at = (path: string, msg: string) => errors.push(`${path}: ${msg}`);

  for (const e of Value.Errors(ServiceManifestSchema, input)) {
    const path = e.path === "" ? "root" : e.path.replace(/^\//, "").replace(/\//g, ".");
    at(path, e.message);
  }
  if (errors.length > 0) return { ok: false, errors };

  const m = input as ServiceManifest;

  if (m.baseUrl.includes("{") || m.baseUrl.includes("}")) {
    at("baseUrl", "must be static");
  }
  try {
    const baseUrl = new URL(m.baseUrl);
    if (baseUrl.protocol !== "http:" && baseUrl.protocol !== "https:") {
      at("baseUrl", "must use http or https");
    } else if (!matchesServiceDomain(baseUrl.hostname, m.domain)) {
      at("baseUrl", "must use the service domain or a subdomain");
    }
  } catch {
    at("baseUrl", "must be an absolute URL");
  }

  for (const [name, schema] of Object.entries(m.$defs ?? {})) {
    errors.push(...validateJSONSchemaProfile(schema, `$defs.${name}`, m.$defs));
  }

  const seenActions = new Set<string>();
  m.actions.forEach((a, i) => {
    const path = `actions[${i}]`;
    if (seenActions.has(a.id)) at(`${path}.id`, `duplicate action "${a.id}"`);
    else seenActions.add(a.id);

    errors.push(...validateJSONSchemaProfile(a.inputSchema, `${path}.inputSchema`, m.$defs));
    errors.push(...validateJSONSchemaProfile(a.outputSchema, `${path}.outputSchema`, m.$defs));
    errors.push(...validateConcreteOutputSchema(a.outputSchema, `${path}.outputSchema`, m.$defs));

    if (Object.prototype.hasOwnProperty.call(a, "defaultArgs")) {
      const r = validateAgainstSchema(a.inputSchema, a.defaultArgs, m.$defs);
      if (!r.ok) for (const e of r.errors) at(`${path}.defaultArgs`, e);
    }

    if (a.baseUrl !== undefined) {
      const placeholders = [...a.baseUrl.matchAll(/\{([A-Za-z_][A-Za-z0-9_]*)\}/g)];
      const queryPlaceholders = [...a.baseUrl.matchAll(/[?&][^=&#]+=\{([A-Za-z_][A-Za-z0-9_]*)\}(?=&|#|$)/g)];
      const parsedBaseUrl = a.baseUrl.replace(/\{[A-Za-z_][A-Za-z0-9_]*\}/g, "schema-input");
      try {
        const url = new URL(parsedBaseUrl);
        if (url.protocol !== "http:" && url.protocol !== "https:") {
          at(`${path}.baseUrl`, "must use http or https");
        } else if (!matchesServiceDomain(url.hostname, m.domain)) {
          at(`${path}.baseUrl`, "must use the service domain or a subdomain");
        }
      } catch {
        at(`${path}.baseUrl`, "must be an absolute URL");
      }
      if (a.baseUrl.includes("{") || a.baseUrl.includes("}")) {
        const unmatched = a.baseUrl.replace(/\{[A-Za-z_][A-Za-z0-9_]*\}/g, "");
        if (unmatched.includes("{") || unmatched.includes("}")) {
          at(`${path}.baseUrl`, "contains an invalid input placeholder");
        }
        if (placeholders.length !== queryPlaceholders.length) {
          at(`${path}.baseUrl`, "input placeholders must be complete query values");
        }
        const input = a.inputSchema as Record<string, unknown>;
        const properties = (input.properties ?? {}) as Record<string, Record<string, unknown>>;
        for (const match of placeholders) {
          const inputName = match[1]!;
          if (properties[inputName]?.type !== "string") {
            at(`${path}.baseUrl`, `input placeholder "${inputName}" must reference a string property`);
          }
        }
      }
    }
  });

  errors.push(...validateStandardActions(m.actions));
  if (errors.length > 0) return { ok: false, errors };
  return { ok: true, manifest: m };
}

function toTypeBox(schema: JSONSchema): TSchema {
  const s = schema as Record<string, unknown>;

  if (typeof s.$ref === "string") {
    const m = /^#\/\$defs\/(.+)$/.exec(s.$ref);
    return m ? Type.Ref(m[1]!) : Type.Unknown();
  }
  if (Array.isArray(s.oneOf)) return Type.Union((s.oneOf as JSONSchema[]).map(toTypeBox));
  if (Array.isArray(s.anyOf)) return Type.Union((s.anyOf as JSONSchema[]).map(toTypeBox));
  if (Array.isArray(s.allOf)) return Type.Intersect((s.allOf as JSONSchema[]).map(toTypeBox));
  if (Array.isArray(s.enum)) {
    return Type.Union((s.enum as unknown[]).map((v) => Type.Literal(v as string | number | boolean)));
  }

  const type = s.type;
  if (Array.isArray(type)) {
    return Type.Union((type as string[]).map((t) => toTypeBox({ ...s, type: t } as JSONSchema)));
  }

  switch (type) {
    case "string": return Type.String(passOptions(s));
    case "integer": return Type.Integer(passOptions(s));
    case "number": return Type.Number(passOptions(s));
    case "boolean": return Type.Boolean();
    case "null": return Type.Null();
    case "array": {
      const items = s.items ? toTypeBox(s.items as JSONSchema) : Type.Unknown();
      return Type.Array(items, passOptions(s));
    }
    case "object": {
      const props: Record<string, TSchema> = {};
      const required = new Set((s.required as string[] | undefined) ?? []);
      const properties = (s.properties as Record<string, JSONSchema> | undefined) ?? {};
      for (const [k, v] of Object.entries(properties)) {
        const t = toTypeBox(v);
        props[k] = required.has(k) ? t : Type.Optional(t);
      }
      const opts: Record<string, unknown> = {};
      if (s.additionalProperties === false) opts.additionalProperties = false;
      else if (s.additionalProperties && typeof s.additionalProperties === "object") {
        opts.additionalProperties = toTypeBox(s.additionalProperties as JSONSchema);
      }
      return Type.Object(props, opts);
    }
  }
  return Type.Unknown();
}

const STRUCTURAL_KEYS = new Set([
  "type", "properties", "required", "additionalProperties",
  "items", "oneOf", "anyOf", "allOf", "enum", "$ref", "$defs", "default",
]);

function passOptions(s: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(s)) {
    if (!STRUCTURAL_KEYS.has(k)) out[k] = v;
  }
  return out;
}

export function validateAgainstSchema(
  schema: JSONSchema,
  value: unknown,
  defs?: Record<string, JSONSchema>,
): { ok: true } | { ok: false; errors: string[] } {
  const allDefs: Record<string, JSONSchema> = {
    ...(defs ?? {}),
    ...(((schema as { $defs?: Record<string, JSONSchema> }).$defs) ?? {}),
  };
  const refs: TSchema[] = Object.entries(allDefs).map(([id, d]) => {
    const t = toTypeBox(d) as TSchema & { $id?: string };
    t.$id = id;
    return t;
  });
  const compiled = toTypeBox(schema);
  const errs: string[] = [];
  for (const e of Value.Errors(compiled, refs, value)) {
    errs.push(`${e.path || "/"} ${e.message}`);
    if (errs.length >= 3) break;
  }
  return errs.length === 0 ? { ok: true } : { ok: false, errors: errs };
}

function isHttpURL(v: string): boolean {
  try {
    const url = new URL(v);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}
