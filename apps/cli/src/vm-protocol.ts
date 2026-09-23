import { Type } from "@sinclair/typebox";

const JSONValueSchema = Type.Recursive(Self => Type.Union([
  Type.Null(), Type.Boolean(), Type.Number(), Type.String(),
  Type.Array(Self), Type.Record(Type.String(), Self),
]), { $id: "JSONValue" });
const sessionId = Type.Optional(Type.String({ minLength: 1 }));

export const VMParamsSchemas = {
  "vm.inspect": Type.Object({ sessionId }, { additionalProperties: false }),
  "vm.functions": Type.Object({ function: Type.Optional(Type.String({ minLength: 1 })) }, { additionalProperties: false }),
  "vm.call": Type.Object({ sessionId, function: Type.String({ minLength: 1 }), arguments: Type.Record(Type.String(), JSONValueSchema) }, { additionalProperties: false }),
  "vm.eval": Type.Object({ sessionId, script: Type.String({ minLength: 1 }) }, { additionalProperties: false }),
};

export const VMResultSchema = Type.Object({
  value: Type.Optional(JSONValueSchema),
  logs: Type.Optional(Type.Array(Type.Object({ level: Type.String(), message: Type.String() }))),
});
