import { Type, type Static } from "@sinclair/typebox";

export const OPENOX_PROTOCOL_VERSION = 1;

export const JSONValueSchema = Type.Recursive(Self => Type.Union([
  Type.Null(),
  Type.Boolean(),
  Type.Number(),
  Type.String(),
  Type.Array(Self),
  Type.Record(Type.String(), Self),
]), { $id: "JSONValue" });

export const JSONObjectSchema = Type.Record(Type.String(), JSONValueSchema);

export const UUIDSchema = Type.String({
  pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
});

export const ISO8601DateSchema = Type.String({
  pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?Z$",
});

export type JSONValue = Static<typeof JSONValueSchema>;
export type JSONObject = Static<typeof JSONObjectSchema>;
