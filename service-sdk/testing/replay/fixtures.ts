import { existsSync, readFileSync } from "node:fs";
import { readdirSync } from "node:fs";
import { basename, dirname, join, relative } from "node:path";
import * as ts from "typescript";
import {
  validateAgainstSchema,
  type Action as ServiceAction,
  type ServiceManifest,
} from "../../manifest.ts";
import type { ReplayCaseDefinition } from "./types.ts";
import { assertNoReusableSecrets } from "./proxy.ts";

export type ExpectedResult =
  | { output: unknown; error?: never }
  | { output?: never; error: string };

export type ServiceReplayCase = {
  domain: string;
  action: string;
  name: string;
  args: unknown;
  expected: ExpectedResult;
  harPath: string;
  casePath: string;
  scope?: string;
  replay: {
    ignoreQueryParameters: string[];
    ignoreBodyParameters: string[];
    matchHeaders: string[];
  };
};

export type FixtureAudit = {
  cases: ServiceReplayCase[];
  errors: string[];
  coveredActions: number;
  totalActions: number;
};

export async function auditServiceFixtures(root: string): Promise<FixtureAudit> {
  const errors: string[] = [];
  const cases = loadCases(root, errors);
  const manifests = new Map<string, ServiceManifest>();
  const actions = new Map<string, ServiceAction>();
  for (const domain of listServiceDomains(root)) {
    const manifestPath = join(sourceDirFor(root, domain), "manifest.json");
    const manifest = await Bun.file(manifestPath).json() as ServiceManifest;
    manifests.set(domain, manifest);
    for (const action of manifest.actions) actions.set(`${domain}:${action.id}`, action);
  }

  const covered = new Set<string>();
  const names = new Set<string>();
  for (const fixture of cases) {
    const label = `${relative(root, fixture.casePath)}:${fixture.scope}`;
    const manifest = manifests.get(fixture.domain);
    if (!manifest) {
      errors.push(`${label}: unknown service domain ${fixture.domain}`);
      continue;
    }
    const action = actions.get(`${fixture.domain}:${fixture.action}`);
    if (!action) {
      errors.push(`${label}: unknown action ${fixture.domain}:${fixture.action}`);
      continue;
    }
    const identity = `${fixture.domain}:${fixture.action}:${fixture.name}`;
    if (names.has(identity)) errors.push(`${label}: duplicate case ${identity}`);
    names.add(identity);
    const input = validateAgainstSchema(action.inputSchema, fixture.args, manifest.$defs);
    if (!input.ok) errors.push(`${label}: invalid args: ${input.errors.join("; ")}`);
    if ("output" in fixture.expected) {
      const output = validateAgainstSchema(action.outputSchema, fixture.expected.output, manifest.$defs);
      if (!output.ok) errors.push(`${label}: invalid expected output: ${output.errors.join("; ")}`);
    }
    errors.push(...await auditHar(fixture.harPath, root, fixture.scope!));
    covered.add(`${fixture.domain}:${fixture.action}`);
  }

  for (const key of actions.keys()) {
    if (!covered.has(key)) errors.push(`missing replay case for ${key}`);
  }
  return { cases, errors, coveredActions: covered.size, totalActions: actions.size };
}

export function readReplayCaseDefinitions(root: string, domain: string): ReplayCaseDefinition[] {
  const directory = sourceDirFor(root, domain);
  const fixturePath = join(directory, "replay.cases.json");
  if (existsSync(fixturePath)) return JSON.parse(readFileSync(fixturePath, "utf8")) as ReplayCaseDefinition[];
  const path = join(directory, "replay.ts");
  if (!existsSync(path)) return [];
  return parseReplayCasesSource(readFileSync(path, "utf8"), path);
}

export async function writeServiceReplayCase(
  root: string,
  domain: string,
  definition: ReplayCaseDefinition,
  caseHar: Record<string, unknown>,
  update: boolean,
): Promise<{ casePath: string; harPath: string }> {
  const directory = sourceDirFor(root, domain);
  const sourcePath = join(directory, "replay.ts");
  const fixturePath = join(directory, "replay.cases.json");
  const casePath = existsSync(fixturePath) ? fixturePath : sourcePath;
  const harPath = join(directory, "actions.har");
  const cases = readReplayCaseDefinitions(root, domain);
  const identity = caseIdentity(definition);
  const index = cases.findIndex((entry) => caseIdentity(entry) === identity);
  if (index >= 0 && !update) throw new Error(`${identity} already exists; pass --update to replace it`);
  if (index >= 0) cases[index] = definition;
  else cases.push(definition);
  const nextHar = await masterHarWithCase(harPath, identity, caseHar);
  assertNoReusableSecrets(nextHar);
  const caseSource = casePath === fixturePath
    ? `${JSON.stringify(cases, null, 2)}\n`
    : sourceWithReplayCases(existsSync(sourcePath) ? readFileSync(sourcePath, "utf8") : "", sourcePath, cases);
  await Promise.all([Bun.write(casePath, caseSource), Bun.write(harPath, `${JSON.stringify(nextHar, null, 2)}\n`)]);
  return { casePath, harPath };
}

