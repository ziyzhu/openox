import { mkdir, writeFile, copyFile, readdir, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import {
  buildService, sourceDirFor,
  listServiceDomains,
} from "./service.ts";
import {
  catalogDir,
  listCatalogIDs,
  loadIOSManifest,
  loadMCPManifest,
  type CatalogKind,
} from "./catalog.ts";
import {
  REPOSITORY_VERSION,
  validateRepositoryPackage,
  qualifiedRepositoryServiceID,
  repositoryServicePath,
  type RepositoryPackage,
  type RepositoryService,
} from "@openox/service-sdk/repository";

async function contentHash(root: string): Promise<string> {
  const files: string[] = [];
  async function collect(directory: string, relative = ""): Promise<void> {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const path = relative ? `${relative}/${entry.name}` : entry.name;
      if (entry.isDirectory()) await collect(join(directory, entry.name), path);
      else files.push(path);
    }
  }
  await collect(root);
  const hasher = new Bun.CryptoHasher("sha256");
  for (const path of files.sort()) {
    hasher.update(path);
    hasher.update(new Uint8Array([0]));
    hasher.update(await readFile(join(root, path)));
    hasher.update(new Uint8Array([0]));
  }
  return hasher.digest("hex");
}

type ArtifactOptions = {
  name?: string;
  domains?: string[];
  catalogKinds?: CatalogKind[];
};

export async function buildArtifacts(outDir: string, options: ArtifactOptions = {}): Promise<RepositoryPackage> {
  const domains = options.domains ?? listServiceDomains();
  const catalogKinds = options.catalogKinds ?? ["ios", "mcp"];
  const results = await Promise.all(domains.map(async (domain) => ({
    domain,
    service: await buildService(domain),
  })));
  const catalogResults = await Promise.all(catalogKinds.flatMap((kind) =>
    listCatalogIDs(kind).map(async (id) => ({
      kind,
      id,
      manifest: kind === "ios" ? await loadIOSManifest(id) : await loadMCPManifest(id),
    }))
  ));
  const failures = [
    ...results.filter((result) => "error" in result.service).map(({ domain, service }) => ({
      id: domain,
      error: (service as { error: string }).error,
    })),
    ...catalogResults.filter((result) => "error" in result.manifest).map(({ kind, id, manifest }) => ({
      id: `${kind}/${id}`,
      error: (manifest as { error: string }).error,
    })),
  ];
  if (failures.length) {
    throw new Error([
      `registry build failed for ${failures.length} service${failures.length === 1 ? "" : "s"}`,
      ...failures.map(({ id, error }) => `- ${id}: ${error}`),
    ].join("\n"));
  }

  await mkdir(outDir, { recursive: true });
  const entries: RepositoryService[] = [];
  for (const { domain, service } of results) {
    if ("error" in service) throw new Error(service.error);
    const out = join(outDir, "web", domain);
    await mkdir(out, { recursive: true });
    await writeFile(join(out, "manifest.json"), JSON.stringify(service.manifest, null, 2));
    await writeFile(join(out, "actions.js"), service.actions);
    for (const skill of service.manifest.skills ?? []) {
      const skillOut = join(out, "skills", skill.name);
      await mkdir(skillOut, { recursive: true });
      await copyFile(
        join(sourceDirFor(domain), "skills", skill.name, "SKILL.md"),
        join(skillOut, "SKILL.md"),
      );
    }
    entries.push(qualifiedRepositoryServiceID("web", domain));
  }
  for (const { kind, id, manifest } of catalogResults) {
    if ("error" in manifest) throw new Error(manifest.error);
    const serviceID = qualifiedRepositoryServiceID(kind, id);
    const out = join(outDir, repositoryServicePath(serviceID));
    await mkdir(out, { recursive: true });
    await writeFile(join(out, "manifest.json"), JSON.stringify(manifest, null, 2));
    const favicon = join(catalogDir(kind, id), "favicon.png");
    if (existsSync(favicon)) await copyFile(favicon, join(out, "favicon.png"));
    entries.push(serviceID);
  }
  const repository: RepositoryPackage = {
    version: REPOSITORY_VERSION,
    name: options.name ?? "Ox Services",
    contentHash: await contentHash(outDir),
    services: entries.sort((a, b) => a.localeCompare(b)),
  };
  const validated = validateRepositoryPackage(repository);
  if ("error" in validated) throw new Error(validated.error);
  await writeFile(join(outDir, "ox.json"), `${JSON.stringify(validated, null, 2)}\n`);
  return validated;
}
