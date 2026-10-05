import { describe, expect, it } from "bun:test";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { registerStorageConformance } from "@earendil-works/pi-durable/testing";
import type { SqliteExecutor } from "@earendil-works/pi-durable/storage/sqlite";
import { nativeDatabase } from "../src/sqlite";
import { backend } from "./sqlite-backend";

registerStorageConformance({ describe, expect, it }, "asynchronous native facade", async use => {
  const { db } = backend();
  const storage = await SqliteStorage.open(db);
  try { await use(storage); } finally { await storage.close({ abortSignal: undefined, value: () => undefined, toString: () => "test" }); }
});

it("excludes unrelated work across awaits and expires escaped handles", async () => {
  const { db } = backend();
  await db.exec("CREATE TABLE checks (value TEXT) STRICT");
  let escaped!: SqliteExecutor;
  let release!: () => void;
  let enter!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const entered = new Promise<void>(resolve => { enter = resolve; });
  const transaction = db.transaction(async tx => {
    escaped = tx;
    await tx.run("INSERT INTO checks VALUES (?)", "inside");
    enter();
    await gate;
    expect(await tx.all("SELECT * FROM checks")).toEqual([{ value: "inside" }]);
  });
  await entered;
  let outsideDone = false;
  const outside = db.run("INSERT INTO checks VALUES (?)", "outside").then(() => { outsideDone = true; });
  await Bun.sleep(20);
  expect(outsideDone).toBe(false);
  release();
  await transaction;
  await outside;
  await expect(escaped.get("SELECT 1")).rejects.toThrow("expired");
  expect(await db.all("SELECT * FROM checks")).toHaveLength(2);
  await db.close();
});

it("rolls back before rejecting with the callback error", async () => {
  const { db } = backend();
  await db.exec("CREATE TABLE checks (value TEXT)");
  const sentinel = new Error("sentinel");
  await expect(db.transaction(async tx => {
    await tx.run("INSERT INTO checks VALUES (?)", "rolled back");
    throw sentinel;
  })).rejects.toBe(sentinel);
  expect(await db.all("SELECT * FROM checks")).toEqual([]);
  await db.close();
});

it("allows a callback to handle a rejected statement before committing", async () => {
  const { db } = backend();
  await db.exec("CREATE TABLE checks (value TEXT UNIQUE)");
  await db.transaction(async tx => {
    await tx.run("INSERT INTO checks VALUES (?)", "kept");
    await expect(tx.run("INSERT INTO checks VALUES (?)", "kept")).rejects.toThrow();
    await tx.run("INSERT INTO checks VALUES (?)", "also kept");
  });
  expect(await db.all("SELECT * FROM checks")).toHaveLength(2);
  await db.close();
});

it("distinguishes failed rollback and poisons the connection", async () => {
  const { request } = backend();
  const db = nativeDatabase((op, sql, params) => {
    if (sql === "ROLLBACK") return Promise.reject(new Error("disk failure"));
    return request(op, sql, params);
  });
  const original = new Error("callback failure");
  const error = await db.transaction(async () => { throw original; }).catch(error => error);
  expect(error).toBeInstanceOf(AggregateError);
  expect(error.errors[0]).toBe(original);
  await expect(db.get("SELECT 1")).rejects.toThrow("poisoned");
  await db.close();
});

it("round trips NULL, embedded NUL, UTF-8 and binary values; close is idempotent", async () => {
  const { db } = backend();
  const bytes = new Uint8Array([0, 255, 12]);
  expect(await db.get("SELECT ? AS nil, ? AS text, ? AS bytes", null, "中\0😀", bytes)).toEqual({ nil: null, text: "中\0😀", bytes });
  await db.close();
  await db.close();
  await expect(db.get("SELECT 1")).rejects.toThrow("closed");
});
