import { Type, type Static } from "@sinclair/typebox";

export const SERVICE_REPOSITORY_VERSION = 1;

export const RepositoryServiceSchema = Type.String({
  minLength: 5,
  maxLength: 253,
  pattern: "^(?:web|ios|mcp):[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$",
});

export const RepositoryPackageSchema = Type.Object({
  version: Type.Literal(SERVICE_REPOSITORY_VERSION),
  name: Type.String({ minLength: 1, maxLength: 100 }),
  contentHash: Type.Optional(Type.String({ pattern: "^[a-f0-9]{64}$" })),
  services: Type.Array(RepositoryServiceSchema, { maxItems: 256 }),
}, {
  additionalProperties: false,
  $id: "https://openox.ai/schemas/repository-v1.json",
});

const JSONSchemaSchema = Type.Object({}, { additionalProperties: true });

export const ServiceActionSchema = Type.Object({
  id: Type.String({ pattern: "^[A-Za-z_][A-Za-z0-9_]*$" }),
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

export const ServiceLocaleSchema = Type.Object({
  name: Type.Optional(Type.String({ minLength: 1 })),
  description: Type.Optional(Type.String()),
  actions: Type.Optional(Type.Record(Type.String(), Type.Object({
    label: Type.Optional(Type.String({ minLength: 1 })),
    description: Type.Optional(Type.String()),
  }, { additionalProperties: false }))),
}, { additionalProperties: false });

export const ServiceManifestSchema = Type.Object({
  domain: Type.String({ pattern: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$" }),
  name: Type.String({ minLength: 1 }),
  description: Type.Optional(Type.String()),
  baseUrl: Type.String({ minLength: 1 }),
  $defs: Type.Optional(Type.Record(Type.String(), JSONSchemaSchema)),
  actions: Type.Array(ServiceActionSchema),
  locales: Type.Optional(Type.Record(Type.String(), ServiceLocaleSchema)),
}, { additionalProperties: false });

export type RepositoryPackage = Static<typeof RepositoryPackageSchema>;
export type RepositoryService = Static<typeof RepositoryServiceSchema>;
export type ServiceAction = Static<typeof ServiceActionSchema>;
export type ServiceLocale = Static<typeof ServiceLocaleSchema>;
export type ServiceManifest = Static<typeof ServiceManifestSchema>;
