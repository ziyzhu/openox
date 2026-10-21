import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import { ROOT } from "../../../lib.ts";
import { catalog } from "../../../../packages/agent/evals/stubs";

async function sourceFunctions(): Promise<string[]> {
  const names = new Set<string>();
  for (const path of await readdir(join(ROOT, "apps/shared/Host"), { recursive: true })) {
    const filename = path.split("/").at(-1)!;
    if (!/^Ox.*\.swift$/.test(filename)) continue;
    const source = await readFile(join(ROOT, "apps/shared/Host", path), "utf8");
    if (!source.includes("OxFunction(")) continue;
    for (const match of source.matchAll(/"(ox\.[a-z]+(?:\.[A-Za-z]+)+)"/g)) names.add(match[1]!);
    if (filename === "OxFileSystem.swift") for (const match of source.matchAll(/__nativeFS\('([A-Za-z]+)'/g)) names.add(`ox.fs.${match[1]}`);
  }
  const browser = await readFile(join(ROOT, "apps/shared/Host/Services/Web/BrowserFunctionCatalog.swift"), "utf8");
  for (const match of browser.matchAll(/id: "([A-Za-z]+)"/g)) names.add(`ox.web.browser.${match[1]}`);
  return [...names].sort();
}

export async function validateCatalog(): Promise<number> {
  const functions = await sourceFunctions();
  const stubbed = Object.keys(catalog).sort();
  if (JSON.stringify(functions) !== JSON.stringify(stubbed)) throw new Error(`Stub function catalog differs from native source: missing ${functions.filter(name => !stubbed.includes(name)).join(", ")}; stale ${stubbed.filter(name => !functions.includes(name)).join(", ")}`);
  return functions.length;
}
