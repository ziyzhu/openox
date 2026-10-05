/** DEBUG storage diagnostics: published Pi conformance and benchmark workloads only. */
import "./host-api";
import { native } from "./bridge";
import { nativeDatabase } from "../../sqlite";
import { storageCheck } from "../../storage-check";
import { runStorageBenchmark } from "../../storage-benchmark";
import type { StorageBenchmarkOptions } from "../../storage-benchmark-types";

export { deliver } from "./bridge";
export const storageConformance = (options: { testCase: number }) => storageCheck(options.testCase);
declare function __oxDurableNow(): number;
export const storageBenchmark = (options: StorageBenchmarkOptions) => runStorageBenchmark(
  nativeDatabase((op, sql, params) => native("sql", { op, sql, params })), () => __oxDurableNow(), options,
);
