import { isMethod, validateParams, validateResult } from "../../../../packages/protocol/src/index.ts";
import { log } from "./log.ts";

type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };
type RequestID = string | number | null;
export type Handler = (params: Record<string, unknown>) => Promise<unknown>;
export type Handlers = Record<string, Handler>;

export class HostError extends Error {
  constructor(message: string, readonly code = -32000) { super(message); }
}

/// Dispatches one JSON-RPC 2.0 message or batch. Returns undefined when only notifications were sent.
export async function handleRPC(text: string, handlers: Handlers): Promise<JSONValue | undefined> {
  let value: unknown;
  try { value = JSON.parse(text); } catch { return failure(null, -32700, "Parse error"); }
  if (!Array.isArray(value)) return request(value, handlers);
  if (value.length < 1 || value.length > 64) return failure(null, -32600, "Invalid Request");
  const responses: JSONValue[] = [];
  for (const entry of value) {
    const response = await request(entry, handlers);
    if (response !== undefined) responses.push(response);
  }
  return responses.length ? responses : undefined;
}

async function request(value: unknown, handlers: Handlers): Promise<JSONValue | undefined> {
  const fields = value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
  if (!fields || fields.jsonrpc !== "2.0" || typeof fields.method !== "string" || !validID(fields.id)) {
    return failure(null, -32600, "Invalid Request");
  }
  const id = (fields.id ?? null) as RequestID;
  const response = await invoke(fields.method, fields.params, id, handlers);
  return "id" in fields ? response : undefined;
}

async function invoke(method: string, rawParams: unknown, id: RequestID, handlers: Handlers): Promise<JSONValue> {
  const handler = isMethod(method) ? handlers[method] : undefined;
  if (!handler) return failure(id, -32601, "Method not found");
  const params = rawParams === undefined || (Array.isArray(rawParams) && !rawParams.length) ? {} : rawParams;
  if (!params || typeof params !== "object" || Array.isArray(params)) return failure(id, -32602, "Parameters must be an object");
  if (!validateParams(method, params)) return failure(id, -32602, "Invalid params");
  try {
    const result = await handler(params as Record<string, unknown>);
    if (!validateResult(method, result)) {
      log("error", "HostRPC invalid result", { method });
      return failure(id, -32603, "Internal error");
    }
    log("debug", "HostRPC completed", { method, code: 0 });
    return { jsonrpc: "2.0", id, result: result as JSONValue };
  } catch (error) {
    const code = error instanceof HostError ? error.code : -32603;
    log(code === -32603 ? "error" : "info", "HostRPC failed", { method, code });
    return failure(id, code, error instanceof HostError ? error.message : "Internal error");
  }
}

function validID(id: unknown): boolean {
  return id === undefined || id === null || typeof id === "string" || typeof id === "number";
}

function failure(id: RequestID, code: number, message: string): JSONValue {
  return { jsonrpc: "2.0", id, error: { code, message } };
}
