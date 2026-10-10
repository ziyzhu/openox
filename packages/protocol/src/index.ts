import { Value } from "typebox/value";
import { Methods, Schemas, RequestSchema, ResponseSchema, type MethodName } from "./contract.ts";

export * from "./contract.ts";

const references = Schemas;
export function isMethod(method: string): method is MethodName {
  return Object.hasOwn(Methods, method);
}

// Unknown methods remain available to newer or extended Hosts; discovery is separate.
export function validateParams(method: string, params: unknown): boolean {
  if (!isMethod(method)) return true;
  const normalized = params === undefined || (Array.isArray(params) && params.length === 0) ? {} : params;
  return Value.Check(references, Schemas[Methods[method].params], normalized);
}

export function validateResult(method: string, result: unknown): boolean {
  return !isMethod(method) || Value.Check(references, Schemas[Methods[method].result], result);
}

export function validateRequest(value: unknown): boolean {
  return Value.Check(RequestSchema, value);
}

export function validateResponse(value: unknown): boolean {
  return Value.Check(ResponseSchema, value);
}
