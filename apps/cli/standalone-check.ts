import { chmod, cp, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import packageMetadata from "./package.json";
import { buildStandalone, nativePlatform } from "./standalone.ts";

const { values } = parseArgs({ options: { out: { type: "string" } } });
const temporaryRoot = await mkdtemp(join(tmpdir(), "ox-cli-standalone-check-"));
const runtimeDirectory = join(temporaryRoot, "standalone runtime");
const repositoryDirectory = join(runtimeDirectory, "example repository");
const environment = { HOME: runtimeDirectory, PATH: "", TMPDIR: temporaryRoot };
const downloads = new Map<string, string>();
const server = Bun.serve({
  port: 0,
  fetch(request, server) {
    if (server.upgrade(request)) return;
    const artifact = downloads.get(new URL(request.url).pathname);
    if (artifact) return new Response(Bun.file(artifact));
    return Response.json({ devices: [] });
  },
  websocket: {
    message(socket, message) {
      const request = JSON.parse(String(message));
      const result = request.method === "host.describe" ? {
        implementation: { name: "Ox fixture", version: "1", build: "1" },
        protocols: { repository: [1, 2] },
        methods: ["host.describe", "chats.list"],
      } : {
        chats: [{ id: "standalone-smoke", title: "Standalone smoke test", model: null, createdAt: "2026-09-22T00:00:00Z", lastActivity: null, active: false }],
      };
      socket.send(JSON.stringify({
        jsonrpc: "2.0",
        id: request.id,
        ...(request.jsonrpc === "2.0" && ["host.describe", "chats.list"].includes(request.method)
          ? { result }
          : { error: { code: -32601, message: "Method not found" } }),
      }));
    },
  },
});

try {
  const archive = await buildStandalone(nativePlatform, values.out ?? join(temporaryRoot, "artifacts"));
  await mkdir(runtimeDirectory);
  downloads.set(`/ox-cli-${nativePlatform}.tar.gz`, archive);
  downloads.set("/SHA256SUMS", join(resolve(values.out ?? join(temporaryRoot, "artifacts")), `SHA256SUMS-${nativePlatform}`));
  const tools = join(temporaryRoot, "tools");
  await mkdir(tools);
  for (const tool of ["uname", "curl", "tar", "gzip", "mktemp", "tr", "sed", "awk", "sort", "head", "chmod", "mv", "rm", "mkdir", "ls", "shasum", "sha256sum"]) {
    const path = Bun.which(tool);
    if (path && tool !== "curl") await symlink(path, join(tools, tool));
  }
  const curl = join(tools, "curl");
  await writeFile(curl, `#!/bin/sh
for argument do
  case "$argument" in
    https://github.com/ziyzhu/openox/releases/download/*) argument="http://127.0.0.1:${server.port}/\${argument##*/}" ;;
  esac
  set -- "$@" "$argument"
  shift
done
exec '${Bun.which("curl")!.replaceAll("'", "'\\''")}' "$@"
`);
  await chmod(curl, 0o755);
  await run(["/bin/sh", join(import.meta.dir, "install.sh")], {
    ...environment, PATH: tools, OX_INSTALL_DIR: runtimeDirectory, OX_CLI_VERSION: packageMetadata.version,
  });
  await cp(resolve(import.meta.dir, "../../examples/service-repository"), repositoryDirectory, { recursive: true });
  await writeFile(join(runtimeDirectory, "bunfig.toml"), 'preload = ["./does-not-exist.ts"]\n');
  await writeFile(join(runtimeDirectory, ".env"), "OX_HOST_ENDPOINT=ws://127.0.0.1:1\n");
  const executable = join(runtimeDirectory, "ox");
  const version = (await run([executable, "--version"])).trim();
  if (version !== packageMetadata.version) throw new Error(`Unexpected version: ${version}`);
  const help = await run([executable, "--help"]);
  if (!help.includes("vm inspect")) throw new Error("Standalone help omitted VM commands");
  const services = JSON.parse(await run([executable, "--repository", repositoryDirectory, "service", "list", "--json"]));
  if (!services.some((service: { domain: string }) => service.domain === "example.com")) {
    throw new Error("Standalone executable could not inspect the example repository");
  }
  await run([executable, "repository", "validate", repositoryDirectory]);
  const discovery = JSON.parse(await run([executable, "discover", "--json"], {
    ...environment, OX_SIM_DAEMON_PORT: String(server.port),
  }));
  if (discovery.hosts[0]?.endpoint !== "ws://127.0.0.1:9876") throw new Error("Standalone loaded the working directory's .env");
  const chats = JSON.parse(await run([executable, "--host", `ws://127.0.0.1:${server.port}`, "chat", "list", "--json"]));
  if (chats[0]?.id !== "standalone-smoke") throw new Error("Standalone Host request failed");
  console.log(`PASS standalone ${nativePlatform}: download, install, version, help, repository validation, discovery, Host request; no Bun or Node on PATH`);
} finally {
  server.stop(true);
  await rm(temporaryRoot, { recursive: true, force: true });
}

async function run(cmd: string[], env: Record<string, string | undefined> = environment): Promise<string> {
  const child = Bun.spawn({ cmd, cwd: runtimeDirectory, env, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  if (code !== 0) throw new Error(`${cmd[0]} exited ${code}\n${stderr}`);
  return stdout;
}
