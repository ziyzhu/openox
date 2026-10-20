import { Value } from "typebox/value";
import type { TObject, TSchema } from "typebox";
import { contracts } from "../src/functions/contracts";
import providerSchema from "../../../apps/shared/Host/ModelProviders/provider-definition.schema.json";

export const catalog = structuredClone(contracts) as Record<string, { description: string; inputSchema: TSchema; outputSchema: TSchema }>;
catalog["ox.provider.get"]!.outputSchema = providerSchema as TSchema;
catalog["ox.provider.default"]!.outputSchema = { type: "array", items: providerSchema } as TSchema;
for (const name of ["ox.provider.save", "ox.provider.validate"]) {
  (catalog[name]!.inputSchema as TObject).properties.provider = providerSchema as TSchema;
}
export type StubRule = { args?: Record<string, unknown>; when?: Record<string, unknown>; result?: unknown; error?: { code: string; message: string; recovery: string }; set?: Record<string, unknown> };
export type StubFixture = { state?: Record<string, unknown>; functions?: Record<string, StubRule[]>; files?: Record<string, string>; denied?: string[] };
export class StubError extends Error {
  readonly code: string;
  readonly recovery: string;
  constructor(code: string, message: string, recovery = "Inspect the current state and function help before proceeding.") { super(message); this.code = code; this.recovery = recovery; }
  toJSON() { return { code: this.code, message: this.message, recovery: this.recovery }; }
}
const equal = (a: unknown, b: unknown): boolean => JSON.stringify(a) === JSON.stringify(b);
const matches = (value: Record<string, unknown>, expected: Record<string, unknown> = {}) => Object.entries(expected).every(([key, item]) => equal(value[key], item));
export class Stubs {
  readonly state: Record<string, unknown>;
  readonly rules: Record<string, StubRule[]>;
  readonly denied: Set<string>;
  constructor(fixture: StubFixture, profile: string) {
    this.state = structuredClone({ profile: { name: profile, storage: "local" }, providers: [{ id: "qa-api", name: "QA API", source: "added", api: "openai-responses", url: "https://provider.example/v1", website: "https://provider.example", regions: ["global"], inferenceLocation: "remote", models: 2, availableModels: 2, authentication: "credential-stored", access: { methods: ["apiKey"], credentialKind: "apiKey", optional: false, notice: null }, capabilities: { supportsTools: true, canLoadModels: false, reasoningPolicy: "none" }, gettingStarted: null }],
      repositories: { status: "ready", repositories: [{ id: "bundled", name: "Built-in", provenance: "bundled", enabled: true, state: "ready", serviceCount: 0, skillCount: 5 }, { id: "local", name: "Local", provenance: "local", enabled: true, state: "ready", serviceCount: 0, skillCount: 0 }], truncated: false }, schedules: [{ id: "qa-weekly", name: "Weekly review", prompt: "Review the synthetic notes", status: "active", enabled: true, recurrence: "Weekly on Monday at 09:00 America/Los_Angeles", nextFireAt: "2026-10-19T16:00:00Z", lastRunAt: "2026-10-12T16:00:00Z", lastOutcome: "failed", lastError: "QA source unavailable" }], ...fixture.state });
    this.rules = structuredClone(fixture.functions ?? {});
    this.denied = new Set(fixture.denied ?? []);
    for (const name of [...Object.keys(this.rules), ...this.denied]) if (!catalog[name]) throw new Error(`Unknown stub function: ${name}`);
    for (const [name, rules] of Object.entries(this.rules)) {
      if (!Array.isArray(rules) || !rules.length) throw new Error(`Expected nonempty stub rules: ${name}`);
      for (const rule of rules) {
        if (!rule || typeof rule !== "object" || ("result" in rule) === ("error" in rule)) throw new Error(`Stub rule needs either result or error: ${name}`);
        if (rule.error && (rule.set || ![rule.error.code, rule.error.message, rule.error.recovery].every(value => typeof value === "string" && value.length))) throw new Error(`Invalid stub error: ${name}`);
        for (const value of [rule.args, rule.when, rule.set]) if (value !== undefined && (!value || typeof value !== "object" || Array.isArray(value))) throw new Error(`Invalid stub match or mutation: ${name}`);
      }
    }
  }
  validate(name: string, args: unknown) {
    const contract = catalog[name];
    if (!contract) throw new StubError("invalid_argument", `Unknown function: ${name}`);
    if (!Value.Check(contract.inputSchema, args)) throw new StubError("invalid_argument", `${name}: ${JSON.stringify([...Value.Errors(contract.inputSchema, args)].map(error => ({ path: error.instancePath, message: error.message })))}`);
    if (this.denied.has(name)) throw new StubError("permission_denied", `${name} was denied`);
  }
  output(name: string, value: unknown) {
    if (value === undefined || !Value.Check(catalog[name]!.outputSchema, value)) throw new Error(`Stub output violates ${name}: ${JSON.stringify([...Value.Errors(catalog[name]!.outputSchema, value)])}`);
    return structuredClone(value);
  }
  resolve(value: unknown, args: Record<string, unknown>): unknown {
    if (value && typeof value === "object" && !Array.isArray(value)) {
      const object = value as Record<string, unknown>;
      if (Object.keys(object).length === 1 && typeof object.$arg === "string") {
        if (!(object.$arg in args)) throw new Error(`Missing stub argument: ${object.$arg}`);
        return structuredClone(args[object.$arg]);
      }
      if (Object.keys(object).length === 1 && typeof object.$state === "string") {
        if (!(object.$state in this.state)) throw new Error(`Missing stub state: ${object.$state}`);
        return structuredClone(this.state[object.$state]);
      }
      return Object.fromEntries(Object.entries(object).map(([key, child]) => [key, this.resolve(child, args)]));
    }
    return Array.isArray(value) ? value.map(child => this.resolve(child, args)) : value;
  }
  call(name: string, args: Record<string, unknown>) {
    this.validate(name, args);
    if (name === "ox.provider.schema") return structuredClone(providerSchema);
    const rule = this.rules[name]?.find(rule => matches(args, rule.args) && matches(this.state, rule.when));
    if (rule) {
      if (rule.error) throw new StubError(rule.error.code, rule.error.message, rule.error.recovery);
      const result = this.output(name, this.resolve(rule.result, args));
      const changes = Object.fromEntries(Object.entries(rule.set ?? {}).map(([key, value]) => [key, this.resolve(value, args)]));
      Object.assign(this.state, changes);
      return result;
    }
    const readers: Record<string, string> = { "ox.app.profile": "profile", "ox.provider.list": "providers", "ox.repository.list": "repositories", "ox.schedule.list": "schedules" };
    if (readers[name]) return this.output(name, this.state[readers[name]!]);
    throw new StubError("stub_unconfigured", `No prepared stub matches ${name}`, "Prepare this function's state and response in the eval fixture.");
  }
}
