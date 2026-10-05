import type { SqliteDatabase, SqliteExecutor, SqliteValue } from "@earendil-works/pi-durable/storage/sqlite";

export type SqlRequest = (op: string, sql: string, params: unknown[]) => Promise<unknown>;

function encode(value: SqliteValue): unknown {
  if (value instanceof Uint8Array) return { blob: Array.from(value) };
  if (typeof value === "bigint") return { integer: String(value) };
  if (typeof value === "number" && !Number.isFinite(value)) throw new TypeError("Non-finite SQL value");
  return value;
}

function decodeRow(row: unknown): object | undefined {
  if (row === null || row === undefined) return undefined;
  return Object.fromEntries(Object.entries(row as object).map(([key, value]) => [
    key,
    value && typeof value === "object" && "blob" in value ? new Uint8Array(value.blob) :
      value && typeof value === "object" && "integer" in value ? BigInt(value.integer) : value,
  ]));
}

/** One facade/connection per immutable native scope. All disk work is native and asynchronous. */
export function nativeDatabase(request: SqlRequest): SqliteDatabase {
  let tail: Promise<unknown> = Promise.resolve();
  let closed = false;
  let poisoned = false;
  function enqueue<T>(body: () => Promise<T>): Promise<T> {
    const next = tail.then(() => {
      if (closed || poisoned) throw new Error(closed ? "Database closed" : "Database poisoned; reopen required");
      return body();
    });
    tail = next.catch(() => {});
    return next;
  }
  const direct: SqliteExecutor = {
    async exec(sql) { await request("exec", sql, []); },
    async run(sql, ...params) { await request("run", sql, params.map(encode)); },
    async get<T extends object>(sql: string, ...params: SqliteValue[]) {
      return decodeRow(await request("get", sql, params.map(encode))) as T | undefined;
    },
    async all<T extends object>(sql: string, ...params: SqliteValue[]) {
      return (await request("all", sql, params.map(encode)) as unknown[]).map(decodeRow) as T[];
    },
  };
  return {
    exec: sql => enqueue(() => direct.exec(sql)),
    run: (sql, ...params) => enqueue(() => direct.run(sql, ...params)),
    get: <T extends object>(sql: string, ...params: SqliteValue[]) => enqueue(() => direct.get<T>(sql, ...params)),
    all: <T extends object>(sql: string, ...params: SqliteValue[]) => enqueue(() => direct.all<T>(sql, ...params)),
    transaction: callback => enqueue(async () => {
      await direct.exec("BEGIN IMMEDIATE");
      let active = true;
      const pending: Promise<unknown>[] = [];
      function track<T>(body: () => Promise<T>): Promise<T> {
        if (!active) return Promise.reject(new Error("Transaction handle expired"));
        const operation = body();
        pending.push(operation);
        // Observe even a detached rejection; drain all admitted statements before settlement.
        void operation.catch(() => {});
        return operation;
      }
      const tx: SqliteExecutor = {
        exec: sql => track(() => direct.exec(sql)),
        run: (sql, ...params) => track(() => direct.run(sql, ...params)),
        get: <T extends object>(sql: string, ...params: SqliteValue[]) => track(() => direct.get<T>(sql, ...params)),
        all: <T extends object>(sql: string, ...params: SqliteValue[]) => track(() => direct.all<T>(sql, ...params)),
      };
      try {
        let result;
        try { result = await callback(tx); } finally { active = false; }
        await Promise.allSettled(pending);
        await direct.exec("COMMIT");
        return result;
      } catch (error) {
        active = false;
        await Promise.allSettled(pending);
        try { await direct.exec("ROLLBACK"); }
        catch (rollback) {
          poisoned = true;
          throw new AggregateError([error, rollback], "Transaction rollback failed; reopen required");
        }
        throw error;
      }
    }),
    close() {
      const next = tail.then(async () => {
        if (closed) return;
        closed = true;
        await request("close", "", []);
      });
      tail = next.catch(() => {});
      return next;
    },
  };
}
