import { Type, type Static } from "@sinclair/typebox";
import { Value } from "@sinclair/typebox/value";

export const REPOSITORY_VERSION = 1;

const RepositoryServiceSchema = Type.String({
  minLength: 5,
  maxLength: 253,
  pattern: "^(?:web|ios|mcp):[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$",
});

export const RepositoryPackageSchema = Type.Object({
  version: Type.Literal(REPOSITORY_VERSION),
  name: Type.String({ minLength: 1, maxLength: 100 }),
  contentHash: Type.Optional(Type.String({ pattern: "^[a-f0-9]{64}$" })),
  services: Type.Array(RepositoryServiceSchema, { maxItems: 256 }),
}, {
  additionalProperties: false,
  $id: "https://oxcraft.ai/schemas/repository-v1.json",
});

export type RepositoryPackage = Static<typeof RepositoryPackageSchema>;
export type RepositoryService = Static<typeof RepositoryServiceSchema>;
export type RepositoryServiceKind = "web" | "ios" | "mcp";

export function repositoryServiceKind(id: string): RepositoryServiceKind {
  return id.slice(0, id.indexOf(":")) as RepositoryServiceKind;
}

export function repositoryServiceIdentity(id: string): string {
  return id.slice(id.indexOf(":") + 1);
}

export function repositoryServicePath(id: string): string {
  return `${repositoryServiceKind(id)}/${repositoryServiceIdentity(id)}`;
}

export function qualifiedRepositoryServiceID(kind: RepositoryServiceKind, identity: string): string {
  return kind === "ios" && identity.startsWith("ios:") ? identity : `${kind}:${identity}`;
}

export function validateRepositoryPackage(raw: unknown): RepositoryPackage | { error: string } {
  if (!Value.Check(RepositoryPackageSchema, raw)) return { error: "invalid ox.json" };
  const repository = raw as RepositoryPackage;
  const identities = new Set<string>();
  for (const service of repository.services) {
    const identity = repositoryServiceIdentity(service);
    if (identities.has(identity)) return { error: `duplicate service ${identity}` };
    identities.add(identity);
  }
  return repository;
}
