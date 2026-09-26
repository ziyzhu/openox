type Schema = Record<string, unknown>;

const string = { type: "string" };
const integer = { type: "integer", minimum: 0 };
const boolean = { type: "boolean" };
const object = (properties: Record<string, Schema>): Schema => ({
  type: "object", properties, required: Object.keys(properties), additionalProperties: false,
});
const array = (items: Schema): Schema => ({ type: "array", items });
const choice = (...values: string[]): Schema => ({ type: "string", enum: values });
const nullable = (schema: Schema): Schema => ({ anyOf: [schema, { type: "null" }] });
const generation = { generationId: string };

export const MODEL_ACTION_SCHEMAS: Record<string, { inputSchema: Schema; outputSchema: Schema }> = {
  listModels: {
    inputSchema: object({}),
    outputSchema: object({ models: array(object({
      id: string, name: string,
      input: array(choice("text", "image", "pdf")),
      contextTokens: nullable(integer), outputTokens: nullable(integer),
      streaming: boolean, cancellation: boolean,
      options: array(choice("temperature", "maxTokens")),
    })) }),
  },
  startModelGeneration: {
    inputSchema: object({
      modelId: string,
      messages: array(object({ role: choice("system", "user", "assistant", "tool"), text: string })),
      attachments: array(object({ id: integer, name: string, mimeType: string })),
      options: object({ temperature: nullable({ type: "number" }), maxTokens: nullable(integer) }),
    }),
    outputSchema: object({ ...generation, submission: choice("uncertain", "confirmed") }),
  },
  readModelGeneration: {
    inputSchema: object({ ...generation, after: integer, waitMilliseconds: { ...integer, maximum: 1000 } }),
    outputSchema: object({
      nextCursor: integer,
      events: array({ oneOf: [
        object({ type: choice("text"), text: string }),
        object({ type: choice("completed") }),
        object({ type: choice("failed"), message: string, kind: choice("contextOverflow", "rateLimited", "network", "authentication", "unsupportedInput", "provider") }),
      ] }),
    }),
  },
  cancelModelGeneration: {
    inputSchema: object(generation),
    outputSchema: object({ status: choice("cancelled", "requested", "completed", "unsupported") }),
  },
};

export const MODEL_ACTION_IDS = Object.keys(MODEL_ACTION_SCHEMAS);
export const MODEL_GENERATION_ACTION_IDS = MODEL_ACTION_IDS.filter(id => id !== "listModels");

export function normalizedModelSchema(value: unknown, definitions: Record<string, Schema> = {}, depth = 0): unknown {
  if (depth > 32) throw new Error("model Action schema is recursive or too deep");
  if (Array.isArray(value)) return value.map(item => normalizedModelSchema(item, definitions, depth + 1));
  if (!value || typeof value !== "object") return value;
  const fields = value as Schema;
  if (typeof fields.$ref === "string") {
    const name = fields.$ref.match(/^#\/\$defs\/([^/]+)$/)?.[1];
    if (!name || !definitions[name]) throw new Error("unresolved model Action schema reference");
    if (Object.keys(fields).some(key => !["$ref", "description"].includes(key))) throw new Error("model Action references cannot have constraints");
    return normalizedModelSchema(definitions[name], definitions, depth + 1);
  }
  return Object.fromEntries(Object.keys(fields).filter(key => key !== "description").sort().map(key => {
    const field = fields[key];
    if (key === "properties" && field && typeof field === "object" && !Array.isArray(field)) {
      return [key, Object.fromEntries(Object.entries(field).sort(([left], [right]) => left.localeCompare(right))
        .map(([name, schema]) => [name, normalizedModelSchema(schema, definitions, depth + 1)]))];
    }
    return [key, ["required", "enum"].includes(key) && Array.isArray(field)
      ? [...field].sort()
      : normalizedModelSchema(field, definitions, depth + 1)];
  }));
}

export function validateModelActions(
  actions: { id: string; inputSchema: Schema; outputSchema: Schema; blocking?: boolean; baseUrl?: string }[],
  definitions: Record<string, Schema> = {},
): string[] {
  if (!actions.some(action => MODEL_GENERATION_ACTION_IDS.includes(action.id))) return [];
  const errors: string[] = [];
  for (const id of MODEL_ACTION_IDS) {
    const action = actions.find(action => action.id === id);
    if (!action) { errors.push(`actions: model service requires ${id}`); continue; }
    if (action.blocking) errors.push(`actions.${id}: model Actions cannot block cancellation`);
    for (const field of ["inputSchema", "outputSchema"] as const) {
      try {
        if (JSON.stringify(normalizedModelSchema(action[field], definitions)) !== JSON.stringify(normalizedModelSchema(MODEL_ACTION_SCHEMAS[id]![field]))) {
          errors.push(`actions.${id}.${field}: incompatible standard model Action schema`);
        }
      } catch (error) { errors.push(`actions.${id}.${field}: ${(error as Error).message}`); }
    }
  }
  const generationURLs = new Set(actions.filter(action => MODEL_GENERATION_ACTION_IDS.includes(action.id)).map(action => action.baseUrl ?? ""));
  if (generationURLs.size > 1) errors.push("actions: model generation Actions must share a baseUrl");
  if ([...generationURLs].some(url => /[{}]/.test(url))) errors.push("actions: model generation baseUrl must be literal");
  return errors;
}
