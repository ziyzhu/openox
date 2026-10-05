import { Database } from "bun:sqlite";
import { nativeDatabase, type SqlRequest } from "../src/sqlite";

export function backend(file = ":memory:") {
  const connection = new Database(file);
  connection.exec("PRAGMA foreign_keys=ON");
  const request: SqlRequest = async (op, sql, params) => {
    await new Promise(resolve => setTimeout(resolve, 0));
    if (op === "close") { connection.close(); return null; }
    if (op === "exec") { connection.exec(sql); return null; }
    const bindings = params.map(value => {
      if (value && typeof value === "object" && "blob" in value) return new Uint8Array(value.blob as number[]);
      if (value && typeof value === "object" && "integer" in value) return BigInt(value.integer as string);
      return value;
    });
    const statement = connection.query(sql);
    if (op === "run") { statement.run(...bindings as never[]); return null; }
    if (op === "get") return statement.get(...bindings as never[]);
    return statement.all(...bindings as never[]);
  };
  return { request, connection, db: nativeDatabase(request) };
}
