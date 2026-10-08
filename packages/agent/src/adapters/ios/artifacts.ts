import type { ArtifactFiles, ArtifactRecord } from "../../profile/artifacts";
import { native } from "./bridge";

const chunkSize = 128 * 1024;
/** The native owner pins a directory descriptor and each opened file, not container URLs. */
export function nativeArtifacts(): ArtifactFiles {
  const request = <T>(op: string, params: object = {}) => native<T>("artifacts", { op, ...params });
  return {
    async publish(path, bytes) {
      const token = await request<string>("begin", { path, size: bytes.length });
      try {
        for (let offset = 0; offset < bytes.length; offset += chunkSize) {
          await request("write", { token, offset, bytes: Array.from(bytes.subarray(offset, offset + chunkSize)) });
        }
        return await request<ArtifactRecord>("publish", { token });
      } finally { await request("release", { token }); }
    },
    async read(record) {
      const token = await request<string>("open", record);
      try {
        const bytes = new Uint8Array(record.size);
        for (let offset = 0; offset < bytes.length; offset += chunkSize) {
          const chunk = await request<number[]>("read", { token, offset, length: Math.min(chunkSize, bytes.length - offset) });
          if (chunk.length !== Math.min(chunkSize, bytes.length - offset) || chunk.some(byte => !Number.isInteger(byte) || byte < 0 || byte > 255)) {
            throw new Error("Invalid native artifact read");
          }
          bytes.set(chunk, offset);
        }
        await request("verify", { token, sha256: record.sha256 });
        return bytes;
      } finally { await request("release", { token }); }
    },
    async verifyPayload(record) { await request("payloadVerify", record); },
    async readPayload(record, offset, length) { return request<string>("payloadRead", { ...record, offset, length }); },
    async flush(path) { await request("flush", { path }); },
    async close() { await request("close"); },
  };
}
