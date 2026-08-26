import { describe, expect, test } from "bun:test";
import { validateIOSManifest, validateMCPManifest } from "../src/catalog.ts";

function iosManifest() {
  return {
    domain: "ios:calendar",
    name: "Calendar",
    icon: { system: "calendar" },
    supportedIOS: { minimum: "18.0" },
    actions: [],
  };
}

function mcpManifest() {
  return {
    id: "aws",
    name: "AWS",
    endpoint: "https://example.com/mcp",
  };
}

describe("catalog manifests", () => {
  test("accepts valid iOS and MCP manifests", () => {
    expect(validateIOSManifest("ios:calendar", iosManifest())).toEqual(iosManifest());
    expect(validateMCPManifest("aws", mcpManifest())).toEqual(mcpManifest());
  });

  test("rejects invalid iOS version ranges", () => {
    expect(validateIOSManifest("ios:calendar", {
      ...iosManifest(),
      supportedIOS: { minimum: "18.1", maximum: "18.0" },
    })).toEqual({ error: "ios ios:calendar: minimum iOS version exceeds maximum" });
  });

  test("rejects locale overlays for unknown actions", () => {
    const result = validateIOSManifest("ios:calendar", {
      ...iosManifest(),
      locales: { en: { actions: { missing: { label: "Missing" } } } },
    });
    expect(result).toEqual({ error: "ios ios:calendar: locales.en.actions: unknown id missing" });
  });

  test("rejects insecure MCP endpoints", () => {
    expect(validateMCPManifest("aws", {
      ...mcpManifest(),
      endpoint: "http://example.com/mcp",
    })).toEqual({ error: "mcp aws: endpoint must use HTTPS" });
  });
});
