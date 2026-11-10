import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { apply, defaultVariant, units, type Variant } from "./units";
import { runChecks } from "./checks";

const draftsDir = process.env.OX_PROMPT_DRAFTS ?? join(import.meta.dir, "drafts");
const port = Number(process.env.PORT ?? 4377);
const unitIDs = new Set(units.map(unit => unit.id));
const draftPath = (id: string) => join(draftsDir, `${id}.md`);

function drafts() {
  const result = new Map<string, string>();
  if (!existsSync(draftsDir)) return result;
  for (const file of readdirSync(draftsDir).filter(file => file.endsWith(".md"))) {
    const id = file.slice(0, -3);
    if (unitIDs.has(id)) result.set(id, readFileSync(join(draftsDir, file), "utf8"));
  }
  return result;
}

function variant(input: unknown): Variant {
  const value = { ...defaultVariant, ...(input && typeof input === "object" ? input : {}) } as Variant;
  if (!["conversation-bubbles", "text"].includes(value.presentation) || !["persisted", "temporary", "temporaryProfile"].includes(value.storage)) throw new Error("Invalid variant");
  return value;
}

function unitID(url: URL) {
  const id = decodeURIComponent(url.pathname.slice("/api/drafts/".length));
  if (!unitIDs.has(id)) throw new Error(`Unknown unit: ${id}`);
  return id;
}

async function handle(request: Request) {
  const url = new URL(request.url);
  if (url.pathname === "/") return new Response(Bun.file(join(import.meta.dir, "index.html")));
  if (url.pathname === "/api/units") {
    const saved = drafts();
    return Response.json({ draftsDir, units: units.map(({ fragments, ...unit }) => ({ ...unit, draft: saved.get(unit.id) ?? null })) });
  }
  if (url.pathname === "/api/render" && request.method === "POST") {
    const saved = drafts();
    const result = apply(variant(await request.json()), saved);
    return Response.json({ ...result, ...runChecks(units, saved, result.next, result.appears) });
  }
  if (url.pathname.startsWith("/api/drafts/")) {
    const id = unitID(url);
    if (request.method === "PUT") {
      mkdirSync(draftsDir, { recursive: true });
      writeFileSync(draftPath(id), await request.text());
      return Response.json({ saved: id });
    }
    if (request.method === "DELETE") {
      rmSync(draftPath(id), { force: true });
      return Response.json({ deleted: id });
    }
  }
  return new Response("Not found", { status: 404 });
}

Bun.serve({
  port,
  async fetch(request) {
    try { return await handle(request); } catch (error) {
      return Response.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 });
    }
  },
});
console.log(`Prompt workbench: http://localhost:${port} (drafts: ${draftsDir})`);
