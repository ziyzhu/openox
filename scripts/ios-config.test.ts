import { describe, expect, test } from "bun:test";
import { iosConfiguration } from "./ios-config.ts";

describe("iosConfiguration", () => {
  test("derives identifiers from the development team", () => {
    expect(iosConfiguration(" ABCDE12345 ", undefined)).toBe([
      "OX_DEVELOPMENT_TEAM = ABCDE12345",
      "OX_BUNDLE_IDENTIFIER = ai.openox.local.ABCDE12345",
      "OX_APP_GROUP_IDENTIFIER = group.ai.openox.local.ABCDE12345",
      "OX_ICLOUD_CONTAINER_IDENTIFIER = iCloud.ai.openox.local.ABCDE12345",
      "OX_KEYCHAIN_SERVICE = ai.openox.local.ABCDE12345.llm",
      "OX_WEBSITE_DATA_NAMESPACE = ai.openox.local.ABCDE12345.web-profile",
      "OX_AGENT_SKILL_TYPE_IDENTIFIER = ai.openox.agent-skill",
      "OX_CHAT_TYPE_IDENTIFIER = ai.openox.chat",
      "",
    ].join("\n"));
  });

  test("accepts an explicit bundle identifier", () => {
    const configuration = iosConfiguration("ABCDE12345", " com.example.openox ");
    expect(configuration).toContain("OX_BUNDLE_IDENTIFIER = com.example.openox\n");
    expect(configuration).toContain("OX_APP_GROUP_IDENTIFIER = group.com.example.openox\n");
    expect(configuration).toContain("OX_ICLOUD_CONTAINER_IDENTIFIER = iCloud.com.example.openox\n");
  });

  test("rejects invalid team and bundle identifiers", () => {
    expect(() => iosConfiguration("ABC123", undefined)).toThrow("Pass --team");
    expect(() => iosConfiguration("ABCDE12345", "invalid")).toThrow("Pass --bundle");
  });
});
