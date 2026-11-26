import { Type, type Static } from "typebox";
import { Value } from "typebox/value";

export const PUSH_TOKEN_PATTERN = "^[0-9a-f]{64,200}$";
export const PUSH_TITLE_LIMIT = 80;
export const PUSH_BODY_LIMIT = 300;

export const PushKind = Type.Union([Type.Literal("completed"), Type.Literal("needsAttention"), Type.Literal("failed")]);
export const PushEnvironment = Type.Union([Type.Literal("development"), Type.Literal("production")]);

export const PushMessage = Type.Object({
  kind: PushKind,
  conversation: Type.String({ minLength: 1, maxLength: 200 }),
  title: Type.String({ maxLength: PUSH_TITLE_LIMIT }),
  body: Type.String({ maxLength: PUSH_BODY_LIMIT }),
}, {
  additionalProperties: false,
  description: "Notification text, sealed as base64(nonce[12] ‖ AES-256-GCM ciphertext ‖ tag[16]) with the device key before it leaves the agent.",
});

export const PushRelayRequest = Type.Object({
  token: Type.String({ pattern: PUSH_TOKEN_PATTERN, description: "APNs device token, lowercase hex." }),
  environment: PushEnvironment,
  sealed: Type.String({ minLength: 1, maxLength: 3000, description: "Sealed PushMessage; the relay forwards it without reading it." }),
  thread: Type.String({ pattern: "^[0-9a-f]{32}$", description: "Hash of the conversation ID, used as the APNs thread and collapse ID." }),
}, { additionalProperties: false });

export type PushKind = Static<typeof PushKind>;
export type PushEnvironment = Static<typeof PushEnvironment>;
export type PushMessage = Static<typeof PushMessage>;
export type PushRelayRequest = Static<typeof PushRelayRequest>;

export function parsePushRelayRequest(value: unknown): PushRelayRequest | undefined {
  return Value.Check(PushRelayRequest, value) ? value : undefined;
}
