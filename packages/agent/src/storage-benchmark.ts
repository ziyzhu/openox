import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { SqliteStorage, type SqliteDatabase } from "@earendil-works/pi-durable/storage/sqlite";
import { STORAGE_MEMORY_SCALES, STORAGE_READ_BENCHMARKS, STORAGE_WRITE_BENCHMARKS, TIMING_SCALE,
  seedStorageBenchmark, seedStorageWriteBenchmark, storageBenchmarkPrimaryRecordCount } from "@earendil-works/pi-durable/testing";

import type { StorageBenchmarkOptions, StorageBenchmarkResult, StorageBenchmarkRow } from "./storage-benchmark-types";
const scales = [TIMING_SCALE, ...STORAGE_MEMORY_SCALES];

/** Runner only: workload definitions, seeds and expected values come from pinned Pi Durable. */
export async function runStorageBenchmark(database: SqliteDatabase, now: () => number, options: StorageBenchmarkOptions): Promise<StorageBenchmarkResult> {
  if (options.mode === "catalog") return { mode: "catalog" as const, scales,
    reads: STORAGE_READ_BENCHMARKS.map(item => item.name), writes: STORAGE_WRITE_BENCHMARKS.map(item => item.name) };
  if (options.mode !== "read" && options.mode !== "write") throw new Error("Unknown storage benchmark mode");
  const iterations = options.iterations ?? (options.mode === "read" ? 5 : 1);
  if (!Number.isInteger(iterations) || iterations < 1 || iterations > 20) throw new Error("Iterations must be 1...20");
  if (options.mode === "write" && iterations !== 1) throw new Error("Each write sample requires a fresh fixture");
  const scale = scales.find(item => item.name === (options.scale ?? "timing"));
  if (!scale) throw new Error("Unknown upstream storage benchmark scale");
  const write = STORAGE_WRITE_BENCHMARKS[options.benchmark ?? -1];
  if (options.mode === "write" && (!Number.isInteger(options.benchmark) || !write)) throw new Error("Invalid write benchmark index");
  const rows: StorageBenchmarkRow[] = [];
  const timing = { openMS: 0, seedMS: 0, closeMS: 0 };
  let storage: SqliteStorage | undefined;
  async function measure(workload: string, sample: number, expected: number, operation: () => Promise<number>) {
    const start = now();
    const actual = await operation();
    const ms = now() - start;
    if (actual !== expected) throw new Error(`Upstream benchmark mismatch: ${workload}: ${actual} != ${expected}`);
    if (!Number.isFinite(ms) || ms < 0) throw new Error("Invalid monotonic benchmark clock");
    rows.push({ workload, sample, ms, actual, expected });
  }
  try {
    const opened = now();
    storage = await SqliteStorage.open(database);
    timing.openMS = now() - opened;
    const seeded = now();
    if (options.mode === "read") {
      const dataset = await seedStorageBenchmark(storage, scale);
      timing.seedMS = now() - seeded;
      for (let sample = 0; sample <= iterations; sample++) {
        for (const benchmark of STORAGE_READ_BENCHMARKS) {
          await measure(benchmark.name, sample, benchmark.expected(dataset), () => benchmark.run(storage!, dataset));
        }
      }
    } else {
      await seedStorageWriteBenchmark(storage);
      timing.seedMS = now() - seeded;
      await measure(write!.name, 1, write!.expected, () => write!.run(storage!));
    }
    const integrity = await database.get<{ integrity_check: string }>("PRAGMA integrity_check");
    if (integrity?.integrity_check !== "ok") throw new Error("Storage benchmark integrity check failed");
    const sqlite = { version: await database.get("SELECT sqlite_version() AS version"),
      journal: await database.get("PRAGMA journal_mode"), synchronous: await database.get("PRAGMA synchronous"),
      foreignKeys: await database.get("PRAGMA foreign_keys") };
    return { mode: options.mode, sqlite, scale: options.mode === "read" ? scale : undefined,
      primaryRecords: options.mode === "read" ? storageBenchmarkPrimaryRecordCount(scale) : undefined,
      timing, integrity: "ok", rows };
  } finally {
    const closing = now();
    if (storage) await storage.close(BACKGROUND_CONTEXT); else await database.close();
    timing.closeMS = now() - closing;
  }
}