function loadCases(root: string, errors: string[]): ServiceReplayCase[] {
  if (!existsSync(root)) return [];
  return listServiceDomains(root).flatMap((domain) => {
    const directory = sourceDirFor(root, domain);
    const fixturePath = join(directory, "replay.cases.json");
    const sourcePath = join(directory, "replay.ts");
    const path = existsSync(fixturePath) ? fixturePath : sourcePath;
    if (!existsSync(path)) return [];
    try {
      const definitions = path === fixturePath
        ? JSON.parse(readFileSync(path, "utf8")) as ReplayCaseDefinition[]
        : parseReplayCasesSource(readFileSync(path, "utf8"), path);
      return definitions.map((raw) => parseCase(path, domain, raw));
    } catch (error) {
      errors.push(`${relative(root, path)}: ${String((error as Error).message ?? error)}`);
      return [];
    }
  });
}

function listServiceDomains(root: string): string[] {
  if (!existsSync(root)) return [];
  return readdirSync(root, { withFileTypes: true })
    .filter(entry => entry.isDirectory() && existsSync(join(root, entry.name, "manifest.json")))
    .map(entry => entry.name)
    .sort();
}

function sourceDirFor(root: string, domain: string): string {
  if (!/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(domain)) throw new Error(`invalid service domain: ${domain}`);
  return join(root, domain);
}

function parseCase(path: string, domain: string, raw: ReplayCaseDefinition): ServiceReplayCase {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Error("case must be an object");
  if (typeof raw.action !== "string" || !raw.action) throw new Error("action must be a non-empty string");
  if (typeof raw.name !== "string" || !raw.name) throw new Error("name must be a non-empty string");
  if (raw.args === undefined) throw new Error("args is required");
  const hasOutput = Object.prototype.hasOwnProperty.call(raw, "output");
  const hasError = Object.prototype.hasOwnProperty.call(raw, "error");
  if (hasOutput === hasError) throw new Error("case must define exactly one of output or error");
  if (hasError && (typeof raw.error !== "string" || !raw.error)) throw new Error("error must be a non-empty string");
  const replay = raw.replay ?? {};
  return {
    domain,
    action: raw.action,
    name: raw.name,
    args: raw.args,
    expected: hasOutput ? { output: raw.output } : { error: raw.error as string },
    harPath: join(dirname(path), "actions.har"),
    casePath: path,
    scope: caseIdentity(raw),
    replay: {
      ignoreQueryParameters: stringArray(replay.ignoreQueryParameters, "replay.ignoreQueryParameters"),
      ignoreBodyParameters: stringArray(replay.ignoreBodyParameters, "replay.ignoreBodyParameters"),
      matchHeaders: stringArray(replay.matchHeaders, "replay.matchHeaders"),
    },
  };
}

export function parseReplayCasesSource(source: string, path = "replay.ts"): ReplayCaseDefinition[] {
  const file = ts.createSourceFile(path, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const declaration = replayCasesDeclaration(file);
  if (!declaration?.initializer) return [];
  const value = literalValue(declaration.initializer);
  if (!Array.isArray(value)) throw new Error("replayCases must be an array literal");
  return value as ReplayCaseDefinition[];
}

function replayCasesDeclaration(file: ts.SourceFile): ts.VariableDeclaration | undefined {
  for (const statement of file.statements) {
    if (!ts.isVariableStatement(statement)) continue;
    for (const declaration of statement.declarationList.declarations) {
      if (ts.isIdentifier(declaration.name) && declaration.name.text === "replayCases") return declaration;
    }
  }
  return undefined;
}

function literalValue(node: ts.Expression): unknown {
  if (ts.isParenthesizedExpression(node) || ts.isAsExpression(node) || ts.isSatisfiesExpression(node)) {
    return literalValue(node.expression);
  }
  if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) return node.text;
  if (ts.isNumericLiteral(node)) return Number(node.text);
  if (node.kind === ts.SyntaxKind.TrueKeyword) return true;
  if (node.kind === ts.SyntaxKind.FalseKeyword) return false;
  if (node.kind === ts.SyntaxKind.NullKeyword) return null;
  if (ts.isPrefixUnaryExpression(node) && node.operator === ts.SyntaxKind.MinusToken) {
    return -Number(literalValue(node.operand));
  }
  if (ts.isArrayLiteralExpression(node)) return node.elements.map((item) => literalValue(item as ts.Expression));
  if (ts.isObjectLiteralExpression(node)) {
    return Object.fromEntries(node.properties.map((property) => {
      if (!ts.isPropertyAssignment(property)) throw new Error("replayCases supports only explicit JSON-like properties");
      return [propertyName(property.name), literalValue(property.initializer)];
    }));
  }
  throw new Error(`replayCases contains unsupported syntax: ${node.getText()}`);
}

function propertyName(name: ts.PropertyName): string {
  if (ts.isIdentifier(name) || ts.isStringLiteral(name) || ts.isNumericLiteral(name)) return name.text;
  throw new Error(`replayCases contains an unsupported property name: ${name.getText()}`);
}

