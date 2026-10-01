import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { runInNewContext } from "node:vm";

const source = readFileSync(
  resolve(import.meta.dir, "../../apps/ios/Ox/Host/Services/Web/ServiceBrowserActionSession.swift"),
  "utf8",
);

function captureScript(includeBodies: boolean) {
  const match = source.match(
    /private static func captureScript\(id: String, includeBodies: Bool\) -> String \{\n\s*#"""\n([\s\S]*?)\n\s*"""#\n\s*\}/,
  );
  expect(match).not.toBeNull();
  return match![1]
    .replaceAll("\\#(id)", "capture-test")
    .replaceAll('\\#(includeBodies ? "true" : "false")', String(includeBodies));
}

test("Browser capture never waits for response bodies and stops cleanly", async () => {
  let finishReading: (result: { done: boolean; value?: Uint8Array }) => void = () => {};
  const pendingRead = new Promise<{ done: boolean; value?: Uint8Array }>((resolveRead) => {
    finishReading = resolveRead;
  });
  const events: unknown[] = [];
  const response = {
    status: 200,
    headers: new Headers({ "content-type": "application/json" }),
    clone: () => ({
      body: {
        getReader: () => ({
          read: () => pendingRead,
          cancel: () => Promise.resolve(),
        }),
      },
    }),
  };
  const originalFetch = async () => response;
  const sandbox: Record<string, any> = {
    fetch: originalFetch,
    Headers,
    Request,
    URL,
    URLSearchParams,
    FormData,
    TextDecoder,
    setTimeout,
    clearTimeout,
    location: { href: "https://example.com/", hostname: "example.com" },
    webkit: {
      messageHandlers: {
        oxBrowserCapture: { postMessage: (event: unknown) => events.push(event) },
      },
    },
    addEventListener: () => {},
    removeEventListener: () => {},
  };

  runInNewContext(captureScript(true), sandbox);
  const result = await Promise.race([
    sandbox.fetch("https://example.com/stream"),
    Bun.sleep(50).then(() => "timed-out"),
  ]);
  expect(result).toBe(response);

  expect(sandbox.__oxCaptureControl.stop()).toBe(true);
  expect(sandbox.fetch).toBe(originalFetch);
  expect(sandbox.__oxCaptureControl).toBeUndefined();

  finishReading({ done: true });
  await Bun.sleep(0);
  expect(events).toEqual([]);
});
