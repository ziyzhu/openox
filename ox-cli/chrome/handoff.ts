import {
  SIGN_IN_URL_ACTION_ID,
  BOT_CONTROL_STATE_ACTION_ID,
  BOT_CONTROL_URL_ACTION_ID,
  SIGN_IN_STATE_ACTION_ID,
} from "../service-manifest.ts";
import { chromeAttention, chromeDiagnostic } from "../lib.ts";
import { type ChromeBrowser } from "./browser.ts";
import { withChromeLock } from "./lock.ts";
import { readChromeMetadata, writeChromeMetadata } from "./metadata.ts";
import { type ChromeServiceSession } from "./service.ts";

type TargetInfo = {
  targetId: string;
  type: string;
  url: string;
};

export async function authenticateService(
  browser: ChromeBrowser,
  service: ChromeServiceSession,
  timeoutMs: number,
): Promise<{ signedIn: true }> {
  const state = await service.invoke(SIGN_IN_STATE_ACTION_ID, {}, true, Math.min(timeoutMs, 30_000)) as { signedIn?: unknown };
  if (state.signedIn === true) return { signedIn: true };
  const value = await service.invoke(SIGN_IN_URL_ACTION_ID, {}, true, Math.min(timeoutMs, 30_000)) as { url?: unknown };
  const url = validatedHandoffUrl(value.url);
  return withHandoff(browser, url, timeoutMs, "finish sign-in in Chrome", async () => {
    const current = await service.invoke(SIGN_IN_STATE_ACTION_ID, {}, true, Math.min(timeoutMs, 30_000)) as { signedIn?: unknown };
    return current.signedIn === true ? { signedIn: true as const } : undefined;
  });
}

export async function completeBotControl(
  browser: ChromeBrowser,
  service: ChromeServiceSession,
  args: Record<string, unknown>,
  timeoutMs: number,
): Promise<{ completed: true }> {
  const value = await service.invoke(BOT_CONTROL_URL_ACTION_ID, args, true, Math.min(timeoutMs, 30_000)) as { url?: unknown };
  const url = validatedHandoffUrl(value.url);
  return withHandoff(browser, url, timeoutMs, "finish verification in Chrome", async (pageUrl) => {
    try {
      const state = await service.invoke(
        BOT_CONTROL_STATE_ACTION_ID,
        { ...args, pageUrl },
        true,
        Math.min(timeoutMs, 30_000),
      ) as { ok?: unknown };
      return state.ok === true ? { completed: true as const } : undefined;
    } catch {
      return undefined;
    }
  });
}

async function withHandoff<T>(
  browser: ChromeBrowser,
  url: string,
  timeoutMs: number,
  instruction: string,
  probe: (pageUrl: string) => Promise<T | undefined>,
): Promise<T> {
  return withChromeLock(browser.profileDir, "handoff", timeoutMs, "Chrome handoff is busy", async () => {
    const targetId = await openHandoffTarget(browser, url, timeoutMs);
    await browser.cdp.send("Target.activateTarget", { targetId });
    chromeAttention(instruction);
    const deadline = performance.now() + timeoutMs;
    while (performance.now() < deadline) {
      const targets = await browser.cdp.send<{ targetInfos: TargetInfo[] }>("Target.getTargets");
      const target = targets.targetInfos.find((candidate) => candidate.targetId === targetId);
      if (!target) throw new Error("Chrome handoff was cancelled");
      const result = await probe(target.url);
      if (result !== undefined) return result;
      await Bun.sleep(1_000);
    }
    throw new Error(`Chrome handoff timed out after ${timeoutMs}ms`);
  });
}

async function openHandoffTarget(browser: ChromeBrowser, url: string, timeoutMs: number): Promise<string> {
  const metadata = await readChromeMetadata(browser.profileDir, browser.endpoint.path);
  const targets = await browser.cdp.send<{ targetInfos: TargetInfo[] }>("Target.getTargets");
  const existing = targets.targetInfos.find((candidate) =>
    candidate.targetId === metadata.handoffTargetId && candidate.type === "page"
  );
  if (existing) {
    const attached = await browser.cdp.send<{ sessionId: string }>("Target.attachToTarget", {
      targetId: existing.targetId,
      flatten: true,
    });
    try {
      const result = await browser.cdp.send<{ errorText?: string }>(
        "Page.navigate",
        { url },
        attached.sessionId,
        timeoutMs,
      );
      if (result.errorText) throw new Error(`Chrome handoff navigation failed: ${result.errorText}`);
    } finally {
      await browser.cdp.send("Target.detachFromTarget", { sessionId: attached.sessionId }).catch(() => {});
    }
    chromeDiagnostic("handoff target disposition=reused");
    return existing.targetId;
  }
  const created = await browser.cdp.send<{ targetId: string }>("Target.createTarget", {
    url,
    newWindow: false,
    background: false,
  });
  metadata.handoffTargetId = created.targetId;
  await writeChromeMetadata(browser.profileDir, metadata);
  chromeDiagnostic("handoff target disposition=created");
  return created.targetId;
}

function validatedHandoffUrl(value: unknown): string {
  if (typeof value !== "string") throw new Error("service handoff returned no URL");
  const url = new URL(value);
  if (url.protocol !== "https:" && !(url.protocol === "http:" && isLoopback(url.hostname))) {
    throw new Error("service handoff returned an unsafe URL");
  }
  if (url.protocol === "https:" && isPrivateHost(url.hostname)) {
    throw new Error("service handoff returned a private-network URL");
  }
  return url.toString();
}

function isLoopback(host: string): boolean {
  return host === "localhost" || host === "::1" || host === "[::1]" || /^127(?:\.\d{1,3}){3}$/.test(host);
}

function isPrivateHost(host: string): boolean {
  if (host === "localhost" || host.endsWith(".local")) return true;
  const ipv6 = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (ipv6 === "::1" || ipv6.startsWith("fc") || ipv6.startsWith("fd") || ipv6.startsWith("fe8") || ipv6.startsWith("fe9") || ipv6.startsWith("fea") || ipv6.startsWith("feb")) return true;
  const match = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (!match) return false;
  const first = Number(match[1]);
  const second = Number(match[2]);
  return first === 10
    || first === 127
    || (first === 169 && second === 254)
    || (first === 172 && second >= 16 && second <= 31)
    || (first === 192 && second === 168);
}
