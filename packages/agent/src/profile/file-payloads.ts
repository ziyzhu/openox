import type { FileRecord } from "./file-record";

export interface FilePayloadStore {
  publish(path: string, bytes: Uint8Array): Promise<FileRecord>;
  read(record: FileRecord): Promise<Uint8Array>;
  verifyPayload?(record: FileRecord): Promise<void>;
  flush(path: string): Promise<void>;
  close(): Promise<void>;
}
export function legacyFilePath(path: string): string {
  if (!/^artifacts\/[^./\\\0][^/\\\0]*$/u.test(path) || path.endsWith("/") || /[\x00-\x1f\x7f]/u.test(path) || new TextEncoder().encode(path.slice(10)).length > 240) {
    throw new Error("Expected a flat legacy Profile-relative file name");
  }
  return path;
}
export function validateFileRecord(record: FileRecord, path: string, size: number): FileRecord {
  if (record.path !== legacyFilePath(path) || record.size !== size || !/^[a-f0-9]{64}$/.test(record.sha256)) {
    throw new Error("Invalid published file receipt");
  }
  return record;
}
