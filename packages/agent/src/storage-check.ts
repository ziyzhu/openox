import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createStorageConformance } from "@earendil-works/pi-durable/testing";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import type { StorageConformanceAssertions } from "@earendil-works/pi-durable/testing";
import { native } from "./adapters/ios/bridge";
import { nativeDatabase } from "./sqlite";

function same(actual: unknown, expected: unknown, partial = false): boolean {
  if (Object.is(actual, expected)) return true;
  if (actual === null || expected === null || typeof actual !== "object" || typeof expected !== "object") return false;
  if (Array.isArray(actual) !== Array.isArray(expected)) return false;
  const keys = Object.keys(expected);
  if (!partial && Object.keys(actual).length !== keys.length) return false;
  return keys.every(key => Object.hasOwn(actual, key) && same(
    (actual as Record<string, unknown>)[key], (expected as Record<string, unknown>)[key], partial,
  ));
}
function check(value: unknown, message = "Native storage conformance assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
const assertions: StorageConformanceAssertions = {
  ok: check,
  strictEqual: (actual, expected) => check(Object.is(actual, expected)),
  deepEqual: (actual, expected) => check(same(actual, expected)),
  partialDeepEqual: (actual, expected) => check(same(actual, expected, true)),
  greaterThan: (actual, expected) => check(actual > expected),
  async rejects(operation, messageIncludes) {
    let rejected = false;
    try { await operation; } catch (error) { rejected = String(error).includes(messageIncludes); }
    check(rejected, `Expected rejection containing ${messageIncludes}`);
  },
};

/** Runs one upstream case on a fresh native-bound cache fixture, without opening a Harness. */
export async function storageCheck(index: number) {
  const cases = createStorageConformance({ assertions, async withStorage(use) {
    const db = nativeDatabase((op, sql, params) => native("sql", { op, sql, params }));
    const storage = await SqliteStorage.open(db);
    try { await use(storage); } finally { await storage.close(BACKGROUND_CONTEXT); }
  } });
  check(Number.isInteger(index) && index >= 0 && index < cases.length, "Invalid conformance case index");
  await cases[index].run();
  return { name: cases[index].name, count: cases.length };
}
