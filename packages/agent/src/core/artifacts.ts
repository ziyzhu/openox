/** File bytes belong to the native Profile owner, never to Pi documents or SQL blobs.
 * Publication is write-once at a readable relative path. A failed metadata commit
 * leaves an unreferenced file; it must not make any previously referenced file change.
 */
export interface ArtifactRecord {
  path: string;
  size: number;
  sha256: string;
}
export interface ArtifactFiles {
  publish(path: string, bytes: Uint8Array): Promise<ArtifactRecord>;
  read(record: ArtifactRecord): Promise<Uint8Array>;
  flush(path: string): Promise<void>;
  close(): Promise<void>;
}
export function artifactPath(path: string): string {
  if (!/^artifacts\/[^./\\\0][^/\\\0]*$/u.test(path) || path.endsWith("/") || /[\x00-\x1f\x7f]/u.test(path) || new TextEncoder().encode(path.slice(10)).length > 240) {
    throw new Error("Expected a flat Profile-relative artifact filename");
  }
  return path;
}
export function artifactRecord(record: ArtifactRecord, path: string, size: number): ArtifactRecord {
  if (record.path !== artifactPath(path) || record.size !== size || !/^[a-f0-9]{64}$/.test(record.sha256)) {
    throw new Error("Invalid published artifact receipt");
  }
  return record;
}
