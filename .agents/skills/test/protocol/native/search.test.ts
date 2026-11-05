import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import contracts from "../../../../../packages/agent/src/functions/web/contracts.json";

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

describe.skipIf(process.platform !== "darwin")("native shared search response contract", () => {
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
      join(root, "apps/shared/Host/Services/Web/WebSearchMerge.swift"),
      join(directory, "OxSearch.swift"), join(directory, "main.swift"),
    ]);
    if (result.exitCode !== 0) throw new Error(result.stderr.toString());
  }, 60_000);
  afterAll(async () => { if (directory) await rm(directory, { recursive: true, force: true }); });

  test("cross-engine and same-engine duplicates keep every source but contribute once", () => {
    const pages = [page("web:b", [item("https://EXAMPLE.com:443/a?utm_source=b", "B")]),
      page("web:a", [item("https://example.com/a", "A"), item("https://example.com/a?fbclid=1", "A duplicate")])];
    const result = run({ pages });
    expect(result.issues).toEqual([]);
    expect(result.merged).toHaveLength(1);
    expect(result.merged[0].title).toBe("A");
    expect(result.merged[0].sources.map((source: { service: string; rank: number }) => [source.service, source.rank]))
      .toEqual([["web:a", 1], ["web:b", 1], ["web:a", 2]]);
    expect(result.merged[0].score).toBeCloseTo(2 / 61, 14);
    expect(result.response.results).toEqual(pages);
    expect(run({ pages: [...pages].reverse() }).merged).toEqual(result.merged);
  });

  test("normalization only removes known trackers, host casing and default ports", () => {
    const urls = ["https://EXAMPLE.com:443/a?utm_source=x&q=a%2Bb&q=c#section", "http://EXAMPLE.com:80/a?gclid=x&x=1",
      "https://example.com/a?%75tm_campaign=x&fbclid=y&dclid=z&msclkid=w", "https://example.com/a?ref=keep&utmish=keep",
      "https://example.com/a?x=1&&utm_source=x&y=2", "https://example.com/a?", "https://example.com:444/a"];
    expect(run({ urls }).urls).toEqual(["https://example.com/a?q=a%2Bb&q=c#section", "http://example.com/a?x=1",
      "https://example.com/a", "https://example.com/a?ref=keep&utmish=keep", "https://example.com/a?x=1&&y=2",
      "https://example.com/a?", "https://example.com:444/a"]);
    const distinct = ["http://example.com/a", "https://example.com/a", "https://www.example.com/a", "https://example.com/a/",
      "https://example.com/a?q=1", "https://example.com/a?q=2", "https://example.com/a#one", "https://example.com/a#two",
      "https://example.com/a?a=1&b=2", "https://example.com/a?b=2&a=1", "https://example.com", "https://example.com/"];
    expect(run({ pages: [page("web:a", distinct.map(url => item(url)))] }).merged).toHaveLength(distinct.length);
  });

  test("invalid and null URLs stay separate even when identical", () => {
    const urls = [null, "", "relative/path", "not a url", "https://", "https://example.com/%zz", "ftp://example.com/a", "https://example.com:99999/a", "https://example.com/a b"];
    expect(run({ urls }).urls).toEqual(urls.map(() => null));
    const items = urls.map(url => item(url));
    const pages = [page("web:b", items), page("web:a", items)];
    const result = run({ pages });
    expect(result.issues).toEqual([]);
    expect(result.merged).toHaveLength(items.length * 2);
    expect(result.merged.every((entry: { sources: unknown[] }) => entry.sources.length === 1)).toBe(true);
    expect(run({ pages: [...pages].reverse() }).merged).toEqual(result.merged);
  });

  test("single-engine order, one-based ranks and internal weights", () => {
    const pages = [page("web:a", [item("https://example.com/one"), item("https://example.com/two")])];
    const result = run({ pages });
    expect(result.merged.map((entry: { score: number }) => entry.score)).toEqual([1 / 61, 1 / 62]);
    const weighted = run({ pages: [...pages, page("web:b", [item("https://example.com/two")])], weights: { "web:a": 2, "web:b": 3 } });
    expect(weighted.merged[0].url).toBe("https://example.com/two");
    expect(weighted.merged[0].score).toBeCloseTo(2 / 62 + 3 / 61, 14);
    expect(run({ pages, weights: { "web:a": 0 } }).merged.map((entry: { score: number }) => entry.score)).toEqual([0, 0]);
    expect(run({ pages, weights: { "web:a": -1 } }).merged).toEqual(result.merged);
  });

  test("tie breaking and floating sums do not depend on engine input/completion order", () => {
    const pages = ["c", "a", "f", "b", "e", "d"].map(engine => page(`web:${engine}`, [item("https://example.com/shared", engine), item(`https://example.com/${engine}`, engine)]));
    const weights = { "web:a": 1e10, "web:b": 0.1, "web:c": 0.2, "web:d": 0.3 };
    const result = run({ pages, weights }).merged;
    for (let offset = 0; offset < pages.length; offset++) {
      expect(run({ pages: [...pages.slice(offset), ...pages.slice(0, offset)].reverse(), weights }).merged).toEqual(result);
    }
    expect(result[0].title).toBe("a");
  });

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
    expect(continuation.merged.map((entry: { url: string }) => entry.url)).toEqual(["https://example.com/next"]);
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
