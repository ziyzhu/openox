import { createServer, createConnection } from "node:net";
import { existsSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";
import type { ServiceReplayCase } from "./fixtures.ts";

const MITMPROXY_VERSION = "12.2.3";

export type ReplayProxy = {
  port: number;
  caCertificatePath: string;
  stop: () => Promise<void>;
};

export type RecordingProxy = ReplayProxy & {
  harPath: string;
};

export type RecordedRequest = {
  method: string;
  url: string;
};

export async function startReplayProxy(
  fixtures: ServiceReplayCase[],
  tempDir: string,
  requestedPort?: number,
  configurationDir = join(tempDir, "mitmproxy"),
): Promise<ReplayProxy> {
  if (fixtures.length === 0) throw new Error("cannot start replay proxy without fixtures");
  const port = requestedPort ?? await availablePort();
  const harPath = join(tempDir, `replay-${crypto.randomUUID()}.har`);
  await Bun.write(harPath, JSON.stringify(mergeHars(fixtures)));
  const command = mitmdumpCommand();
  const ignoreQuery = unique(fixtures.flatMap((fixture) => fixture.replay.ignoreQueryParameters));
  const ignoreBody = unique(fixtures.flatMap((fixture) => fixture.replay.ignoreBodyParameters));
  const matchHeaders = unique(fixtures.flatMap((fixture) => fixture.replay.matchHeaders));
  const args = [
    ...command.slice(1),
    "--listen-host", "127.0.0.1",
    "--listen-port", String(port),
    "--server-replay", harPath,
    "--set", "connection_strategy=lazy",
    "--set", "server_replay_extra=kill",
    "--set", "server_replay_refresh=true",
    "--set", "termlog_verbosity=error",
    "--set", "flow_detail=0",
    "--set", `confdir=${configurationDir}`,
  ];
  for (const name of ignoreQuery) args.push("--set", `server_replay_ignore_params=${name}`);
  for (const name of ignoreBody) args.push("--set", `server_replay_ignore_payload_params=${name}`);
  for (const name of matchHeaders) args.push("--set", `server_replay_use_headers=${name}`);
  const process = Bun.spawn({
    cmd: [command[0]!, ...args],
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const stderr = new Response(process.stderr).text();
  try {
    await waitForPort(port, process.exited, 30_000);
  } catch (error) {
    process.kill("SIGTERM");
    await process.exited;
    const detail = (await stderr).trim();
    throw new Error(`${String((error as Error).message ?? error)}${detail ? `: ${detail}` : ""}`);
  }
  return {
    port,
    caCertificatePath: join(configurationDir, "mitmproxy-ca-cert.pem"),
    stop: async () => {
      process.kill("SIGTERM");
      await process.exited;
      await stderr;
    },
  };
}

export async function startRecordingProxy(tempDir: string, requestedPort?: number): Promise<RecordingProxy> {
  const port = requestedPort ?? await availablePort();
  const harPath = join(tempDir, `recording-${crypto.randomUUID()}.har`);
  const command = mitmdumpCommand();
  const process = Bun.spawn({
    cmd: [
      ...command,
      "--listen-host", "127.0.0.1",
      "--listen-port", String(port),
      "--set", `hardump=${harPath}`,
      "--set", "termlog_verbosity=error",
      "--set", "flow_detail=0",
      "--set", `confdir=${join(tempDir, "mitmproxy")}`,
    ],
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const stderr = new Response(process.stderr).text();
  try {
    await waitForPort(port, process.exited, 30_000);
  } catch (error) {
    process.kill("SIGTERM");
    await process.exited;
    const detail = (await stderr).trim();
    throw new Error(`${String((error as Error).message ?? error)}${detail ? `: ${detail}` : ""}`);
  }
  return {
    port,
    caCertificatePath: join(tempDir, "mitmproxy", "mitmproxy-ca-cert.pem"),
    harPath,
    stop: async () => {
      process.kill("SIGINT");
      await process.exited;
      const detail = (await stderr).trim();
      if (!existsSync(harPath)) throw new Error(`mitmdump did not write ${harPath}${detail ? `: ${detail}` : ""}`);
    },
  };
}

export function sanitizeRecordedHar(raw: unknown): {
  har: Record<string, unknown>;
  ignoreQueryParameters: string[];
  ignoreBodyParameters: string[];
} {
  const har = structuredClone(raw) as any;
  if (!Array.isArray(har?.log?.entries) || har.log.entries.length === 0) {
    throw new Error("recorded HAR has no entries");
  }
  const ignoreQueryParameters = new Set<string>();
  const ignoreBodyParameters = new Set<string>();
  for (const entry of har.log.entries) {
    for (const side of [entry.request, entry.response]) {
      preserveRedactedPresence(side);
    }
    if (typeof entry.request?.url === "string") {
      const url = new URL(entry.request.url);
      for (const name of [...url.searchParams.keys()]) {
        if (!SECRET_PARAMETER.test(name)) continue;
        ignoreQueryParameters.add(name);
        url.searchParams.set(name, "[REDACTED]");
      }
      entry.request.url = url.toString();
      if (Array.isArray(entry.request.queryString)) {
        entry.request.queryString = entry.request.queryString.map((item: any) => {
          if (!SECRET_PARAMETER.test(String(item?.name ?? ""))) return item;
          return { ...item, value: "[REDACTED]" };
        });
      }
    }
    const postData = entry.request?.postData;
    if (typeof postData?.text === "string" && /application\/x-www-form-urlencoded/i.test(postData.mimeType ?? "")) {
      const form = new URLSearchParams(postData.text);
      for (const name of [...form.keys()]) {
        if (!SECRET_PARAMETER.test(name)) continue;
        ignoreBodyParameters.add(name);
        form.set(name, "[REDACTED]");
      }
      postData.text = form.toString();
    }
    sanitizeJsonContent(postData, ignoreBodyParameters);
    sanitizeJsonContent(entry.response?.content);
  }
  assertNoReusableSecrets(har);
  return {
    har,
    ignoreQueryParameters: [...ignoreQueryParameters].sort(),
    ignoreBodyParameters: [...ignoreBodyParameters].sort(),
  };
}

export function selectRecordedRequestOccurrences(raw: unknown, requests: RecordedRequest[]): Record<string, unknown> {
  const har = structuredClone(raw) as any;
  if (!Array.isArray(har?.log?.entries)) throw new Error("recorded HAR has no entries");
  const remaining = new Map<string, number>();
  for (const request of requests) {
    const key = requestKey(request.method, request.url);
    remaining.set(key, (remaining.get(key) ?? 0) + 1);
  }
  har.log.entries = har.log.entries.filter((entry: any) => {
    const key = requestKey(String(entry?.request?.method ?? ""), String(entry?.request?.url ?? ""));
    const count = remaining.get(key) ?? 0;
    if (count === 0) return false;
    remaining.set(key, count - 1);
    return true;
  });
  const missing = [...remaining.entries()].filter(([, count]) => count > 0);
  if (missing.length) {
    throw new Error(`recorded HAR is missing ${missing.map(([key, count]) => `${count}x ${key}`).join(", ")}`);
  }
  return har;
}

export function selectRecordedRequests(raw: unknown, requests: RecordedRequest[]): Record<string, unknown> {
  const har = structuredClone(raw) as any;
  if (!Array.isArray(har?.log?.entries)) throw new Error("recorded HAR has no entries");
  const selected = new Set(requests.map(({ method, url }) => requestKey(method, url)));
  har.log.entries = har.log.entries.filter((entry: any) => selected.has(requestKey(
    String(entry?.request?.method ?? ""),
    String(entry?.request?.url ?? ""),
  )));
  if (har.log.entries.length === 0) throw new Error("recorded HAR contains no requests from the service page");
  return har;
}

export function assertNoReusableSecrets(value: unknown): void {
  if (typeof value === "string") {
    for (const pattern of SECRET_PATTERNS) {
      if (pattern.test(value)) throw new Error(`recorded HAR still matches secret pattern ${pattern}`);
    }
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) assertNoReusableSecrets(item);
    return;
  }
  if (value && typeof value === "object") {
    for (const item of Object.values(value)) assertNoReusableSecrets(item);
  }
}

function mitmdumpCommand(): string[] {
  const configured = process.env.OX_MITMDUMP;
  if (configured) {
    if (!existsSync(configured)) throw new Error(`OX_MITMDUMP does not exist: ${configured}`);
    return [configured];
  }
  const installed = Bun.which("mitmdump");
  if (installed) return [installed];
  const uvx = Bun.which("uvx");
  if (uvx) return [uvx, "--from", `mitmproxy==${MITMPROXY_VERSION}`, "mitmdump"];
  throw new Error("mitmdump is required; install mitmproxy or set OX_MITMDUMP");
}

function mergeHars(fixtures: ServiceReplayCase[]): Record<string, unknown> {
  const entries = fixtures.flatMap((fixture) => {
    const har = JSON.parse(readFileSync(fixture.harPath, "utf8")) as {
      log?: { entries?: Array<{ pageref?: unknown }> };
    };
    if (!Array.isArray(har.log?.entries)) throw new Error(`${basename(fixture.harPath)} has no HAR entries`);
    return fixture.scope
      ? har.log.entries.filter((entry) => entry.pageref === fixture.scope)
      : har.log.entries;
  });
  return {
    log: {
      version: "1.2",
      creator: { name: "service replay", version: "1" },
      pages: [],
      entries,
    },
  };
}

function unique(values: string[]): string[] {
  return [...new Set(values)].sort();
}

function requestKey(method: string, url: string): string {
  let normalized = url;
  try { normalized = new URL(url).toString(); }
  catch {}
  return `${method.toUpperCase()} ${normalized}`;
}

function availablePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close();
        reject(new Error("failed to allocate replay proxy port"));
        return;
      }
      server.close((error) => error ? reject(error) : resolve(address.port));
    });
  });
}

