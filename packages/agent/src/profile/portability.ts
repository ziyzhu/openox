import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { JsonObject } from "@earendil-works/pi-durable";
import type { ProfileRuntime } from "./runtime";
import { ProfileIndex } from "./files";
import { readSchedules, importScheduleIdentity } from "./schedules";

const context = BACKGROUND_CONTEXT;

export async function prepareProfileExport(session: ProfileRuntime) {
  const inspection = await session.harness.inspect(context);
  if (inspection.tasks.length || inspection.submissions.length) throw new Error("Stop running conversations and finish queued messages before exporting this Profile");
  if (session.files.physical && (await session.files.state()).pending.length) throw new Error("Finish pending file changes before exporting this Profile");
  const schedules = await readSchedules(session.harness);
  if (Object.values(schedules.records).some(record => record.state && "running" in (record.state as JsonObject))) {
    throw new Error("Stop running schedule checks before exporting this Profile");
  }
  await session.files.flush();
  return {};
}

export async function importProfileIdentity(session: ProfileRuntime, identity: string, preparingFiles: boolean) {
  if (!preparingFiles || !/^[0-9a-f-]{36}$/i.test(identity)) throw new Error("Profile import requires isolated storage preparation");
  const inspection = await session.harness.inspect(context);
  if (inspection.tasks.length || inspection.submissions.length) throw new Error("Backups containing pending actions cannot be imported");
  if ((await session.files.state()).pending.length) throw new Error("Backups containing pending file changes cannot be imported");
  await session.harness.commit(async tx => { (await tx.doc(ProfileIndex)).identity = identity; }, context);
  await importScheduleIdentity(session.harness, identity);
  return {};
}
