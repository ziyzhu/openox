import "./encoding";
import { URL, URLSearchParams } from "whatwg-url";
import { validateRepositoryManifest } from "@openox/protocol/manifest";
export { inspectInstaller } from "@openox/protocol/installer";

Object.assign(globalThis, { URL, URLSearchParams });

export function validateManifest(manifest: unknown, identity?: string): string[] {
  const result = validateRepositoryManifest(manifest, identity);
  return result.ok ? [] : result.errors;
}
