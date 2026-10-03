import { Value } from "@sinclair/typebox/value";
import { Methods, Schemas, RequestSchema, ResponseSchema, type MethodName } from "./contract.ts";

export * from "./contract.ts";

const references = Object.values(Schemas);
export function isMethod(method: string): method is MethodName {
  return Object.hasOwn(Methods, method);
}

// Unknown methods remain available to newer or extended Hosts; discovery is separate.
export function validateParams(method: string, params: unknown): boolean {
  if (!isMethod(method)) return true;
  const normalized = params === undefined || (Array.isArray(params) && params.length === 0) ? {} : params;
  return Value.Check(Schemas[Methods[method].params], references, normalized);
}

export function validateResult(method: string, result: unknown): boolean {
  return !isMethod(method) || Value.Check(Schemas[Methods[method].result], references, result);
}

export function validateRequest(value: unknown): boolean {
  return Value.Check(RequestSchema, value);
}

export function validateResponse(value: unknown): boolean {
  return Value.Check(ResponseSchema, value);
}