async function waitForPort(port: number, exited: Promise<number>, timeoutMs: number): Promise<void> {
  const deadline = performance.now() + timeoutMs;
  while (performance.now() < deadline) {
    const result = await Promise.race([
      connect(port).then(() => "ready" as const, () => "retry" as const),
      exited.then((code) => ({ code })),
      Bun.sleep(50).then(() => "retry" as const),
    ]);
    if (result === "ready") return;
    if (typeof result === "object") throw new Error(`mitmdump exited ${result.code} before listening`);
  }
  throw new Error(`mitmdump did not listen within ${timeoutMs}ms`);
}

function connect(port: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const socket = createConnection({ host: "127.0.0.1", port });
    socket.setTimeout(100);
    socket.once("connect", () => {
      socket.destroy();
      resolve();
    });
    socket.once("timeout", () => {
      socket.destroy();
      reject(new Error("connection timed out"));
    });
    socket.once("error", reject);
  });
}

const SECRET_HEADERS = new Set([
  "authorization",
  "cookie",
  "proxy-authorization",
  "set-cookie",
  "x-api-key",
  "x-auth-token",
  "x-csrf-token",
  "x-xsrf-token",
  "shopify-storefront-private-token",
  "x-rebuy-user-token",
  "x-recharge-access-token",
  "x-recharge-storefront-access-token",
  "x-shopify-storefront-access-token",
]);

