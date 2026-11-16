import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import contracts from "../../../../../packages/agent/src/functions/web/contracts.json";

if (process.platform !== "darwin") throw new Error("Native search contracts require macOS; use bun run test:protocol for portable checks");

const root = resolve(import.meta.dir, "../../../../..");
const contractPath = join(root, "packages/agent/src/functions/web/contracts.json");
const schema = contracts["ox.web.search"].outputSchema;
let directory: string;
let executable: string;

function item(url: string | null, title = "Result", snippet: string | null = "Excerpt") {
  return { title, url, snippet };
}
function page(service: string, items: ReturnType<typeof item>[], nextCursor: string | null = null, coverage = "unknown") {
  return { service, items, nextCursor, coverage, scope: "public" };
}
function run(input: object) {
  const result = Bun.spawnSync([executable, contractPath], { stdin: Buffer.from(JSON.stringify(input)) });
  if (result.exitCode !== 0) throw new Error(result.stderr.toString());
  return JSON.parse(result.stdout.toString());
}

describe("native shared search response contract", () => {
  beforeAll(async () => {
    directory = await mkdtemp(join(tmpdir(), "ox-search-contract-"));
    executable = join(directory, "search");
    const source = await readFile(join(root, "apps/shared/Host/Services/OxSearch.swift"), "utf8");
    await writeFile(join(directory, "OxSearch.swift"), `${source.slice(0, source.indexOf("    static let function = OxFunction("))}\n}\n`);
    await writeFile(join(directory, "main.swift"), await readFile(join(import.meta.dir, "search-fixture.swift")));
    const result = Bun.spawnSync([
      "xcrun", "swiftc", "-o", executable,
      join(root, "apps/shared/Platform/Models/JSONValue.swift"),
      join(root, "apps/shared/Platform/Models/JSONSchemaValidator.swift"),
      join(root, "apps/shared/Platform/Models/SecretReference.swift"),
      join(root, "apps/shared/Host/Services/Web/WebSearchMerge.swift"),
      join(directory, "OxSearch.swift"), join(directory, "main.swift"),
    ]);
    if (result.exitCode !== 0) throw new Error(result.stderr.toString());
  }, 60_000);
  afterAll(async () => { if (directory) await rm(directory, { recursive: true, force: true }); });

  test("empty, partial and failed-engine envelopes retain errors and per-engine pagination", () => {
    expect(run({ pages: [] }).merged).toEqual([]);
    expect(run({ pages: [page("web:a", [])] }).merged).toEqual([]);
    const pages = [page("web:a", [item("https://example.com/first")], "page-2", "partial"), page("web:b", [], null, "complete")];
    const error = { service: "web:c", code: "unavailable", message: "Failed",
      ...("recovery" in schema.properties.errors.items.properties ? { recovery: "Retry explicitly" } : {}) };
    const response = { query: "same query", results: pages, errors: [error] };
    const result = run({ pages, response });
    expect(result.issues).toEqual([]);
    expect(result.response).toEqual({ ...response, mergedResults: result.merged });
    const continuation = run({ pages: [page("web:a", [item("https://example.com/next")], null, "unknown")] });
    expect(continuation.response.results[0].items[0].url).toBe("https://example.com/next");
    expect(continuation.merged).toHaveLength(1);
    expect(continuation.merged[0].sources[0].rank).toBe(1);
  });

  test("additive schema accepts legacy output and matches native schema declarations", () => {
    const result = run({ pages: [page("web:a", [])], legacy: true });
    expect(result.issues).toEqual([]);
    expect(result.response.mergedResults).toBeUndefined();
    expect(result.nativeMergedSchema).toEqual(schema.properties.mergedResults.items);
    expect(result.nativePageSchema).toEqual(schema.properties.results.items);
    expect(schema.required).toEqual(["query", "results", "errors"]);
  });
});
