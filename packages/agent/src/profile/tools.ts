import { defineExtension, section } from "@earendil-works/pi-durable";
import type { ProfileFiles } from "./files";

export function profileTools(files: ProfileFiles, physicalFiles = false) {
  return defineExtension({ name: "ox-profile-files", sections: [
    section("filesystem_mounts", () => "Use ox.fs through execute as the only filesystem API. Discover this host's mounted paths with ox.fs.list. read uses one-indexed offset/limit and bounded output; follow nextOffset and diagnostics to continue. Host permissions and source ownership remain authoritative."),
    section("profile_files", () => physicalFiles
      ? "The Profile contains mutable files and persisted directories. Conversation files belong under conversations/<id>/; shared files may use ordinary root folders. Messages reference current contents, not historical versions. Move retires references at the old path and transfers ownership to the destination. Deleting a conversation removes its owned files; shared files survive. Private storage is inaccessible. Shell execution is unavailable."
      : files.immutableFiles
      ? "Legacy files are immutable: use a distinct filename for each new version. Existing files cannot be overwritten or edited. Historical references keep their original bytes. Shell execution is unavailable."
      : "This Session uses an isolated mutable fixture. Shell execution is unavailable."),
  ] });
}
