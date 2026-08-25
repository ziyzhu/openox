import { expect, test } from "bun:test";
import { Value } from "@sinclair/typebox/value";
import {
  CHAT_SCHEMA_VERSION,
  ChatMetadataSchema,
  PROFILE_SCHEMA_VERSION,
  ProfileConfigSchema,
} from "../../profile/schema.ts";

const fixture = (path: string) => Bun.file(`${import.meta.dir}/${path}`).json();

test("Profile protocol accepts current profile metadata", async () => {
  expect(Value.Check(ProfileConfigSchema, await fixture("valid/profile.json"))).toBe(true);
});

test("Profile protocol accepts current chat metadata", async () => {
  expect(Value.Check(ChatMetadataSchema, await fixture("valid/chat.json"))).toBe(true);
});

test("Profile protocol excludes device-local Profile location", async () => {
  expect(Value.Check(ProfileConfigSchema, await fixture("invalid/profile-location.json"))).toBe(false);
});

test("Profile protocol rejects unsupported chat metadata versions", async () => {
  expect(Value.Check(ChatMetadataSchema, await fixture("invalid/chat-version.json"))).toBe(false);
});

test("reference Profile implementation uses the published metadata versions", async () => {
  const [migration, chat] = await Promise.all([
    Bun.file(`${import.meta.dir}/../../../apps/ios/OpenOx/Host/Profile/ProfileMigration.swift`).text(),
    Bun.file(`${import.meta.dir}/../../../apps/ios/OpenOx/Host/Chats/ChatModel.swift`).text(),
  ]);
  expect(migration).toContain(`"${PROFILE_SCHEMA_VERSION}"`);
  expect(migration).toContain("static var current: String { versions.last! }");
  expect(chat).toContain(`static let currentSchemaVersion = ${CHAT_SCHEMA_VERSION}`);
});
