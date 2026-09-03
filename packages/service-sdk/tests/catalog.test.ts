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

  test("accepts iOS favicon URLs without local icons", () => {
    const { icon: _, ...manifest } = iosManifest();
    const remoteManifest = {
      ...manifest,
      faviconUrl: "https://example.com/favicon.png",
    };
    expect(validateIOSManifest("ios:calendar", remoteManifest)).toEqual(remoteManifest);
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

  test("rejects insecure native icon URLs", () => {
    const { icon: _, ...manifest } = iosManifest();
    expect(validateIOSManifest("ios:calendar", {
      ...manifest,
      faviconUrl: "http://example.com/favicon.png",
    })).toEqual({ error: "ios ios:calendar: faviconUrl must use HTTPS" });
  });

  test("accepts MCP favicon URLs and rejects insecure ones", () => {
    expect(validateMCPManifest("aws", {
      ...mcpManifest(),
      faviconUrl: "https://example.com/favicon.png",
    })).toEqual({
      ...mcpManifest(),
      faviconUrl: "https://example.com/favicon.png",
    });
    expect(validateMCPManifest("aws", {
      ...mcpManifest(),
      faviconUrl: "http://example.com/favicon.png",
    })).toEqual({ error: "mcp aws: faviconUrl must use HTTPS" });
  });
});
