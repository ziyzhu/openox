import { afterEach, beforeEach, expect, test } from "bun:test";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createHash } from "node:crypto";

const installer = resolve(import.meta.dir, "../apps/cli/install.sh");
let root: string;
let bin: string;
let destination: string;
let curl: string;
let releasePages: string[];
let downloads: string[];
let artifacts: Map<string, string>;
let server: ReturnType<typeof Bun.serve>;

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), "ox-cli-installer-"));
  bin = join(root, "tools");
  destination = join(root, "install with spaces");
  await mkdir(bin);
  for (const tool of ["tar", "gzip", "mktemp", "tr", "sed", "awk", "sort", "head", "chmod", "mv", "rm", "mkdir", "ls", "shasum"]) {
    const executable = Bun.which(tool);
    if (!executable) throw new Error(`Missing fixture tool: ${tool}`);
    await symlink(executable, join(bin, tool));
  }
  curl = Bun.which("curl")!;
  artifacts = new Map();
  downloads = [];
  releasePages = [JSON.stringify([{ tag_name: "service-sdk-v9.0.0" }, { tag_name: "ox-cli-v0.2.0" }])];
  server = Bun.serve({
    port: 0,
    fetch(request) {
      const url = new URL(request.url);
      downloads.push(url.pathname);
      if (url.pathname.endsWith("/releases")) {
        return new Response(releasePages[Number(url.searchParams.get("page")) - 1] ?? "[]");
      }
      const artifact = artifacts.get(url.pathname);
      return artifact ? new Response(Bun.file(artifact)) : new Response("Not found", { status: 404 });
    },
  });
  await script("curl", `for argument do
  case "$argument" in
    https://api.github.com/*) argument="http://127.0.0.1:${server.port}/api/\${argument#https://api.github.com/}" ;;
    https://github.com/*) argument="http://127.0.0.1:${server.port}/\${argument#https://github.com/}" ;;
  esac
  set -- "$@" "$argument"
  shift
done
exec '${curl.replaceAll("'", "'\\''")}' "$@"`);
  await script("uname", 'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac');
  await release("0.1.0");
  await release("0.2.0");
});

afterEach(async () => {
  server?.stop(true);
  await rm(root, { recursive: true, force: true });
});

async function script(name: string, contents: string): Promise<void> {
  const path = join(bin, name);
  await writeFile(path, `#!/bin/sh\n${contents}\n`);
  await chmod(path, 0o755);
}

async function release(version: string, reportedVersion = version): Promise<void> {
  const directory = join(root, version);
  await mkdir(directory);
  await writeFile(join(directory, "ox"), `#!/bin/sh\nprintf '%s\\n' '${reportedVersion}'\n`);
  const archiveName = "ox-cli-darwin-arm64.tar.gz";
  const archive = join(directory, archiveName);
  const child = Bun.spawn([Bun.which("tar")!, "-czf", archive, "ox"], { cwd: directory });
  if (await child.exited !== 0) throw new Error("Could not create installer fixture");
  const checksum = createHash("sha256").update(await readFile(archive)).digest("hex");
  const checksums = join(directory, "SHA256SUMS");
  await writeFile(checksums, `${checksum}  ${archiveName}\n`);
  const prefix = `/ziyzhu/openox/releases/download/ox-cli-v${version}`;
  artifacts.set(`${prefix}/${archiveName}`, archive);
  artifacts.set(`${prefix}/SHA256SUMS`, checksums);
}

