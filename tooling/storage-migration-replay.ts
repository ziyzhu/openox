import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { runOnce } from "../apps/cli/src/debug-ws.ts";
import { ROOT } from "./lib.ts";

type ReplayResult = {
  ok: boolean;
  error?: string;
  versionUpdated?: boolean;
  ordinaryContextRemoved?: boolean;
  unreadableContextRetained?: boolean;
  compactedContextRetained?: boolean;
  compactedContextValid?: boolean;
  noContextPreserved?: boolean;
  transcriptsUnchanged?: boolean;
  secondRunNoOp?: boolean;
  ordinaryExportOmitsContext?: boolean;
  compactedExportRetainsContext?: boolean;
};

const input = JSON.parse(await readFile(
  join(ROOT, "apps/ios/fixtures/chatlogs/short.input.json"),
  "utf8",
)) as { turns: unknown[] };
const result = await runOnce({
  kind: "replay-storage-migration",
  id: crypto.randomUUID(),
  turns: input.turns,
}, 30_000) as ReplayResult;

if (!result.ok) throw new Error(result.error ?? "storage migration replay failed");
const checks = Object.entries(result).filter(([key]) => !["ok", "kind", "id", "error"].includes(key));
const failures = checks.filter(([, value]) => value !== true);
for (const [name, value] of checks) console.log(`${value === true ? "PASS" : "FAIL"} ${name}`);
if (failures.length > 0) throw new Error(`storage migration replay failed: ${failures.map(([name]) => name).join(", ")}`);
