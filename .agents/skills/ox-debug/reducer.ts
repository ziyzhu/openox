import { existsSync } from "node:fs";
import { readdir, readFile } from "node:fs/promises";
import { basename, join, resolve } from "node:path";
import { ROOT, dispatch, fail, failResult, type SubCommand } from "./lib.ts";
import { runOnce } from "../../../scripts/debug-ws.ts";

export const SUBS: Record<string, SubCommand> = {
  replay: {
    desc: "Replay recorded turns through the projection reducer and compare committed golden snapshots (--fixtures, --update, --json)",
    fn: replay,
  },
};

export async function reducer(args: string[]): Promise<void> {
  return dispatch("reducer", "Deterministic conversation reducer verification.", SUBS, args);
}

type ReplayRow = {
  name: string;
  snapshot: unknown;
};

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
  let timeoutMs = 30000;
  let update = false;
  let asJson = false;
  for (let index = 0; index < args.length; index++) {
    const arg = args[index]!;
    if (arg === "--fixtures") fixtureDirectory = resolve(ROOT, args[++index] ?? "");
    else if (arg === "--timeout") timeoutMs = Number(args[++index]) || 30000;
    else if (arg === "--update") update = true;
    else if (arg === "--json") asJson = true;
    else if (arg === "-h" || arg === "--help") {
      console.log("Usage: debug reducer replay [--fixtures ios/fixtures/chatlogs] [--update] [--json] [--timeout 30000]");
      return;
    } else fail(`unknown reducer replay argument: ${arg}`);
  }

  if (!existsSync(fixtureDirectory)) fail(`fixture directory not found: ${fixtureDirectory}`);
  const files = (await readdir(fixtureDirectory))
    .filter((file) => file.endsWith(".input.json"))
    .sort();
  if (files.length === 0) fail(`no *.input.json fixtures found in ${fixtureDirectory}`);

  const fixtures = await Promise.all(files.map(async (file) => {
    const input = JSON.parse(await readFile(join(fixtureDirectory, file), "utf8")) as { turns: unknown[] };
    return { name: basename(file, ".input.json"), turns: input.turns };
  }));
  const id = crypto.randomUUID();
  const result = await runOnce({ kind: "replay-reducer", id, fixtures }, timeoutMs);
  if (!result.ok) failResult("reducer replay", result.error);
  const rows = (result.fixtures ?? []) as ReplayRow[];
  if (rows.length !== fixtures.length) fail(`expected ${fixtures.length} replay results, received ${rows.length}`);

  const status: Array<{ name: string; status: "matched" | "updated" | "missing" | "mismatched" }> = [];
  for (const row of rows) {
    const goldenPath = join(fixtureDirectory, `${row.name}.golden.json`);
    const actual = formatted(row.snapshot);
    if (update) {
      await Bun.write(goldenPath, actual);
      status.push({ name: row.name, status: "updated" });
      continue;
    }
    if (!existsSync(goldenPath)) {
      status.push({ name: row.name, status: "missing" });
      continue;
    }
    const expected = formatted(JSON.parse(await readFile(goldenPath, "utf8")));
    status.push({ name: row.name, status: actual === expected ? "matched" : "mismatched" });
  }

  if (asJson) console.log(JSON.stringify(status, null, 2));
  else {
    console.log(`\nreducer replay ${status.length}`);
    for (const row of status) {
      const marker = row.status === "matched" || row.status === "updated" ? "✓" : "✗";
      console.log(`  ${marker} ${row.name} ${row.status}`);
    }
    console.log("");
  }
  const failures = status.filter((row) => row.status === "missing" || row.status === "mismatched");
  if (failures.length > 0) {
    fail(`${failures.length} golden snapshot${failures.length === 1 ? "" : "s"} need ${update ? "attention" : "review; rerun with --update to accept"}`);
  }
}
