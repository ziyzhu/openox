import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { dispatch, fail, type CliContext, type SubCommand } from "./lib.ts";
import { profileRoot } from "./ox-content.ts";

const SERVICE_DOMAIN = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;

type CreateRequest = {
  name: string;
  description: string;
  instructions: string;
  services: string[];
  json: boolean;
};

export const SUBS: Record<string, SubCommand> = {
  create: {
    desc: "Create a user skill in a Profile",
    fn: createSkill,
  },
};

export async function skill(args: string[], context: CliContext): Promise<void> {
  return dispatch("skill", "Create and manage user skills.", SUBS, args, context);
}

export function skillName(raw: string): string {
  return raw.trim()
    .replace(/^\/+/, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function serializeUserSkill(request: Omit<CreateRequest, "json">): string {
  const description = request.description.trim().split(/\s+/u).join(" ");
  const instructions = request.instructions.trim();
  if (!request.name || skillName(request.name) !== request.name) fail(`invalid skill name: ${request.name}`);
  if (!description) fail("skill description cannot be empty");
  if (!instructions) fail("skill instructions cannot be empty");
  const services = normalizedServices(request.services);
  const serviceField = services.length ? `\nservices: ${services.join(", ")}` : "";
  return `---\nname: ${request.name}\ndescription: ${JSON.stringify(description)}${serviceField}\n---\n\n${instructions}\n`;
}

async function createSkill(args: string[], context: CliContext): Promise<void> {
  if (args.includes("-h") || args.includes("--help")) {
    printCreateUsage();
    return;
  }
  const root = profileRoot(context);
  const request = createRequest(args);
  const content = serializeUserSkill(request);
  const skillsRoot = join(root, "skills");
  const destination = join(skillsRoot, request.name);
  if (existsSync(destination)) fail(`skill already exists: ${request.name}`);
  mkdirSync(skillsRoot, { recursive: true });
  let claimed = false;
  try {
    mkdirSync(destination);
    claimed = true;
    const staging = join(destination, `.SKILL-${crypto.randomUUID()}.tmp`);
    writeFileSync(staging, content, { encoding: "utf8", flag: "wx" });
    renameSync(staging, join(destination, "SKILL.md"));
  } catch (error) {
    if (claimed) rmSync(destination, { recursive: true, force: true });
    if ((error as NodeJS.ErrnoException).code === "EEXIST") fail(`skill already exists: ${request.name}`);
    fail(`could not create skill ${request.name}: ${(error as Error).message}`);
  }
  const path = join(destination, "SKILL.md");
  if (request.json) {
    process.stdout.write(`${JSON.stringify({ name: request.name, path, services: normalizedServices(request.services) }, null, 2)}\n`);
    return;
  }
  console.log(`Created /${request.name} at ${path}`);
}

function createRequest(args: string[]): CreateRequest {
  let name = "";
  let description = "";
  let instructions = "";
  let instructionsFile = "";
  let json = false;
  const services: string[] = [];
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--description") description = requiredValue(args, ++index, argument);
    else if (argument === "--instructions") instructions = requiredValue(args, ++index, argument);
    else if (argument === "--instructions-file") instructionsFile = requiredValue(args, ++index, argument);
    else if (argument === "--service") services.push(requiredValue(args, ++index, argument));
    else if (argument === "--json") json = true;
    else if (argument.startsWith("-")) fail(`unknown option: ${argument}`);
    else if (!name) name = skillName(argument);
    else fail(`unexpected argument: ${argument}`);
  }
  if (!name) fail("skill create requires a name");
  if (!description.trim()) fail("--description is required");
  if (instructions && instructionsFile) fail("use either --instructions or --instructions-file, not both");
  if (instructionsFile) instructions = readInstructions(instructionsFile);
  if (!instructions.trim()) fail("--instructions or --instructions-file is required");
  return { name, description, instructions, services, json };
}

function requiredValue(args: string[], index: number, option: string): string {
  const value = args[index];
  if (!value || value.startsWith("--")) fail(`${option} requires a value`);
  return value;
}

function readInstructions(path: string): string {
  try {
    return readFileSync(path === "-" ? 0 : resolve(path), "utf8");
  } catch (error) {
    return fail(`could not read instructions from ${path}: ${(error as Error).message}`);
  }
}

function normalizedServices(values: string[]): string[] {
  const seen = new Set<string>();
  const services: string[] = [];
  for (const raw of values.flatMap((value) => value.split(","))) {
    const service = raw.trim().toLowerCase();
    if (!service || seen.has(service)) continue;
    if (!SERVICE_DOMAIN.test(service)) fail(`invalid service domain: ${service}`);
    seen.add(service);
    services.push(service);
  }
  return services;
}

function printCreateUsage(): void {
  console.log("Usage: ox --root <path> skill create <name> --description <text> (--instructions <text> | --instructions-file <path|->) [--service <domain>]... [--json]");
}
