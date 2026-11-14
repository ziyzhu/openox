import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { run } from "../../../../lib.ts";
import { actionsSource, type Site } from "./sites/shared.ts";

export type Fixtures = { origin: (host: string) => string; ca: string; repository: string; stop: () => void; reset: () => void };

async function certificates(hosts: string[]) {
  const directory = join(tmpdir(), "ox-web-fixtures");
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const path = (name: string) => join(directory, name);
  const openssl = (...args: string[]) => run(["openssl", ...args], { capture: true });
  if (!existsSync(path("ca.pem"))) {
    await writeFile(path("ca.cnf"), "[req]\ndistinguished_name=dn\n[dn]\n[ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n");
    await openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", path("ca.key"), "-out", path("ca.pem"),
      "-days", "825", "-subj", "/CN=Ox Web Fixtures CA", "-config", path("ca.cnf"), "-extensions", "ca");
  }
  await writeFile(path("leaf.cnf"), `basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=${hosts.map(host => `DNS:${host}`).join(",")}\n`);
  await openssl("req", "-newkey", "rsa:2048", "-nodes", "-keyout", path("leaf.key"), "-out", path("leaf.csr"), "-subj", "/CN=Ox Web Fixtures");
  await openssl("x509", "-req", "-in", path("leaf.csr"), "-CA", path("ca.pem"), "-CAkey", path("ca.key"), "-CAcreateserial",
    "-out", path("leaf.pem"), "-days", "365", "-extfile", path("leaf.cnf"));
  return { ca: path("ca.pem"), cert: await Bun.file(path("leaf.pem")).text(), key: await Bun.file(path("leaf.key")).text() };
}

async function writeRepository(sites: Site[], origin: (host: string) => string): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "ox-web-fixture-repository-"));
  const services = sites.flatMap(site => site.services(origin));
  await writeFile(join(root, "repository.json"), JSON.stringify({
    version: 3, name: "Web Fixtures", services: services.map(service => `${service.manifest.kind ?? "web"}:${service.manifest.domain}`), skills: [],
  }, null, 2));
  for (const service of services) {
    const directory = join(root, String(service.manifest.kind ?? "web"), service.manifest.domain);
    await mkdir(directory, { recursive: true });
    await writeFile(join(directory, "service.json"), JSON.stringify(service.manifest, null, 2));
    await writeFile(join(directory, "actions.js"), await actionsSource(service.actions));
  }
  return root;
}

export async function startFixtures(sites: Site[], port: number): Promise<Fixtures> {
  const byHost = new Map(sites.flatMap(site => site.hosts.map(host => [host, site] as const)));
  const origin = (host: string) => {
    if (!byHost.has(host)) throw new Error(`Unknown fixture host ${host}`);
    return `https://${host}:${port}`;
  };
  const tls = await certificates([...byHost.keys()]);
  const server = Bun.serve({
    port, hostname: "127.0.0.1", idleTimeout: 60, tls: { cert: tls.cert, key: tls.key },
    async fetch(request) {
      const url = new URL(request.url);
      const site = byHost.get(url.hostname);
      if (!site) return new Response("Unknown fixture host", { status: 421 });
      try {
        return await site.handle(request, url, origin);
      } catch (error) {
        console.error(`fixture ${site.name} ${request.method} ${url.pathname} failed: ${(error as Error).message}`);
        return new Response("Fixture error", { status: 500 });
      }
    },
  });
  return {
    origin, ca: tls.ca,
    repository: await writeRepository(sites, origin),
    stop: () => server.stop(true),
    reset: () => sites.forEach(site => site.reset()),
  };
}
