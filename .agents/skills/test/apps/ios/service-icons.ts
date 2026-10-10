import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { ROOT, run } from "../../../../lib.ts";
import { qaCommand } from "../../../onboarding/scripts/qa-config.ts";
import { claimSimulator, requireFreePort, requireSimulator } from "../../../onboarding/scripts/simulator.ts";

const qa = qaCommand({
  usage: "bun .agents/skills/test/apps/ios/service-icons.ts --device ox-N --host <ws-url> --chat <saved-QA-chat> --domain <run-owned-MCP-domain> [--live] [--only <case,...>] [--output /tmp/directory]\nRequires an attached run-owned MCP fixture at http://127.0.0.1:<registryPort>/mcp-favicon-qa and an idle saved QA chat. Launch Ox with the matching OX_SERVICES_ENDPOINT. Starts its fixture server, verifies native image loading through ox, and restores the saved favicon URL. --live also contacts Google, httpbingo, and httpbin for public HTTPS ICO and redirect checks.",
  options: { host: { type: "string" }, chat: { type: "string" }, domain: { type: "string" }, live: { type: "boolean" }, only: { type: "string" }, output: { type: "string" } },
});
const { host, chat, domain } = qa.values;
assert(host && chat && domain, "Pass an explicit Host, saved QA chat, and run-owned MCP fixture domain");
assert.equal(Number(new URL(host).port), qa.debugPort);
const origin = `http://127.0.0.1:${qa.registryPort}`;
const directory = resolve(qa.values.output ?? `/tmp/ox-service-icons-${Date.now()}`);
assert(directory !== ROOT && !directory.startsWith(ROOT + "/"), "Keep evidence outside the repository");
const small = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAL0lEQVRYw+3OMQEAMAyAMDb/nlsZfYIB8qamw/7lHAAAAAAAAAAAAAAAAAAAoGoBMOMCPiHJMh4AAAAASUVORK5CYII=", "base64");
const large = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAABTklEQVR42u3SMQEAIAzAsIFynIMMjiYKenTNmTtk7d8B/GWAOAPEGSDOAHEGiDNAnAHiDBBngDgDxBkgzgBxBogzQJwB4gwQZ4A4A8QZIM4AcQaIM0CcAeIMEGeAOAPEGSDOAHEGiDNAnAHiDBBngDgDxBkgzgBxBogzQJwB4gwQZ4A4A8QZIM4AcQaIM0CcAeIMEGeAOAPEGSDOAHEGiDNAnAHiDBBngDgDxBkgzgBxBogzQJwB4gwQZ4A4A8QZIM4AcQaIM0CcAeIMEGeAOAPEGSDOAHEGiDNAnAHiDBBngDgDxBkgzgBxBogzQJwB4gwQZ4A4A8QZIM4AcQaIM0CcAeIMEGeAOAPEGSDOAHEGiDNAnAHiDBBngDgDxBkgzgBxBogzQJwB4gwQZ4A4A8QZIM4AcQaIM0CcAeIMEGeAOAPEGSDOAHEGiDNA3AMZEwJ/fCT72gAAAABJRU5ErkJggg==", "base64");
const wide = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAEAEAAAABCAYAAACx4wBCAAAAKklEQVR42u3BMQEAAAgDoNnc5jOGDzDZNAAAAAAAAAAAAAAAAAAAAMC7A0gpAYHDMkXrAAAAAElFTkSuQmCC", "base64");
const jpeg = Buffer.from("/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCACAAIADAREAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAj/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFgEBAQEAAAAAAAAAAAAAAAAAAAcI/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AnJD2bwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAH//Z", "base64");
const header = Buffer.alloc(38);
header.writeUInt16LE(1, 2);
header.writeUInt16LE(2, 4);
let offset = header.length;
for (const [index, image] of [small, large].entries()) {
  const entry = 6 + index * 16;
  header[entry] = header[entry + 1] = image.readUInt32BE(16);
  header.writeUInt16LE(1, entry + 4);
  header.writeUInt16LE(32, entry + 6);
  header.writeUInt32LE(image.length, entry + 8);
  header.writeUInt32LE(offset, entry + 12);
  offset += image.length;
}
const ico = Buffer.concat([header, small, large]);
type Icon = { src: string; mimeType: string; sizes?: string[] };
const inline = (mimeType: string, data: Buffer): Icon => ({ src: `data:${mimeType};base64,${data.toString("base64")}`, mimeType });
let icons: Icon[] = [];
const checks: string[] = [];
let original: string | null | undefined;

