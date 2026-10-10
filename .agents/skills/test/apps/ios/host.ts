export async function waitForHost(endpoint: string, describe: () => Promise<unknown>, timeout = 30_000): Promise<void> {
  const deadline = Date.now() + timeout;
  let failure: unknown;
  while (Date.now() < deadline) {
    try { await describe(); return; }
    catch (error) { failure = error; }
    await Bun.sleep(200);
  }
  throw new Error(`Host unavailable at ${endpoint}`, { cause: failure });
}
