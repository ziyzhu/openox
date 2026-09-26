import { createHash } from "node:crypto";
import { mkdtemp, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHerdrMCPHandler } from "../apps/cli/src/herdr.ts";
import { mcpManagementFixture } from "./fixtures/mcp-management.ts";
import { ROOT } from "./lib.ts";
import { qaCommand } from "./qa-config.ts";

const config = qaCommand({ usage: "Usage: bun tooling/canvas-integration-fixture.ts --device ox-qa-N" });
const directory = await mkdtemp(join(tmpdir(), "ox-canvas-integration-"));
await mkdir(join(directory, "artifacts"));
await Bun.write(join(directory, "artifacts/canvas-export.txt"), "Ox canvas export fixture\nNo account data or credentials.\n");
const repository = Bun.spawn(["ox", "repository", "serve", join(ROOT, "repositories/builtin"), "--port", "0"], {
  stdout: "pipe", stderr: "inherit",
});
let server: ReturnType<typeof Bun.serve> | undefined;
const stop = async () => {
  await server?.stop(true);
  repository.kill("SIGTERM");
  await repository.exited;
  process.exit();
};
process.once("SIGINT", stop);
process.once("SIGTERM", stop);
try {
  let output = "";
  let upstream = "";
  const reader = repository.stdout.getReader();
  const timeout = setTimeout(() => repository.kill("SIGTERM"), 30_000);
  try {
    while (!upstream) {
      const chunk = await reader.read();
      if (chunk.done) throw new Error("Repository server exited before readiness");
      output += new TextDecoder().decode(chunk.value);
      upstream = output.match(/READY (http:\/\/127\.0\.0\.1:\d+)\/repository.git/)?.[1] ?? "";
    }
  } finally { clearTimeout(timeout); reader.releaseLock(); }
  const mcp = createHerdrMCPHandler(async args => {
    if (args.join(" ") !== "agent get canvas-fixture") throw new Error("Only the fixture workspace is available");
    return { result: { agent: { cwd: directory } } };
  });
  server = Bun.serve({
    hostname: "127.0.0.1", port: config.registryPort,
    fetch: request => {
      const { pathname, search } = new URL(request.url);
      if (pathname === "/mcp") return mcp(request);
      if (["/mcp-a", "/mcp-b", "/mcp-fail"].includes(pathname)) return mcpManagementFixture(request);
      return fetch(new Request(upstream + pathname + search, request));
    },
  });
  const endpoint = `http://127.0.0.1:${server.port}/mcp`;
  const domain = "mcp." + createHash("sha256").update(endpoint).digest("hex").slice(0, 16);
  const html = (await Bun.file(join(ROOT, "tooling/fixtures/canvas-handoffs.html")).text()).replace("__MCP_DOMAIN__", domain);
  const artifactPath = join(directory, "Canvas Integration.html");
  await Bun.write(artifactPath, html);
  const profile = join(directory, "bootstrap.json");
  await Bun.write(profile, JSON.stringify({ version: 1, artifacts: [{ path: artifactPath }], providers: [], websiteData: false }));
  console.log(JSON.stringify({ directory, profile, endpoint, domain, repository: `http://127.0.0.1:${server.port}/repository.git`, proxyPort: config.serviceProxyPort }));
} catch (error) {
  repository.kill("SIGTERM");
  await repository.exited;
  throw error;
}
