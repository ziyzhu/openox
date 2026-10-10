import type { FileRecord } from "../../profile/file-record";
import type { WorkspaceBackend, WorkspaceObservation } from "../../profile/workspace";
import { native } from "./bridge";

const chunkSize = 128 * 1024;
export const fileRequest = <T>(op: string, params: object = {}) => native<T>("files", { op, ...params });
export async function readFile(record: FileRecord, op = "workspaceOpen") {
  const token = await fileRequest<string>(op, record);
  try {
    const bytes = new Uint8Array(record.size);
    for (let offset = 0; offset < bytes.length; offset += chunkSize) {
      const length = Math.min(chunkSize, bytes.length - offset);
      const chunk = await fileRequest<number[]>("read", { token, offset, length });
      if (chunk.length !== length || chunk.some(byte => !Number.isInteger(byte) || byte < 0 || byte > 255)) throw new Error("Invalid native file read");
      bytes.set(chunk, offset);
    }
    await fileRequest("verify", { token, sha256: record.sha256 });
    return bytes;
  } finally { await fileRequest("release", { token }); }
}
export async function stageFile(bytes: Uint8Array, path?: string) {
  const token = await fileRequest<string>(path ? "begin" : "workspaceStage", { path, size: bytes.length });
  try {
    for (let offset = 0; offset < bytes.length; offset += chunkSize) {
      await fileRequest("write", { token, offset, bytes: Array.from(bytes.subarray(offset, offset + chunkSize)) });
    }
    return await fileRequest<FileRecord>("publish", { token });
  } finally { await fileRequest("release", { token }); }
}
export function nativeFiles(): WorkspaceBackend {
  return {
    identifier: () => native<string>("uuid", {}),
    inventory: () => fileRequest<string[]>("inventory"),
    verify: record => fileRequest<void>("workspaceVerify", record),
    sweep: () => fileRequest<void>("workspaceSweep"),
    stage: bytes => stageFile(bytes),
    apply: operations => fileRequest<void | { conflict: boolean }>("workspaceApply", { operations }),
    snapshot: files => fileRequest<{ files: WorkspaceObservation[]; directories: string[] }>("workspaceInventory", { files: files.map(({ path, sha256, binary, stamp }) => ({ path, sha256, binary, stamp })) }),
    validate: operations => fileRequest<void>("workspaceValidate", { operations }),
    read: record => readFile(record),
    readRange: (record, offset, length) => fileRequest<string>("workspaceReadRange", { ...record, offset, length }),
    close: () => fileRequest<void>("close"),
  };
}
