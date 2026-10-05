import { defineExtension, defineTool, wrapTool, section, type ConversationId, type ToolRegistration } from "@earendil-works/pi-durable";
import { createReadTool, createWriteTool, createEditTool } from "@earendil-works/pi-durable/tools";
import { canonical, type ProfileFiles } from "./profile-files";

export type AuthorizeFile = (conversationId: ConversationId, action: "write" | "edit", path: string, signal?: AbortSignal) => Promise<void>;

/** Shared filesystem behavior; the host remains responsible for permission enforcement. */
export function profileTools(files: ProfileFiles, authorize: AuthorizeFile) {
  const write = createWriteTool();
  const read = createReadTool();
  const edit = defineTool({
    ...createEditTool(), replay: "unsafe", execute: async (args, api, context) => {
      await authorize(api.conversationId, "edit", canonical(args.path), context.abortSignal);
      await files.edit(args.path, args.edits);
      return { content: [{ type: "text", text: `Edited ${canonical(args.path)}` }], details: { diff: "", patch: "" } };
    },
  });
  return defineExtension<ToolRegistration>({ name: "ox-profile-files", tools: [read, write, edit],
    sections: [section("profile_files", () => files.immutableArtifacts
      ? "MEMORY.md, SOUL.md and skills/ are document-backed and editable. artifacts/<filename> contains immutable physical files: use distinct readable filenames for new versions. write never overwrites an artifact; edit on an artifact is unavailable. Read the old file, then write edited content under a new filename. Historical references keep their original bytes. Shell execution is unavailable."
      : "These files belong to an isolated mutable cache fixture, not the user's Profile. Shell execution is unavailable.")],
    wraps: [wrapTool(read, tool => ({ ...tool, execute: async (args, api, context) => {
      const path = canonical(args.path);
      if (files.immutableArtifacts && /^artifacts\/[^/]+\.(png|jpe?g|gif|webp|hei[cf]|bmp|tiff?)$/i.test(path)) {
        // Verify physical bytes/digest before committing a reference. The native
        // model adapter resolves it in its immutable owning Profile scope. Never
        // duplicate image Base64 into the transcript or expose container URLs.
        const value = await files.read(path);
        if (!(value instanceof Uint8Array)) throw new Error("Image artifact must contain binary bytes");
        return { content: [{ type: "text" as const, text: `[Attachment: ${path}]`,
          oxAttachment: path.slice("artifacts/".length), oxProfileID: files.identity }] };
      }
      return read.execute(args, api, context);
    } })), wrapTool(write, tool => ({ ...tool, replay: "unsafe", execute: async (args, api, context) => {
      await authorize(api.conversationId, "write", canonical(args.path), context.abortSignal);
      return write.execute(args, api, context);
    } }))],
  });
}
