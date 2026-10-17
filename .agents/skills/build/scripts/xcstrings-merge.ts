import { readFile, writeFile } from "node:fs/promises";

type Entry = { key: string; text: string };
type Catalog = { prefix: string; entries: Entry[]; suffix: string };

function skipString(source: string, index: number): number {
  for (let i = index + 1; i < source.length; i++) {
    if (source[i] === "\\") i++;
    else if (source[i] === "\"") return i + 1;
  }
  throw new Error("Unterminated string");
}

function skipValue(source: string, index: number): number {
  if (source[index] === "\"") return skipString(source, index);
  let depth = 0;
  for (let i = index; i < source.length; i++) {
    const character = source[i];
    if (character === "\"") i = skipString(source, i) - 1;
    else if (character === "{" || character === "[") depth++;
    else if (character === "}" || character === "]") {
      if (depth === 0) return i;
      if (--depth === 0) return i + 1;
    } else if (depth === 0 && character === ",") return i;
  }
  return source.length;
}

function skipWhitespace(source: string, index: number): number {
  while (/\s/.test(source[index] ?? "")) index++;
  return index;
}

function parse(source: string): Catalog {
  const strings = /^\{\s*(?:"[^"]*"\s*:\s*"[^"]*"\s*,\s*)*"strings"\s*:\s*\{/.exec(source);
  if (!strings) throw new Error("Missing top-level strings object");
  const entries: Entry[] = [];
  let index = strings[0].length;
  let start = index;
  while (true) {
    const key = skipWhitespace(source, index);
    if (source[key] === "}") return { prefix: source.slice(0, strings[0].length), entries, suffix: source.slice(start) };
    const keyEnd = skipString(source, key);
    const colon = skipWhitespace(source, keyEnd);
    const valueEnd = skipValue(source, skipWhitespace(source, colon + 1));
    const next = skipWhitespace(source, valueEnd);
    const end = source[next] === "," ? next : valueEnd;
    entries.push({ key: JSON.parse(source.slice(key, keyEnd)), text: source.slice(start, end) });
    index = source[next] === "," ? next + 1 : valueEnd;
    start = index;
  }
}

function serialize(catalog: Catalog): string {
  return catalog.prefix + catalog.entries.map(entry => entry.text).join(",") + catalog.suffix;
}

function pick<T>(base: T | undefined, ours: T | undefined, theirs: T | undefined): { value: T | undefined } | null {
  if (ours === theirs || theirs === base) return { value: ours };
  if (ours === base) return { value: theirs };
  return null;
}

function merge(base: Catalog, ours: Catalog, theirs: Catalog): Catalog | null {
  const prefix = pick(base.prefix, ours.prefix, theirs.prefix);
  const suffix = pick(base.suffix, ours.suffix, theirs.suffix);
  if (!prefix || !suffix) return null;
  const text = (catalog: Catalog) => new Map(catalog.entries.map(entry => [entry.key, entry.text]));
  const [baseText, oursText, theirsText] = [text(base), text(ours), text(theirs)];
  const merged: Entry[] = [];
  for (const { key } of ours.entries) {
    const result = pick(baseText.get(key), oursText.get(key), theirsText.get(key));
    if (!result) return null;
    if (result.value !== undefined) merged.push({ key, text: result.value });
  }
  for (const [position, { key, text: value }] of theirs.entries.entries()) {
    if (oursText.has(key)) continue;
    const result = pick(baseText.get(key), undefined, value);
    if (!result) return null;
    if (result.value === undefined) continue;
    const previous = theirs.entries.slice(0, position).reverse().find(entry => merged.some(item => item.key === entry.key));
    const at = previous ? merged.findIndex(item => item.key === previous.key) + 1 : 0;
    merged.splice(at, 0, { key, text: value });
  }
  return { prefix: prefix.value!, entries: merged, suffix: suffix.value! };
}

const [basePath, oursPath, theirsPath, name = oursPath] = Bun.argv.slice(2);
if (!basePath || !oursPath || !theirsPath) {
  console.error("Usage: xcstrings-merge.ts <base> <ours> <theirs> [path]");
  process.exit(2);
}
let result: string | null = null;
try {
  const [base, ours, theirs] = await Promise.all([basePath, oursPath, theirsPath].map(async path => parse(await readFile(path, "utf8"))));
  const merged = merge(base, ours, theirs);
  if (merged) {
    result = serialize(merged);
    JSON.parse(result);
  }
} catch (error) {
  console.error(`xcstrings-merge: ${name}: ${error instanceof Error ? error.message : error}`);
  result = null;
}
if (result !== null) {
  await writeFile(oursPath, result);
  process.exit(0);
}
console.error(`xcstrings-merge: ${name}: falling back to a text merge`);
const fallback = Bun.spawnSync(["git", "merge-file", "-L", "ours", "-L", "base", "-L", "theirs", oursPath, basePath, theirsPath], { stdout: "inherit", stderr: "inherit" });
process.exit(fallback.exitCode === 0 ? 0 : 1);
