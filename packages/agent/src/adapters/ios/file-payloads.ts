import type { FilePayloadStore } from "../../profile/file-payloads";
import { fileRequest, readFile, stageFile } from "./files";

export function nativeFilePayloads(): FilePayloadStore {
  return {
    publish: (path, bytes) => stageFile(bytes, path),
    read: record => readFile(record, "open"),
    verifyPayload: record => fileRequest<void>("payloadVerify", record),
    flush: path => fileRequest<void>("flush", { path }),
    close: () => fileRequest<void>("close"),
  };
}
