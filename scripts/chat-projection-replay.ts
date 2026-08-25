import { existsSync } from "node:fs";
import { readdir, readFile } from "node:fs/promises";
import { basename, join, resolve } from "node:path";
import { runOnce } from "../cli/debug-ws.ts";
import { ROOT } from "./lib.ts";

type ReplayRow = {
  name: string;
  snapshot: unknown;
};

type ReplayResult = {
  ok: true;
  fixtures?: ReplayRow[];
};

function fail(message: string): never {
  console.error(`error: ${message}`);
  process.exit(1);
}

function takeValue(args: string[], index: number, flag: string): string {
  const value = args[index + 1];
  if (!value || value.startsWith("--")) fail(`${flag} requires a value`);
  return value;
}

function sorted(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, child]) => [key, sorted(child)]),
    );
  }
  return value;
}

function formatted(value: unknown): string {
  return `${JSON.stringify(sorted(value), null, 2)}\n`;
}

async function replay(args: string[]): Promise<void> {
  let fixtureDirectory = join(ROOT, "ios/fixtures/chatlogs");
  let timeoutMs = 30_000;
  let update = false;
  let asJson = false;

  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--fixtures") fixtureDirectory = resolve(ROOT, takeValue(args, index++, argument));
    else if (argument === "--timeout") {
      const value = Number(takeValue(args, index++, argument));
      if (!Number.isFinite(value) || value <= 0) fail("--timeout must be a positive number");
      timeoutMs = value;
    } else if (argument === "--update") update = true;
    else if (argument === "--json") asJson = true;
    else if (argument === "-h" || argument === "--help") {
      console.log("Usage: bun run test:chat-projection [--fixtures ios/fixtures/chatlogs] [--update] [--json] [--timeout 30000]");
      return;
    } else fail(`unknown argument: ${argument}`);
  }

  if (!existsSync(fixtureDirectory)) fail(`fixture directory not found: ${fixtureDirectory}`);
  const files = (await readdir(fixtureDirectory))
    .filter(file => file.endsWith(".input.json"))
    .sort();
  if (files.length === 0) fail(`no *.input.json fixtures found in ${fixtureDirectory}`);

  const fixtures = await Promise.all(files.map(async file => {
    const input = JSON.parse(await readFile(join(fixtureDirectory, file), "utf8")) as { turns: unknown[] };
    return { name: basename(file, ".input.json"), turns: input.turns };
  }));
  const result = await runOnce({ kind: "replay-reducer", id: crypto.randomUUID(), fixtures }, timeoutMs);
  if (!result.ok) fail(`chat projection replay failed: ${result.error}`);

  const rows = (result as ReplayResult).fixtures ?? [];
  if (rows.length !== fixtures.length) fail(`expected ${fixtures.length} replay results, received ${rows.length}`);

  const statuses: Array<{ name: string; status: "matched" | "updated" | "missing" | "mismatched" }> = [];
  for (const row of rows) {
    const goldenPath = join(fixtureDirectory, `${row.name}.golden.json`);
    const actual = formatted(row.snapshot);
    if (update) {
      await Bun.write(goldenPath, actual);
      statuses.push({ name: row.name, status: "updated" });
    } else if (!existsSync(goldenPath)) {
      statuses.push({ name: row.name, status: "missing" });
    } else {
      const expected = formatted(JSON.parse(await readFile(goldenPath, "utf8")));
      statuses.push({ name: row.name, status: actual === expected ? "matched" : "mismatched" });
    }
  }

  if (asJson) console.log(JSON.stringify(statuses, null, 2));
  else {
    console.log(`\nchat projection replay ${statuses.length}`);
    for (const row of statuses) {
      const marker = row.status === "matched" || row.status === "updated" ? "✓" : "✗";
      console.log(`  ${marker} ${row.name} ${row.status}`);
    }
    console.log("");
  }

  const failures = statuses.filter(row => row.status === "missing" || row.status === "mismatched");
  if (failures.length > 0) {
    fail(`${failures.length} golden snapshot${failures.length === 1 ? "" : "s"} need review; rerun with --update to accept`);
  }
}

await replay(process.argv.slice(2));