const SECRET_PARAMETER = /(?:^|_)(?:access_?token|api_?key|auth|code|csrf|key|password|secret|session|signature|state|token|xsrf)(?:$|_)/i;

const SECRET_PATTERNS = [
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  /\bBearer\s+[A-Za-z0-9._~+/=-]{12,}/i,
  /"(?:access_?token|api_?key|password|refresh_?token|secret)"\s*:\s*"(?!\[REDACTED\]|fixture-)[^"]+"/i,
];

function isSecretHeader(name: string): boolean {
  const normalized = name.toLowerCase();
  return SECRET_HEADERS.has(normalized) || SECRET_PARAMETER.test(normalized.replace(/-/g, "_"));
}

function preserveRedactedPresence(side: any): void {
  if (!side || typeof side !== "object") return;
  const headers = Array.isArray(side.headers) ? side.headers : [];
  const cookies = Array.isArray(side.cookies) ? side.cookies : [];
  const previous = side._oxRedactions && typeof side._oxRedactions === "object"
    ? side._oxRedactions
    : {};
  const redactedHeaders = redactedPresence([
    ...(Array.isArray(previous.headers) ? previous.headers : []),
    ...headers.filter((header: any) => isSecretHeader(String(header?.name ?? ""))),
  ]);
  const redactedCookies = redactedPresence([
    ...(Array.isArray(previous.cookies) ? previous.cookies : []),
    ...cookies,
  ]);
  side.headers = headers.filter((header: any) => !isSecretHeader(String(header?.name ?? "")));
  side.cookies = [];
  delete side._oxRedactions;
  if (redactedHeaders.length === 0 && redactedCookies.length === 0) return;
  side._oxRedactions = {
    headers: redactedHeaders,
    cookies: redactedCookies,
  };
}

function redactedPresence(values: any[]): Array<{ name: string; value: string }> {
  return [...new Set(values.map((value) => String(value?.name ?? "")))]
    .map((name) => ({ name, value: "[REDACTED]" }));
}

function sanitizeJsonContent(content: any, ignored = new Set<string>()): void {
  if (typeof content?.text !== "string" || !/\bjson\b/i.test(content.mimeType ?? "")) return;
  try {
    content.text = JSON.stringify(sanitizeJsonValue(JSON.parse(content.text), ignored));
  } catch {}
}

function sanitizeJsonValue(value: unknown, ignored: Set<string>): unknown {
  if (Array.isArray(value)) return value.map((item) => sanitizeJsonValue(item, ignored));
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(Object.entries(value).map(([key, item]) => {
    if (!SECRET_PARAMETER.test(key)) return [key, sanitizeJsonValue(item, ignored)];
    ignored.add(key);
    return [key, "[REDACTED]"];
  }));
}
