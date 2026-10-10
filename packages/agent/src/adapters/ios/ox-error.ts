import { FileError } from "@earendil-works/pi-durable/env";

export interface OxErrorFields { code: string; message: string; recovery: string }
const fallbackRecovery = "Inspect the relevant resource and help. Effects may have occurred; verify state before retrying a write. Do not repeat a cancelled or denied user interaction.";
const fileRecovery: Record<FileError["code"], string> = {
  aborted: "Stop. Do not repeat the operation unless the user asks; inspect any possible effects before retrying a write.",
  not_found: "Use ox.fs.list on the parent directory to discover an existing path before trying again.",
  permission_denied: "Do not bypass source permissions. Use a writable destination, or ask the user to grant access through the normal interface.",
  not_directory: "Use ox.fs.list to locate a directory, or ox.fs.read to read a file.",
  is_directory: "Use ox.fs.list to inspect the directory and select a readable file.",
  invalid: "Inspect the operation's help and correct the reported input. For edits, read the file again and build unique, non-overlapping replacements.",
  not_supported: "Inspect the operation's help and path with ox.fs.list. Choose a supported operation or writable destination; do not bypass source permissions.",
  unknown: fallbackRecovery,
};

export function oxError(error: unknown): Error & OxErrorFields {
  if (error instanceof FileError && error.code === "unknown" && error.cause instanceof Error) return oxError(error.cause);
  const source = error instanceof Error ? error : new Error(String(error));
  const fields = source as Partial<OxErrorFields>;
  const sourceCode = typeof fields.code === "string" ? fields.code : "operation_failed";
  const code = sourceCode === "invalid" ? "invalid_argument" : sourceCode === "aborted" ? "cancelled" : sourceCode === "unknown" ? "operation_failed" : sourceCode;
  const recovery = typeof fields.recovery === "string" ? fields.recovery : error instanceof FileError ? fileRecovery[error.code] : fallbackRecovery;
  const message = error instanceof FileError && error.path ? `${source.message}: ${error.path}` : source.message;
  return Object.assign(new Error(message), { code, recovery });
}
