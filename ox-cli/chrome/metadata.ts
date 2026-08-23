import { join } from "node:path";

export type ChromeServiceRecord = {
  targetId: string;
  bundleHash: string;
};

export type ChromeRuntimeMetadata = {
  version: 1;
  browserInstance: string;
  services: Record<string, ChromeServiceRecord>;
  handoffTargetId?: string;
};

export async function readChromeMetadata(
  profileDir: string,
  browserInstance: string,
): Promise<ChromeRuntimeMetadata> {
  const empty = (): ChromeRuntimeMetadata => ({ version: 1, browserInstance, services: {} });
  const file = Bun.file(join(profileDir, "runtime.json"));
  if (!await file.exists()) return empty();
  try {
    const value = await file.json() as Partial<ChromeRuntimeMetadata>;
    if (value.version !== 1 || value.browserInstance !== browserInstance || !value.services) return empty();
    return {
      version: 1,
      browserInstance,
      services: value.services,
      handoffTargetId: typeof value.handoffTargetId === "string" ? value.handoffTargetId : undefined,
    };
  } catch {
    return empty();
  }
}

export async function writeChromeMetadata(profileDir: string, metadata: ChromeRuntimeMetadata): Promise<void> {
  await Bun.write(join(profileDir, "runtime.json"), `${JSON.stringify(metadata, null, 2)}\n`);
}
