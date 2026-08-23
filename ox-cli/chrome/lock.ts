import { closeSync, mkdirSync, openSync, statSync, unlinkSync, writeSync } from "node:fs";
import { join } from "node:path";

export async function withServiceLock<T>(
  profileDir: string,
  domain: string,
  timeoutMs: number,
  operation: () => Promise<T>,
): Promise<T> {
  return withChromeLock(profileDir, domain, timeoutMs, `service ${domain} is busy`, operation);
}

export async function withChromeLock<T>(
  profileDir: string,
  key: string,
  timeoutMs: number,
  busyMessage: string,
  operation: () => Promise<T>,
): Promise<T> {
  const directory = join(profileDir, "locks");
  mkdirSync(directory, { recursive: true });
  const lockName = new Bun.CryptoHasher("sha256").update(key.toLowerCase()).digest("hex").slice(0, 24);
  const path = join(directory, `${lockName}.lock`);
  const deadline = performance.now() + timeoutMs;
  let descriptor: number | undefined;
  while (descriptor === undefined) {
    try {
      descriptor = openSync(path, "wx", 0o600);
      writeSync(descriptor, `${process.pid}\n`);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      if (isStale(path)) {
        try { unlinkSync(path); } catch {}
        continue;
      }
      if (performance.now() >= deadline) throw new Error(busyMessage);
      await Bun.sleep(50);
    }
  }
  try {
    return await operation();
  } finally {
    closeSync(descriptor);
    try { unlinkSync(path); } catch {}
  }
}

function isStale(path: string): boolean {
  try {
    return Date.now() - statSync(path).mtimeMs > 10 * 60 * 1_000;
  } catch {
    return false;
  }
}