async function call(name: string, args: Record<string, unknown> = {}) {
  const result = await run(["ox", "--host", host!, "--chat", chat!, "vm", "call", name, "--args", JSON.stringify({ ...args, purpose: "Verify run-owned favicon fixture" }), "--json"], { capture: true });
  return JSON.parse(result.stdout).value;
}
async function verify(name: string, candidates: Icon[], expectedSize?: number | true, faviconUrl: string | null = null) {
  if (qa.values.only && !qa.values.only.split(",").includes(name)) return;
  icons = candidates;
  await call("ox.service.update", { domain, faviconUrl });
  const result = await run(["ox", "--host", host!, "host", "services", "--json", "--timeout", "120000"], { capture: true });
  const row = JSON.parse(result.stdout).find((row: { domain: string }) => row.domain === domain);
  assert(row, "Fixture disappeared");
  assert.equal(Boolean(row.favicon), expectedSize !== undefined, name);
  if (expectedSize !== undefined) {
    const image = Buffer.from(row.favicon.split(",")[1], "base64");
    assert.equal(image.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
    const width = image.readUInt32BE(16);
    assert.equal(image.readUInt32BE(20), width, name);
    assert(width > 0 && width <= 256, name);
    if (expectedSize !== true) assert.equal(width, expectedSize, name);
    await writeFile(join(directory, `${name}.png`), image);
  }
  checks.push(name);
  console.log(`PASS ${name}`);
}

assert(await requireSimulator(qa.device), "Boot the reserved simulator before testing");
await requireFreePort(qa.registryPort);
const release = claimSimulator(qa.device);
const server = Bun.serve({
  hostname: "127.0.0.1", port: qa.registryPort,
  async fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === "/image") return new Response(large, { headers: { "Content-Type": "image/png" } });
    if (path === "/redirect") return Response.redirect(`${origin}/image`, 302);
    if (path === "/too-large") return new Response(Buffer.alloc(1_048_577), { headers: { "Content-Type": "image/png" } });
    if (path === "/bad-type") return new Response("<html>not an icon</html>", { headers: { "Content-Type": "text/html" } });
    if (request.method !== "POST") return new Response("", { status: 405 });
    const rpc = await request.json() as { id?: number; method: string };
    if (rpc.id == null) return new Response("", { status: 202 });
    const result = rpc.method === "initialize" ? {
      protocolVersion: "2025-11-25", capabilities: { tools: {} },
      serverInfo: { name: "QA favicon pipeline", version: "1", icons },
    } : { tools: [] };
    return Response.json({ jsonrpc: "2.0", id: rpc.id, result });
  },
});
try {
  await mkdir(directory, { recursive: true });
  const inspected = await run(["ox", "--host", host, "--chat", chat, "chat", "inspect", "--json"], { capture: true });
  assert.equal(JSON.parse(inspected.stdout).isBusy, false, "Use an idle QA chat");
  const service = (await call("ox.service.inspect", { domain })).service;
  assert.equal(service.endpoint, `${origin}/mcp-favicon-qa`, "Use only the run-owned fixture endpoint");
  original = service.faviconUrl;
  await call("ox.fs.read", { path: "skills/evolve/SKILL.md" });
  const guide = (await call("ox.fs.read", { path: "skills/evolve/references/web-service.md" })).text;
  assert.match(guide, /document.baseURI/);
  assert.match(guide, /manifest's final response URL/);
  assert.match(guide, /smaller official candidates.*before using a third-party cache/);
  checks.push("bundled-browser-style-discovery-guidance");
  await verify("small-official-png", [inline("image/png", small)], 32);
  await verify("jpeg-normalized-to-png", [inline("image/jpeg", jpeg)], 128);
  await verify("ico-largest-frame", [inline("image/x-icon", ico)], 128);
  await verify("ico-mime-alias", [inline("image/vnd.microsoft.icon", ico)], 128);
  await verify("native-candidate-fallback", [inline("image/png", large.subarray(0, 8)), inline("image/png", small)], 32);
  await verify("corrupt-png", [inline("image/png", large.subarray(0, 8))]);
  await verify("unsupported-svg", [inline("image/svg+xml", Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"/>'))]);
  await verify("pixel-limit", [inline("image/png", wide)]);
  await verify("advertised-direct-http", [{ src: `${origin}/image`, mimeType: "image/png" }], 128);
  await verify("advertised-redirect-still-blocked", [{ src: `${origin}/redirect`, mimeType: "image/png" }]);
  await verify("download-byte-limit", [{ src: `${origin}/too-large`, mimeType: "image/png" }]);
  await verify("download-content-type", [{ src: `${origin}/bad-type`, mimeType: "image/png" }]);
  if (qa.values.live) {
    await verify("public-https-ico", [], true, "https://www.google.com/favicon.ico");
    await verify("public-https-redirect", [], true, "https://www.google.com/s2/favicons?domain_url=https%3A%2F%2Fgithub.com&sz=128&alt=404");
    await verify("public-redirect-limit", [], undefined, "https://httpbingo.org/redirect/6");
    await verify("public-unsafe-redirect", [], undefined, "https://httpbin.org/redirect-to?url=https%3A%2F%2F127.0.0.1%2Fimage");
    await verify("public-https-downgrade", [], undefined, "https://httpbingo.org/redirect-to?url=http%3A%2F%2Fexample.com%2Fimage");
    for (const [name, path] of [["public-redirect-limit", "httpbingo.org/redirect/6"], ["public-unsafe-redirect", "httpbin.org/redirect-to"], ["public-https-downgrade", "httpbingo.org/redirect-to"]] as const) {
      if (!checks.includes(name)) continue;
      const logs = await run(["ox", "--host", host, "host", "logs", "--grep", path, "--limit", "1", "--json"], { capture: true });
      assert.match(logs.stdout, /reason=httpStatus\(302\)/, "Redirect rejection must occur before fetching the final resource");
    }
  }
  if (qa.values.only) assert.equal(checks.length, new Set(qa.values.only.split(",")).size + 1, "Unknown or unavailable selected case");
} finally {
  try {
    if (original !== undefined) await call("ox.service.update", { domain, faviconUrl: original });
    await writeFile(join(directory, "report.json"), JSON.stringify({ device: qa.device, domain, checks }, null, 2) + "\n", { mode: 0o600 });
  } finally { server.stop(); release(); }
}
console.log(`PASS native service icon E2E (${checks.length} checks); evidence: ${directory}`);