async function install(version?: string, overrides: Record<string, string> = {}) {
  const child = Bun.spawn(["/bin/sh", installer], {
    env: { HOME: root, PATH: bin, OX_INSTALL_DIR: destination, ...(version ? { OX_CLI_VERSION: version } : {}), ...overrides },
    stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  return { code, stdout, stderr };
}

async function installedVersion(): Promise<string> {
  const child = Bun.spawn([join(destination, "ox"), "--version"], { env: { PATH: "" }, stdout: "pipe" });
  return (await new Response(child.stdout).text()).trim();
}

test("fresh pinned install, reinstall, and upgrade work without Node or Bun", async () => {
  for (const version of ["0.1.0", "0.1.0", "0.2.0"]) {
    const result = await install(version);
    expect(result.code).toBe(0);
    expect(result.stdout).toContain("Add");
    expect(await installedVersion()).toBe(version);
    expect(await readdir(destination)).toEqual(["ox"]);
  }
  expect(downloads.some(path => path.startsWith("/api/"))).toBe(false);
});

test("latest selection skips other packages and prerelease tags, including across pages", async () => {
  releasePages = [
    JSON.stringify([{ tag_name: "ox-cli-v0.1.0" }, ...Array.from({ length: 99 }, () => ({ tag_name: "services-v9.0.0" }))]),
    JSON.stringify([{ tag_name: "ox-cli-v0.2.0" }, { tag_name: "ox-cli-v0.3.0-beta.1" }, { tag_name: "ox-cli-v0.1.0" }]),
  ];
  expect((await install()).code).toBe(0);
  expect(await installedVersion()).toBe("0.2.0");
});

test("missing releases produce a useful error", async () => {
  releasePages = ["[]"];
  const result = await install();
  expect(result.code).not.toBe(0);
  expect(result.stderr).toContain("No standalone Ox CLI release");
  expect(await readdir(destination)).toEqual([]);
});

test("checksum failure preserves the installed executable and cleans staging", async () => {
  expect((await install("0.1.0")).code).toBe(0);
  await writeFile(join(root, "0.2.0/SHA256SUMS"), `${"0".repeat(64)}  ox-cli-darwin-arm64.tar.gz\n`);
  expect((await install("0.2.0")).stderr).toContain("checksum verification failed");
  expect(await installedVersion()).toBe("0.1.0");
  expect(await readdir(destination)).toEqual(["ox"]);
});

test("missing or ambiguous checksum entries stop installation", async () => {
  for (const content of ["", `${"0".repeat(64)}  ox-cli-darwin-arm64.tar.gz\n`.repeat(2)]) {
    await writeFile(join(root, "0.2.0/SHA256SUMS"), content);
    expect((await install("0.2.0")).stderr).toContain("missing or ambiguous");
  }
});

test("failed download and mismatched executable preserve the previous version", async () => {
  expect((await install("0.1.0")).code).toBe(0);
  expect((await install("0.9.0")).code).not.toBe(0);
  await release("0.3.0", "0.2.0");
  expect((await install("0.3.0")).stderr).toContain("does not match");
  expect(await installedVersion()).toBe("0.1.0");
  expect(await readdir(destination)).toEqual(["ox"]);
});

test("another installation on PATH and npm symlinks are not replaced", async () => {
  await script("ox", "echo 0.1.0");
  expect((await install("0.2.0")).stderr).toContain("already resolves");
  await rm(join(bin, "ox"));
  await mkdir(destination);
  await symlink(join(root, "0.1.0/ox"), join(destination, "ox"));
  expect((await install("0.2.0")).stderr).toContain("symbolic link");
  expect(await readFile(join(root, "0.1.0/ox"), "utf8")).toContain("0.1.0");
  expect(downloads).toEqual([]);
});

test("unsupported platforms, invalid versions, and invalid destinations fail before downloading", async () => {
  await script("uname", 'case "$1" in -s) echo Darwin ;; -m) echo riscv64 ;; esac');
  expect((await install("0.2.0")).stderr).toContain("Unsupported CPU");
  await script("uname", 'case "$1" in -s) echo FreeBSD ;; -m) echo x86_64 ;; esac');
  expect((await install("0.2.0")).stderr).toContain("support macOS and Linux");
  await script("uname", 'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac');
  expect((await install("../../bad")).stderr).toContain("OX_CLI_VERSION");
  expect((await install("0.2.0\n0.1.0")).stderr).toContain("OX_CLI_VERSION");
  expect((await install("0.2.0", { OX_INSTALL_DIR: "relative" })).stderr).toContain("absolute path");
  const occupied = join(root, "occupied");
  await writeFile(occupied, "occupied");
  expect((await install("0.2.0", { OX_INSTALL_DIR: occupied })).code).not.toBe(0);
  expect(downloads).toEqual([]);
});

test("an installation already on PATH prints a ready-to-run command", async () => {
  expect((await install("0.2.0", { PATH: `${destination}:${bin}` })).stdout).toContain("Run: ox --help");
});

test("termination during a download preserves the previous version and removes staging", async () => {
  expect((await install("0.1.0")).code).toBe(0);
  await script("curl", 'kill -TERM "$PPID"\nexit 1');
  expect((await install("0.2.0")).code).toBe(143);
  expect(await installedVersion()).toBe("0.1.0");
  expect(await readdir(destination)).toEqual(["ox"]);
});

test("an unwritable installation directory preserves the previous executable", async () => {
  expect((await install("0.1.0")).code).toBe(0);
  await chmod(destination, 0o555);
  try {
    expect((await install("0.2.0")).code).not.toBe(0);
    expect(await installedVersion()).toBe("0.1.0");
    expect(await readdir(destination)).toEqual(["ox"]);
  } finally {
    await chmod(destination, 0o755);
  }
});

test("missing checksum tools fail before downloading", async () => {
  await rm(join(bin, "shasum"));
  const result = await install("0.2.0");
  expect(result.code).not.toBe(0);
  expect(result.stderr).toContain("required to verify");
  expect(downloads).toEqual([]);
});

test("missing gzip fails before downloading", async () => {
  await rm(join(bin, "gzip"));
  const result = await install("0.2.0");
  expect(result.code).not.toBe(0);
  expect(result.stderr).toContain("gzip is required");
  expect(downloads).toEqual([]);
});
