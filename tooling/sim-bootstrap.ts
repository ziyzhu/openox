import { ROOT } from "./lib.ts";
import { callHost } from "../apps/cli/src/host-rpc.ts";
import {
  type BootstrapProfile,
  type LLMRegion,
  apiKeyFor,
  loadAPIKeys,
  loadBootstrapProfile,
  parseBootstrapOptions,
  prepareBootstrap,
} from "./sim-bootstrap-lib.ts";

function usage(): string {
  return `Usage: bun run sim:bootstrap --device ox-qa-N [options]

Bootstraps credentials, artifacts, and optional website data into a running DEBUG app.

Options:
  --device <ox-qa-N>             Target numbered simulator
  --keys <path>                  API key file (default secrets/API_KEYS.json)
  --profile <path>               Bootstrap profile describing artifacts, providers, and website data
  --website-data-from <ox-qa-N>  Copy website data from another running simulator
  -h, --help                     Display this help`;
}

function runDebug(port: number, payload: Record<string, unknown>, timeoutMs: number) {
  const { method, ...params } = payload;
  return callHost(String(method), params, timeoutMs, `ws://127.0.0.1:${port}`);
}

async function command(cmd: string[]): Promise<string> {
  const process = Bun.spawn({ cmd, cwd: ROOT, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([
    new Response(process.stdout).text(),
    new Response(process.stderr).text(),
    process.exited,
  ]);
  if (code !== 0) throw new Error(stderr.trim() || stdout.trim() || `${cmd.join(" ")} exited ${code}`);
  return stdout;
}

async function requireBooted(requested: string[]): Promise<void> {
  const output = JSON.parse(await command(["sim", "devices"])) as {
    devices?: Record<string, Array<{ name?: string; state?: string; isAvailable?: boolean }>>;
  };
  const devices = Object.values(output.devices ?? {}).flat();
  for (const device of requested) {
    const target = devices.find((candidate) => candidate.name === device && candidate.isAvailable !== false);
    if (!target) throw new Error(`simulator not found: ${device}`);
    if (target.state !== "Booted") throw new Error(`simulator ${device} is ${target.state ?? "unavailable"}; launch it before bootstrap`);
  }
}

async function simulatorRegion(debugPort: number): Promise<LLMRegion> {
  const result = await runDebug(debugPort, { method: "models.list" }, 10_000);
  if (result.region !== "global" && result.region !== "china") {
    throw new Error("simulator region lookup returned an invalid result");
  }
  return result.region;
}

async function bootstrap(args: string[]): Promise<void> {
  const options = parseBootstrapOptions(args, Bun.env.OX_QA_DEVICE, ROOT);
  const configuredProfile = options.profilePath ? await loadBootstrapProfile(options.profilePath) : undefined;
  const needsCredentials = configuredProfile === undefined || configuredProfile.providers.length > 0;
  const apiKeys = needsCredentials ? await loadAPIKeys(options.apiKeysPath) : {};
  const profile: BootstrapProfile = configuredProfile ?? {
    version: 1,
    artifacts: [],
    providers: Object.keys(apiKeys),
    websiteData: false,
  };
  if (profile.websiteData && !options.websiteDataSource) {
    throw new Error("profile websiteData requires --website-data-from ox-qa-N");
  }
  if (!profile.websiteData && options.websiteDataSource) {
    throw new Error("--website-data-from requires websiteData: true in the profile");
  }
  await requireBooted([options.device, ...(options.websiteDataSource ? [options.websiteDataSource] : [])]);
  const region = needsCredentials ? await simulatorRegion(options.debugPort) : undefined;
  const prepared = await prepareBootstrap(
    options.profilePath ?? options.apiKeysPath,
    profile,
    async (clientId) => region ? apiKeyFor(apiKeys, clientId, region) : null,
  );
  if (prepared.websiteData) {
    const exported = await runDebug(options.websiteDataSourceDebugPort!, {
      method: "debug.websiteData.export",
    }, 60_000);
    if (typeof exported.data !== "string" || typeof exported.bytes !== "number") {
      throw new Error("website data export returned an invalid result");
    }
    await runDebug(options.debugPort, {
      method: "debug.websiteData.restore",
      data: exported.data,
    }, 60_000);
    console.log(`Website data: restored ${exported.bytes} bytes from ${options.websiteDataSource}`);
  }
  if (prepared.artifacts.length > 0) {
    const result = await runDebug(options.debugPort, {
      method: "debug.artifacts.bootstrap",
      artifacts: prepared.artifacts.map(({ name, data }) => ({ name, data })),
    }, 60_000);
    const installed = result.artifacts as string[] | undefined;
    if (!installed || installed.length !== prepared.artifacts.length) throw new Error("artifact bootstrap returned an invalid result");
    prepared.artifacts.forEach((artifact, index) => {
      console.log(`Artifact ${artifact.path} -> ${installed[index]} (${artifact.bytes} bytes)`);
    });
  }
  for (const credential of prepared.credentials) {
    await runDebug(options.debugPort, {
      method: "debug.providers.setKey",
      clientId: credential.clientId,
      key: credential.key,
      region,
    }, 10_000);
    console.log(`Provider ${credential.clientId}: ready`);
  }
  console.log(`BOOTSTRAPPED ${options.device} region=${region ?? "none"} providers=${prepared.credentials.length}`);
}

try {
  const args = Bun.argv.slice(2);
  if (args.includes("-h") || args.includes("--help")) console.log(usage());
  else await bootstrap(args);
} catch (error) {
  console.error(`error: ${(error as Error).message}`);
  process.exitCode = 1;
}
