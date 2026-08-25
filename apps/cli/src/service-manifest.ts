import { join } from "node:path";
import { existsSync } from "node:fs";
import {
  BOT_CONTROL_STATE_ACTION_ID,
  BOT_CONTROL_URL_ACTION_ID,
  SIGN_IN_STATE_ACTION_ID,
  SIGN_IN_URL_ACTION_ID,
  validateAgainstSchema,
  type Action,
  type JSONSchema,
  type Manifest,
} from "@openox/service-sdk/manifest";

export {
  BOT_CONTROL_STATE_ACTION_ID,
  BOT_CONTROL_URL_ACTION_ID,
  SIGN_IN_STATE_ACTION_ID,
  SIGN_IN_URL_ACTION_ID,
  validateAgainstSchema,
};

export type ServiceAction = Action;
export type ServiceManifest = Manifest;
export type { JSONSchema };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseAction(value: unknown): Action {
  if (!isRecord(value)
    || typeof value.id !== "string"
    || typeof value.label !== "string"
    || !isRecord(value.inputSchema)
    || !isRecord(value.outputSchema)
    || typeof value.requireApproval !== "boolean"
    || typeof value.requireAuth !== "boolean") {
    throw new Error("service manifest contains an invalid action");
  }
  return value as Action;
}

export async function readWebService(root: string, domain: string): Promise<{ manifest: Manifest; actions: string }> {
  const serviceRoot = join(root, "web", domain);
  const servicePath = existsSync(join(serviceRoot, "service.json"))
    ? join(serviceRoot, "service.json")
    : join(serviceRoot, "manifest.json");
  const raw = await Bun.file(servicePath).json();
  if (!isRecord(raw)
    || raw.domain !== domain
    || typeof raw.name !== "string"
    || typeof raw.baseUrl !== "string"
    || !Array.isArray(raw.actions)) {
    throw new Error(`invalid web service manifest: ${domain}`);
  }
  const manifest = { ...raw, actions: raw.actions.map(parseAction) } as Manifest;
  const actions = await Bun.file(join(serviceRoot, "actions.js")).text();
  return { manifest, actions };
}