function sourceWithReplayCases(source: string, path: string, cases: ReplayCaseDefinition[]): string {
  const literal = JSON.stringify(cases, null, 2);
  if (!source) {
    return `export const replayCases = ${literal};\n`;
  }
  const file = ts.createSourceFile(path, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const declaration = replayCasesDeclaration(file);
  if (declaration?.initializer) {
    const start = declaration.initializer.getStart(file);
    return `${source.slice(0, start)}${literal}${source.slice(declaration.initializer.end)}`;
  }
  return `${source.trimEnd()}\n\nexport const replayCases = ${literal};\n`;
}

async function masterHarWithCase(
  path: string,
  scope: string,
  caseHar: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const existing = existsSync(path)
    ? await Bun.file(path).json() as any
    : { log: { version: "1.2", creator: { name: "service replay", version: "1" }, pages: [], entries: [] } };
  const entries = object(object(caseHar)?.log)?.entries;
  if (!Array.isArray(entries) || entries.length === 0) throw new Error("case HAR has no entries");
  const log = object(existing.log) ?? {};
  const currentEntries = Array.isArray(log.entries) ? log.entries : [];
  const currentPages = Array.isArray(log.pages) ? log.pages : [];
  log.entries = [
    ...currentEntries.filter((entry) => object(entry)?.pageref !== scope),
    ...entries.map((entry) => ({ ...structuredClone(entry), pageref: scope })),
  ];
  log.pages = [
    ...currentPages.filter((page) => object(page)?.id !== scope),
    { id: scope, title: scope, startedDateTime: new Date(0).toISOString(), pageTimings: {} },
  ];
  existing.log = log;
  return existing;
}

function caseIdentity(value: Pick<ReplayCaseDefinition, "action" | "name">): string {
  return `${value.action}:${value.name}`;
}

function stringArray(value: unknown, label: string): string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string" || !item)) {
    throw new Error(`${label} must be an array of non-empty strings`);
  }
  return [...new Set(value as string[])];
}

async function auditHar(path: string, root: string, scope: string): Promise<string[]> {
  const label = `${relative(root, path)}:${scope}`;
  if (!existsSync(path)) return [`${label}: HAR file is missing`];
  let raw: unknown;
  try {
    raw = await Bun.file(path).json();
  } catch (error) {
    return [`${label}: invalid HAR JSON: ${String((error as Error).message ?? error)}`];
  }
  const entries = object(object(raw)?.log)?.entries;
  if (!Array.isArray(entries)) return [`${label}: HAR has no entries`];
  const selected = entries.filter((entry) => object(entry)?.pageref === scope);
  if (selected.length === 0) return [`${label}: HAR has no entries for this case`];
  const errors: string[] = [];
  try { assertNoReusableSecrets(raw); }
  catch (error) { errors.push(`${label}: ${String((error as Error).message ?? error)}`); }
  selected.forEach((entry, index) => {
    const value = object(entry);
    const request = object(value?.request);
    const response = object(value?.response);
    if (typeof request?.method !== "string" || typeof request?.url !== "string") {
      errors.push(`${label}: entry ${index} has no request method or URL`);
    }
    if (typeof response?.status !== "number") errors.push(`${label}: entry ${index} has no response status`);
    for (const [sideName, side] of [["request", request], ["response", response]] as const) {
      if (Array.isArray(side?.cookies) && side.cookies.length > 0) {
        errors.push(`${label}: entry ${index} contains cookies`);
      }
      const headers = side?.headers;
      if (Array.isArray(headers)) {
        for (const header of headers) {
          const item = object(header);
          const name = typeof item?.name === "string" ? item.name.toLowerCase() : "";
          if (SECRET_HEADERS.has(name)) errors.push(`${label}: entry ${index} contains secret-bearing header ${name}`);
        }
      }
      const rawRedactions = side?._oxRedactions;
      if (rawRedactions === undefined) continue;
      const redactions = object(rawRedactions);
      if (!redactions) {
        errors.push(`${label}: entry ${index} ${sideName} has invalid _oxRedactions`);
        continue;
      }
      for (const field of ["headers", "cookies"] as const) {
        if (!Array.isArray(redactions[field])) {
          errors.push(`${label}: entry ${index} ${sideName} has invalid _oxRedactions.${field}`);
          continue;
        }
        for (const redaction of redactions[field]) {
          const item = object(redaction);
          if (typeof item?.name !== "string" || !item.name || item.value !== "[REDACTED]") {
            errors.push(`${label}: entry ${index} ${sideName} has invalid _oxRedactions.${field} item`);
          }
        }
      }
    }
  });
  return errors;
}

function object(value: unknown): Record<string, any> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, any>
    : undefined;
}

const SECRET_HEADERS = new Set([
  "authorization",
  "cookie",
  "proxy-authorization",
  "set-cookie",
  "x-api-key",
  "x-auth-token",
  "x-csrf-token",
  "x-xsrf-token",
  "shopify-storefront-private-token",
  "x-rebuy-user-token",
  "x-recharge-access-token",
  "x-recharge-storefront-access-token",
  "x-shopify-storefront-access-token",
]);
