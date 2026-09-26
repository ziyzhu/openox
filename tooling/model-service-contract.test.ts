import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { cp, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { validateServiceManifest } from "../packages/service-sdk/src/manifest.ts";
import { MODEL_ACTION_SCHEMAS, validateModelActions } from "../packages/service-sdk/src/model-actions.ts";

const actions = () => Object.entries(MODEL_ACTION_SCHEMAS).map(([id, schemas]) => ({
  id, label: id, ...structuredClone(schemas), requireAuth: false, requireApproval: false,
}));
const manifest = () => ({ domain: "example.com", name: "Example", baseUrl: "https://example.com/", actions: actions() });

test.skipIf(process.platform !== "darwin")("Swift model streams reject invalid cursors, revisions, and terminal events", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ox-model-stream-"));
  try {
    const executable = join(directory, "stream-tests");
    const support = readFileSync("apps/ios/Ox/Host/Agent/LLM/Providers/WebsiteProviderSupport.swift", "utf8").split("nonisolated enum WebsiteToolContract")[0]!;
    await Bun.write(join(directory, "Support.swift"), support);
    const compiler = Bun.spawn(["xcrun", "swiftc", "-module-cache-path", join(directory, "cache"),
      join(directory, "Support.swift"), "apps/ios/Ox/Host/Services/Web/ModelServiceStreamState.swift",
      "tooling/fixtures/model-service-stream.swift", "-o", executable], { stdout: "pipe", stderr: "pipe" });
    const diagnostics = await new Response(compiler.stderr).text();
    expect(await compiler.exited, diagnostics).toBe(0);
    const run = Bun.spawn([executable], { stdout: "pipe", stderr: "pipe" });
    const errors = await new Response(run.stderr).text();
    expect(await run.exited, errors).toBe(0);
  } finally { await rm(directory, { recursive: true, force: true }); }
}, 60_000);

test("a complete model service uses the existing manifest shape", () => {
  expect(validateServiceManifest(manifest())).toMatchObject({ ok: true });
});

test("ordinary listModels Actions are not model providers", () => {
  const service = manifest();
  service.actions = [{ ...service.actions[0]!, outputSchema: { type: "string" } }];
  expect(validateServiceManifest(service)).toMatchObject({ ok: true });
});

test("partial generation contracts report missing Actions", () => {
  const service = manifest();
  service.actions = service.actions.filter(action => action.id !== "cancelModelGeneration");
  const result = validateServiceManifest(service);
  expect(result.ok).toBe(false);
  if (!result.ok) expect(result.errors).toContain("actions: model service requires cancelModelGeneration");
});

test("model Action schemas cannot weaken output validation", () => {
  const service = manifest();
  service.actions[2]!.outputSchema = { type: "object", additionalProperties: true };
  expect(validateModelActions(service.actions)).toContain("actions.readModelGeneration.outputSchema: incompatible standard model Action schema");
});

test("a property named description is not mistaken for schema documentation", () => {
  const service = manifest();
  const schema = service.actions[2]!.outputSchema;
  (schema.properties as Record<string, unknown>).description = { type: "string" };
  expect(validateModelActions(service.actions).join(" ")).toContain("incompatible standard model Action schema");
});

test("schema descriptions, required ordering, and local references are accepted", () => {
  const service = manifest();
  const schema = service.actions[1]!.inputSchema;
  schema.required = [...schema.required as string[]].reverse();
  schema.description = "Start a model request";
  service.actions[1]!.inputSchema = { $ref: "#/$defs/startInput" };
  expect(validateServiceManifest({ ...service, $defs: { startInput: schema } })).toMatchObject({ ok: true });
});

test("recursive schema references fail with a bounded validation error", () => {
  const service = manifest();
  service.actions[1]!.inputSchema = { $ref: "#/$defs/startInput" };
  const result = validateModelActions(service.actions, { startInput: { $ref: "#/$defs/startInput" } });
  expect(result.join(" ")).toContain("recursive or too deep");
});

test("read Actions cannot block cancellation or use another execution URL", () => {
  const service = manifest();
  const blocking = service.actions.map(action => ({ ...action, blocking: action.id === "readModelGeneration" }));
  expect(validateModelActions(blocking).join(" ")).toContain("cannot block cancellation");
  const differentURL = service.actions.map(action => ({ ...action, baseUrl: action.id === "readModelGeneration" ? "https://example.com/read" : "https://example.com/" }));
  expect(validateModelActions(differentURL).join(" ")).toContain("must share a baseUrl");
});

test("API services cannot claim the website generation contract", () => {
  const result = validateServiceManifest({ ...manifest(), kind: "api", auth: { type: "none" } });
  expect(result.ok).toBe(false);
  if (!result.ok) expect(result.errors.join(" ")).toContain("standard model Actions require a web service");
});

test("Swift and SDK validators consume the same model Action schemas", () => {
  const resource = JSON.parse(readFileSync("apps/ios/Ox/Resources/ModelServiceActions.json", "utf8"));
  expect(resource).toEqual(MODEL_ACTION_SCHEMAS);
});

test.skipIf(process.platform !== "darwin")("Swift rejects the same incompatible contracts as the SDK", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ox-model-contract-"));
  try {
    const executable = join(directory, "contract-tests");
    const compiler = Bun.spawn(["xcrun", "swiftc", "-module-cache-path", join(directory, "cache"),
      "apps/ios/Ox/Platform/Models/JSONValue.swift",
      "apps/ios/Ox/Host/Services/Web/ModelServiceContract.swift",
      "tooling/fixtures/model-service-contract.swift", "-o", executable], { stdout: "pipe", stderr: "pipe" });
    const diagnostics = await new Response(compiler.stderr).text();
    expect(await compiler.exited, diagnostics).toBe(0);
    await cp("apps/ios/Ox/Resources/ModelServiceActions.json", join(directory, "ModelServiceActions.json"));
    const complete = actions();
    const described = actions();
    described[1]!.inputSchema.description = "Model input";
    const extraProperty = actions();
    (extraProperty[2]!.outputSchema.properties as Record<string, unknown>).description = { type: "string" };
    const referenced = actions();
    referenced[1]!.inputSchema = { $ref: "#/$defs/startInput" };
    const samples = [
      { actions: complete, definitions: {}, isWeb: true },
      { actions: complete.slice(0, 1), definitions: {}, isWeb: true },
      { actions: complete.slice(1), definitions: {}, isWeb: true },
      { actions: complete, definitions: {}, isWeb: false },
      { actions: described, definitions: {}, isWeb: true },
      { actions: extraProperty, definitions: {}, isWeb: true },
      { actions: referenced, definitions: { startInput: complete[1]!.inputSchema }, isWeb: true },
      { actions: referenced, definitions: { startInput: { $ref: "#/$defs/startInput" } }, isWeb: true },
    ];
    const run = Bun.spawn([executable], { stdin: new Blob([JSON.stringify(samples)]), stdout: "pipe", stderr: "pipe" });
    const output = await new Response(run.stdout).text();
    const errors = await new Response(run.stderr).text();
    expect(await run.exited, errors).toBe(0);
    expect(JSON.parse(output)).toEqual([true, true, false, false, true, false, true, false]);
  } finally { await rm(directory, { recursive: true, force: true }); }
}, 60_000);
