import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { defineDoc, type Harness, type JsonObject } from "@earendil-works/pi-durable";
import { ConversationApplicationMetadata } from "./install";

export const Schedules = defineDoc<{
  revision: number;
  records: Record<string, JsonObject>;
  legacyImported: boolean;
  host: string;
}>({
  kind: "ox.schedules", version: 1, scope: "session",
  initial: () => ({ revision: 0, records: {}, legacyImported: false, host: "" }),
  checkpointWhen: (_, __, info) => info.deltasSinceBase >= 31,
});
const context = BACKGROUND_CONTEXT;

export async function readSchedules(harness: Harness) {
  return await harness.snapshot(Schedules, context) ?? { revision: 0, records: {}, legacyImported: false, host: "" };
}

export async function replaceSchedules(harness: Harness, revision: number, records: Record<string, JsonObject>, host: string) {
  if (!Number.isSafeInteger(revision) || revision < 0 || !host || Object.keys(records).length > 100) throw new Error("Invalid schedules");
  await harness.commit(async tx => {
    const doc = await tx.doc(Schedules);
    if (doc.revision !== revision) throw new Error("Schedules changed; reload before retrying");
    doc.records = records;
    doc.revision++;
    doc.legacyImported = true;
    doc.host = host;
  }, context);
  return readSchedules(harness);
}

export async function importSchedules(harness: Harness, records: Record<string, JsonObject>, host: string) {
  await harness.commit(async tx => {
    const doc = await tx.doc(Schedules);
    if (doc.legacyImported) return;
    if (Object.keys(doc.records).length || Object.keys(records).length > 100) throw new Error("Schedule migration collision");
    doc.records = records;
    doc.legacyImported = true;
    doc.host = host;
    doc.revision++;
  }, context);
  return readSchedules(harness);
}

export async function importScheduleIdentity(harness: Harness, profileID: string) {
  await harness.commit(async tx => {
    const doc = await tx.doc(Schedules);
    for (const record of Object.values(doc.records)) {
      record.profileID = profileID;
      const state = record.state as JsonObject | undefined;
      if (state && ("active" in state || "running" in state)) record.state = { paused: {} };
      delete record.conversationID;
      delete record.lastChatID;
    }
    doc.host = "";
    doc.legacyImported = true;
    doc.revision++;
  }, context);
}

export async function recoverScheduledRuns(harness: Harness, profileID: string) {
  const stored = await readSchedules(harness);
  const prefix = profileID.replaceAll("-", "").slice(0, 16).toUpperCase();
  const claimed = new Set<number>();
  for (const record of Object.values(stored.records)) {
    const state = record.state as JsonObject | undefined;
    const raw = typeof record.lastChatID === "string" ? record.lastChatID.replaceAll("-", "").toUpperCase() : "";
    if (state && "running" in state && raw.length === 32 && raw.startsWith(prefix)) {
      const id = Number.parseInt(raw.slice(16), 16);
      if (Number.isSafeInteger(id)) claimed.add(id);
    }
  }
  const inspection = await harness.inspect(context);
  const pending = new Set([...inspection.tasks.map(({ record }) => record.conversationId), ...inspection.submissions.map(record => record.conversationId)]);
  let cancelled = 0;
  for (const id of pending) {
    const metadata = (await harness.snapshot(ConversationApplicationMetadata, id, context))?.fields;
    if (!claimed.has(id) && typeof metadata?.scheduledSkillID !== "string") continue;
    const conversation = await harness.conversation(id, context);
    if (conversation) { await conversation.abort(context); cancelled++; }
  }
  return { cancelled };
}
