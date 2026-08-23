import { join } from "node:path";

export async function virtualMachineHelperNames(root: string): Promise<string[]> {
  const directory = join(root, "ios/ios/VirtualMachine/OxFunctions");
  const catalogSource = await Bun.file(join(directory, "OxFunctionCatalog.swift")).text();
  const owners = [...catalogSource.matchAll(/\b(Ox[A-Za-z0-9]+)\.function\b/g)].map((match) => match[1]!);
  if (owners.length === 0) throw new Error("OxFunctionCatalog.all has no function owners");
  const sources = await Promise.all([...new Set(owners)].map(async (owner) => {
    const file = Bun.file(join(directory, `${owner}.swift`));
    if (await file.exists()) return await file.text();
    throw new Error(`Ox function source does not exist: ${owner}.swift`);
  }));
  const names = new Set<string>();
  const helper = "(ox\\.[A-Za-z][A-Za-z0-9]*(?:\\.[A-Za-z][A-Za-z0-9]*)*)";
  const patterns = [
    new RegExp(`(?:entry|builder)\\(\\s*"${helper}"`, "g"),
    new RegExp(`\\(\\s*"${helper}"\\s*,\\s*\\.object\\s*\\(`, "g"),
    new RegExp(`\\bname:\\s*"${helper}"`, "g"),
  ];
  for (const source of sources) {
    for (const pattern of patterns) {
      for (const match of source.matchAll(pattern)) names.add(match[1]!);
    }
  }
  return [...names].sort();
}
