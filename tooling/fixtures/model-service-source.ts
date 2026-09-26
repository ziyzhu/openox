import { readFileSync } from "node:fs";

export function serviceSource(domain: string) {
  return readFileSync(`repositories/builtin/web/${domain}/actions.js`, "utf8");
}

export function modelSiteSource(domain: string) {
  const source = serviceSource(domain);
  const start = source.indexOf("function createModelSite(send)");
  const end = source.indexOf("async function modelCatalog()", start);
  if (start < 0 || end < 0) throw new Error(`Missing model service implementation: ${domain}`);
  return source.slice(start, end);
}
