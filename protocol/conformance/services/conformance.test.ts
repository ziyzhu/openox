import { expect, test } from "bun:test";
import { validateServiceManifest } from "../../../packages/service-sdk/src/manifest.ts";
import { validateRepositoryPackage } from "../../../packages/service-sdk/src/repository.ts";

const fixture = (path: string) => Bun.file(`${import.meta.dir}/${path}`).json();

test("service protocol accepts the valid repository fixture", async () => {
  const result = validateRepositoryPackage(await fixture("valid/repository.json"));
  expect("error" in result).toBe(false);
});

test("service protocol accepts the valid service fixture", async () => {
  const result = validateServiceManifest(await fixture("valid/service.json"));
  expect(result.ok).toBe(true);
});

test("service protocol rejects an unqualified repository identity", async () => {
  const result = validateRepositoryPackage(await fixture("invalid/unqualified-repository.json"));
  expect("error" in result).toBe(true);
});

test("service protocol rejects an open object output", async () => {
  const result = validateServiceManifest(await fixture("invalid/open-output-service.json"));
  expect(result.ok).toBe(false);
});
