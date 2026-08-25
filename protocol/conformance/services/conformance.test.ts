import { expect, test } from "bun:test";
import { Value } from "@sinclair/typebox/value";
import { validateServiceManifest } from "../../../packages/service-sdk/src/manifest.ts";
import { validateRepositoryPackage } from "../../../packages/service-sdk/src/repository.ts";
import {
  RepositoryPackageSchema,
  ServiceManifestSchema,
} from "../../services/schema.ts";
import {
  RepositoryPackageSchema as SDKRepositoryPackageSchema,
} from "../../../packages/service-sdk/src/repository.ts";
import {
  ServiceManifestSchema as SDKServiceManifestSchema,
} from "../../../packages/service-sdk/src/manifest.ts";

const fixture = (path: string) => Bun.file(`${import.meta.dir}/${path}`).json();

test("service protocol accepts the valid repository fixture", async () => {
  const input = await fixture("valid/repository.json");
  expect(Value.Check(RepositoryPackageSchema, input)).toBe(true);
  const result = validateRepositoryPackage(input);
  expect("error" in result).toBe(false);
});

test("service protocol accepts the valid service fixture", async () => {
  const input = await fixture("valid/service.json");
  expect(Value.Check(ServiceManifestSchema, input)).toBe(true);
  const result = validateServiceManifest(input);
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

test("service SDK structural schemas match the protocol", () => {
  expect(JSON.parse(JSON.stringify(SDKRepositoryPackageSchema))).toEqual(JSON.parse(JSON.stringify(RepositoryPackageSchema)));
  expect(JSON.parse(JSON.stringify(SDKServiceManifestSchema))).toEqual(JSON.parse(JSON.stringify(ServiceManifestSchema)));
});
