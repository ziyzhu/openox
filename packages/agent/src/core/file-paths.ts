import { FileError } from "@earendil-works/pi-durable/env";

export function canonical(path: string): string {
  const relative = path.startsWith("/") ? path.slice(1) : path;
  if (relative === "" || relative === ".") return "";
  if (relative.includes("\\") || relative.includes("\0") || relative.split("/").some(part => !part || part === "." || part === ".." || part.startsWith("."))) {
    throw new FileError("invalid", "Invalid virtual path", path);
  }
  return relative;
}
