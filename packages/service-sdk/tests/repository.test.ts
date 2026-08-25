import { describe, expect, test } from "bun:test";
import {
  qualifiedRepositoryServiceID,
  repositoryServiceIdentity,
  repositoryServiceKind,
  repositoryServicePath,
  validateRepositoryPackage,
} from "../src/repository.ts";

function repository(services: unknown[]) {
  return {
    version: 1,
    name: "Test Services",
    services,
  };
}

describe("validateRepositoryPackage", () => {
  test("accepts qualified service identities", () => {
    const result = validateRepositoryPackage({
      ...repository([
        "web:github.com",
        "ios:files",
        "mcp:aws",
      ]),
      contentHash: "a".repeat(64),
    });
    expect("error" in result).toBeFalse();
  });

  test("rejects legacy metadata and invalid content hashes", () => {
    expect(validateRepositoryPackage({
      formatVersion: 1,
      name: "Legacy",
      services: [],
    })).toEqual({ error: "invalid repository.json" });
    expect(validateRepositoryPackage({
      ...repository([]),
      minimumOxVersion: "1.0.0",
    })).toEqual({ error: "invalid repository.json" });
    expect(validateRepositoryPackage({
      ...repository([]),
      contentHash: "not-a-hash",
    })).toEqual({ error: "invalid repository.json" });
  });

  test("rejects path traversal identities", () => {
    expect(validateRepositoryPackage(repository([
      "web:..",
    ]))).toEqual({ error: "invalid repository.json" });
  });

  test("rejects unqualified and object service entries", () => {
    expect(validateRepositoryPackage(repository([
      "github.com",
    ]))).toEqual({ error: "invalid repository.json" });
    expect(validateRepositoryPackage(repository([
      { id: "web:github.com" },
    ]))).toEqual({ error: "invalid repository.json" });
  });

  test("rejects duplicate service identities across kinds", () => {
    expect(validateRepositoryPackage(repository([
      "web:aws",
      "mcp:aws",
    ]))).toEqual({ error: "duplicate service aws" });
  });

  test("derives kind, runtime identity, and path", () => {
    expect(repositoryServiceKind("web:amazon.com")).toBe("web");
    expect(repositoryServiceIdentity("web:amazon.com")).toBe("amazon.com");
    expect(repositoryServicePath("web:amazon.com")).toBe("web/amazon.com");
    expect(repositoryServicePath("ios:browser")).toBe("ios/browser");
    expect(qualifiedRepositoryServiceID("ios", "ios:browser")).toBe("ios:browser");
    expect(qualifiedRepositoryServiceID("mcp", "aws")).toBe("mcp:aws");
  });
});
