import type { ArtifactFiles } from "../../profile/artifacts";
import { fileRequest, readFile, stageFile } from "./files";

export function nativeArtifacts(): ArtifactFiles {
  return {
    publish: (path, bytes) => stageFile(bytes, path),
    read: record => readFile(record, "open"),
    verifyPayload: record => fileRequest<void>("payloadVerify", record),
    flush: path => fileRequest<void>("flush", { path }),
    close: () => fileRequest<void>("close"),
  };
}
