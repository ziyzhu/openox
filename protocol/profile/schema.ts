import { Type, type Static } from "@sinclair/typebox";
import { ISO8601DateSchema, UUIDSchema } from "../schema.ts";

export const PROFILE_SCHEMA_VERSION = "2026-08-17-runtime";
export const CHAT_SCHEMA_VERSION = 1;

export const ProfileConfigSchema = Type.Object({
  id: UUIDSchema,
  createdAt: ISO8601DateSchema,
  version: Type.String({ minLength: 1 }),
}, {
  additionalProperties: false,
  $id: "https://openox.ai/schemas/profile-config-v1.json",
});

export const ChatMetadataSchema = Type.Object({
  schemaVersion: Type.Literal(CHAT_SCHEMA_VERSION),
  id: UUIDSchema,
  createdAt: ISO8601DateSchema,
  lastActivity: Type.Optional(ISO8601DateSchema),
  title: Type.Optional(Type.String()),
  isFavorite: Type.Boolean(),
  modelID: Type.Optional(Type.String()),
  clientID: Type.Optional(Type.String()),
  monoRepositoryHash: Type.Optional(Type.String()),
  attachedServiceDomains: Type.Array(Type.String()),
  preview: Type.Optional(Type.String()),
  hasUnreadResponse: Type.Optional(Type.Boolean()),
}, {
  additionalProperties: false,
  $id: "https://openox.ai/schemas/chat-metadata-v1.json",
});

export type ProfileConfig = Static<typeof ProfileConfigSchema>;
export type ChatMetadata = Static<typeof ChatMetadataSchema>;
