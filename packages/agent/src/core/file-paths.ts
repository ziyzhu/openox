import { FileError } from "@earendil-works/pi-durable/env";

export function canonical(path: string): string {
  const relative = path.startsWith("/") ? path.slice(1) : path;
  if (relative === "" || relative === ".") return "";
  if (relative.includes("\\") || relative.includes("\0") || relative.split("/").some(part => !part || part === "." || part === ".." || [".ox", ".files"].includes(part.toLowerCase()) || part.toLowerCase().startsWith(".ox-stage-") || part.toLowerCase().startsWith(".stage-"))) {
    throw new FileError("invalid", "Invalid virtual path", path);
  }
  if (relative.toLowerCase() === "artifacts/.saved.json") throw new FileError("permission_denied", "Private file metadata is not accessible", path);
  return relative;
}
