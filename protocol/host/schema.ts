import { Type, type Static } from "@sinclair/typebox";
import { JSONObjectSchema, JSONValueSchema, OPENOX_PROTOCOL_VERSION } from "../schema.ts";

export const VM_PROTOCOL_VERSION = OPENOX_PROTOCOL_VERSION;

const RequestIDSchema = Type.String({ minLength: 1 });
const SessionIDSchema = Type.Optional(Type.String({ minLength: 1 }));

export const VMInspectRequestSchema = Type.Object({
  kind: Type.Literal("vm-inspect"),
  id: RequestIDSchema,
  protocolVersion: Type.Literal(VM_PROTOCOL_VERSION),
  sessionId: SessionIDSchema,
}, { additionalProperties: false });

export const VMFunctionsRequestSchema = Type.Object({
  kind: Type.Literal("vm-functions"),
  id: RequestIDSchema,
  protocolVersion: Type.Literal(VM_PROTOCOL_VERSION),
  function: Type.Optional(Type.String({ minLength: 1 })),
}, { additionalProperties: false });

export const VMCallRequestSchema = Type.Object({
  kind: Type.Literal("vm-call"),
  id: RequestIDSchema,
  protocolVersion: Type.Literal(VM_PROTOCOL_VERSION),
  sessionId: SessionIDSchema,
  function: Type.String({ minLength: 1 }),
  arguments: JSONObjectSchema,
}, { additionalProperties: false });

export const VMEvalRequestSchema = Type.Object({
  kind: Type.Literal("vm-eval"),
  id: RequestIDSchema,
  protocolVersion: Type.Literal(VM_PROTOCOL_VERSION),
  sessionId: SessionIDSchema,
  script: Type.String({ minLength: 1 }),
}, { additionalProperties: false });

export const VMControlRequestSchema = Type.Union([
  VMInspectRequestSchema,
  VMFunctionsRequestSchema,
  VMCallRequestSchema,
  VMEvalRequestSchema,
], { $id: "https://oxcraft.ai/schemas/vm-control-request-v1.json" });

export const VMLogSchema = Type.Object({
  level: Type.String(),
  message: Type.String(),
}, { additionalProperties: false });

const response = <Kind extends string>(kind: Kind) => Type.Union([
  Type.Object({
    kind: Type.Literal(kind),
    id: RequestIDSchema,
    ok: Type.Literal(true),
    protocolVersion: Type.Literal(VM_PROTOCOL_VERSION),
    value: Type.Optional(JSONValueSchema),
    logs: Type.Optional(Type.Array(VMLogSchema)),
  }, { additionalProperties: false }),
  Type.Object({
    kind: Type.Literal(kind),
    id: RequestIDSchema,
    ok: Type.Literal(false),
    protocolVersion: Type.Literal(VM_PROTOCOL_VERSION),
    logs: Type.Optional(Type.Array(VMLogSchema)),
    error: Type.String({ minLength: 1 }),
  }, { additionalProperties: false }),
]);

export const VMInspectResponseSchema = response("vm-inspect-result");
export const VMFunctionsResponseSchema = response("vm-functions-result");
export const VMCallResponseSchema = response("vm-call-result");
export const VMEvalResponseSchema = response("vm-eval-result");

export const VMControlResponseSchema = Type.Union([
  VMInspectResponseSchema,
  VMFunctionsResponseSchema,
  VMCallResponseSchema,
  VMEvalResponseSchema,
], { $id: "https://oxcraft.ai/schemas/vm-control-response-v1.json" });

export type VMControlRequest = Static<typeof VMControlRequestSchema>;
export type VMControlResponse = Static<typeof VMControlResponseSchema>;
