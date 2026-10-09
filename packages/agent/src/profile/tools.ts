import { defineExtension, section } from "@earendil-works/pi-durable";
import type { ProfileFiles } from "./files";

export function profileTools(files: ProfileFiles) {
  return defineExtension({ name: "ox-profile-files", sections: [
    section("filesystem_mounts", () => "Use ox.fs through execute as the only filesystem API. Discover this host's mounted paths with ox.fs.list. read uses one-indexed offset/limit and bounded output; follow nextOffset and diagnostics to continue. Host permissions and source ownership remain authoritative."),
    section("profile_files", () => files.immutableArtifacts
      ? "Artifacts are immutable physical files: use a distinct filename for each new version. Existing artifacts cannot be overwritten or edited. Historical references keep their original bytes. Shell execution is unavailable."
      : "This Session uses an isolated mutable fixture. Shell execution is unavailable."),
  ] });
}
