/** JSON diagnostics ABI only; importing it must not pull Pi/provider SDKs into CLI tooling. */
export interface StorageBenchmarkOptions {
  mode: "catalog" | "read" | "write";
  scale?: string;
  iterations?: number;
  benchmark?: number;
}
export interface StorageBenchmarkRow { workload: string; sample: number; ms: number; actual: number; expected: number }
export interface StorageBenchmarkScale { name: string; entryCount: number; taskCount: number; documentCount: number }
export interface StorageBenchmarkCatalog {
  mode: "catalog";
  scales: readonly StorageBenchmarkScale[];
  reads: string[];
  writes: string[];
}
export interface StorageBenchmarkMeasurement {
  mode: "read" | "write";
  scale?: StorageBenchmarkScale;
  primaryRecords?: number;
  timing: { openMS: number; seedMS: number; closeMS: number };
  sqlite: unknown;
  integrity: string;
  rows: StorageBenchmarkRow[];
}
export type StorageBenchmarkResult = StorageBenchmarkCatalog | StorageBenchmarkMeasurement;
