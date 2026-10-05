import { chmod, cp, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import packageMetadata from "./package.json";
import { buildStandalone, nativePlatform, standaloneArtifacts } from "./standalone.ts";
import { hostFixtureReply } from "../../.agents/skills/test/contracts/client-host/fixture.ts";

const { values } = parseArgs({ options: { out: { type: "string" } } });
const temporaryRoot = await mkdtemp(join(tmpdir(), "ox-cli-standalone-check-"));
const runtimeDirectory = join(temporaryRoot, "standalone runtime");
const repositoryDirectory = join(runtimeDirectory, "example repository");
const windows = process.platform === "win32";
const artifacts = standaloneArtifacts(nativePlatform);
const environment: Record<string, string | undefined> = windows
  ? { USERPROFILE: runtimeDirectory, LOCALAPPDATA: runtimeDirectory, PATH: "", TEMP: temporaryRoot, TMP: temporaryRoot, SystemRoot: process.env.SystemRoot }
  : { HOME: runtimeDirectory, PATH: "", TMPDIR: temporaryRoot };
const downloads = new Map<string, string>();
const server = Bun.serve({
  port: 0,
  fetch(request, server) {
    if (server.upgrade(request)) return;
    const artifact = downloads.get(new URL(request.url).pathname);
    if (artifact) return new Response(Bun.file(artifact));
    return Response.json({ devices: [{
      name: "Standalone fixture", udid: "standalone-fixture", state: "Booted",
      listeners: [{ port: server.port }],
    }] });
  },
  websocket: {
    message(socket, message) {
      socket.send(JSON.stringify(hostFixtureReply(JSON.parse(String(message)))));
    },
  },
});

try {
  const archive = await buildStandalone(nativePlatform, values.out ?? join(temporaryRoot, "artifacts"));
  await mkdir(runtimeDirectory);
  downloads.set(`/${artifacts.archive}`, archive);
  downloads.set("/SHA256SUMS", join(resolve(values.out ?? join(temporaryRoot, "artifacts")), `SHA256SUMS-${nativePlatform}`));
  if (windows) await installWithPowerShell();
  else await installWithShell();
  await cp(resolve(import.meta.dir, "../../examples/repository"), repositoryDirectory, { recursive: true });
  await writeFile(join(runtimeDirectory, "bunfig.toml"), 'preload = ["./does-not-exist.ts"]\n');
  await writeFile(join(runtimeDirectory, ".env"), "OX_HOST_ENDPOINT=ws://127.0.0.1:1\n");
  const executable = join(runtimeDirectory, artifacts.executable);
  const version = (await run([executable, "--version"])).trim();
  if (version !== packageMetadata.version) throw new Error(`Unexpected version: ${version}`);
  const help = await run([executable, "--help"]);
  if (!help.includes("vm inspect")) throw new Error("Standalone help omitted VM commands");
  if (/^\s+serve\s/m.test(help)) throw new Error("Standalone help exposed the extracted Pi MCP server command");
  const services = JSON.parse(await run([executable, "--repository", repositoryDirectory, "repository", "services", "--json"]));
  if (!services.some((service: { domain: string }) => service.domain === "example.com")) {
    throw new Error("Standalone executable could not inspect the example repository");
  }
  await run([executable, "--repository", repositoryDirectory, "repository", "validate"]);
  const discoveryEnvironment = { ...environment, OX_SIM_DAEMON_PORT: String(server.port) };
  const candidates = JSON.parse(await run([executable, "host", "list", "--all", "--json"], discoveryEnvironment));
  const configured = candidates.hosts.find((host: { source: string }) => host.source === "configuration");
  if (configured?.endpoint !== "ws://127.0.0.1:9876") throw new Error("Standalone loaded the working directory's .env");
  const discovery = JSON.parse(await run([executable, "host", "list", "--json"], discoveryEnvironment));
  if (!discovery.hosts.some((host: { endpoint: string; reachable: boolean }) =>
    host.endpoint === `ws://127.0.0.1:${server.port}` && host.reachable)) {
    throw new Error("Standalone Host discovery missed the reachable fixture");
  }
  const chats = JSON.parse(await run([executable, "--host", `ws://127.0.0.1:${server.port}`, "chat", "list", "--json"]));
  if (chats[0]?.id !== "standalone-smoke") throw new Error("Standalone Host request failed");
  const hostArgs = [executable, "--host", `ws://127.0.0.1:${server.port}`];
  const created = JSON.parse(await run([...hostArgs, "chat", "new", "--temporary", "--provider", "mock", "--model", "mock", "--json"]));
  const outcome = JSON.parse(await run([...hostArgs, "--chat", created.chatId, "chat", "send", "hello", "--json"]));
  if (outcome.outcome !== "completed" || outcome.text !== "Hello from the fixture.") throw new Error("Standalone chat send failed");
  const snapshot = JSON.parse(await run([...hostArgs, "--chat", created.chatId, "chat", "inspect", "--json"]));
  if (snapshot.id !== created.chatId || snapshot.isBusy || !snapshot.messages.length) throw new Error("Standalone chat inspection failed");
  console.log(`PASS standalone ${nativePlatform}: download, install, version, help, repository validation, discovery, chat create/send/inspect; no Bun or Node on PATH`);
} finally {
  server.stop(true);
  await rm(temporaryRoot, { recursive: true, force: true });
}

async function installWithShell(): Promise<void> {
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
}

// PowerShell resolves functions before cmdlets, so this shim redirects release downloads like the curl shim.
async function installWithPowerShell(): Promise<void> {
  const powershell = Bun.which("pwsh") ?? Bun.which("powershell") ?? fail("PowerShell is required to verify install.ps1");
  const shim = `function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec, $Headers)
    $Uri = $Uri -replace '^https://github.com/ziyzhu/openox/releases/download/[^/]+/', 'http://127.0.0.1:${server.port}/'
    Microsoft.PowerShell.Utility\\Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing }
  & '${join(import.meta.dir, "install.ps1").replaceAll("'", "''")}'`;
  await run([powershell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", shim], {
    ...environment, OX_INSTALL_DIR: runtimeDirectory, OX_CLI_VERSION: packageMetadata.version, OX_NO_MODIFY_PATH: "1",
  });
}

function fail(message: string): never {
  throw new Error(message);
}

async function run(cmd: string[], env: Record<string, string | undefined> = environment): Promise<string> {
  const child = Bun.spawn({ cmd, cwd: runtimeDirectory, env, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  if (code !== 0) throw new Error(`${cmd[0]} exited ${code}\n${stderr}`);
  return stdout;
}
