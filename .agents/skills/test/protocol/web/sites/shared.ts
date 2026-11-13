export type Account = { id: string; label: string; username: string; password: string };
export type Manifest = Record<string, unknown> & { domain: string };
export type FixtureService = { manifest: Manifest; actions: string };
export type Counters = Record<string, number>;
export type Site = {
  name: string;
  hosts: string[];
  services: (origin: Origins) => FixtureService[];
  handle: (request: Request, url: URL, origin: Origins) => Response | Promise<Response>;
  reset: () => void;
  counters: Counters;
};
export type Origins = (host: string) => string;

export const accounts: Account[] = [
  { id: "ada", label: "Ada Fixture", username: "ada@fixture.test", password: "fixture-ada-password" },
  { id: "grace", label: "Grace Fixture", username: "grace@fixture.test", password: "fixture-grace-password" },
];

export const favicon = "https://www.iana.org/favicon.ico";

export function counter(): Counters {
  return {};
}

export function count(counters: Counters, name: string): void {
  counters[name] = (counters[name] ?? 0) + 1;
}

export function clear(counters: Counters): void {
  for (const key of Object.keys(counters)) delete counters[key];
}

export class Sessions {
  private readonly byToken = new Map<string, Account>();
  readonly cookie: string;

  constructor(cookie: string) {
    this.cookie = cookie;
  }

  create(account: Account): string {
    const token = crypto.randomUUID();
    this.byToken.set(token, account);
    return token;
  }

  account(request: Request): Account | undefined {
    const token = cookies(request)[this.cookie];
    return token ? this.byToken.get(token) : undefined;
  }

  clear(): void {
    this.byToken.clear();
  }
}

export function cookies(request: Request): Record<string, string> {
  return Object.fromEntries((request.headers.get("cookie") ?? "").split(/;\s*/).filter(Boolean).map(pair => {
    const index = pair.indexOf("=");
    return [pair.slice(0, index), decodeURIComponent(pair.slice(index + 1))];
  }));
}

export function setCookie(name: string, value: string, options: { domain?: string; httpOnly?: boolean; sameSite?: string; maxAge?: number } = {}): string {
  return [
    `${name}=${encodeURIComponent(value)}`, "Path=/", "Secure", `SameSite=${options.sameSite ?? "Lax"}`,
    ...options.httpOnly === false ? [] : ["HttpOnly"],
    ...options.domain ? [`Domain=${options.domain}`] : [],
    ...options.maxAge === undefined ? [] : [`Max-Age=${options.maxAge}`],
  ].join("; ");
}

export function findAccount(username: string): Account | undefined {
  return accounts.find(account => account.username === username.trim().toLowerCase());
}

export function escape(value: string): string {
  return value.replace(/[&<>"']/g, character => `&#${character.charCodeAt(0)};`);
}

export function page(title: string, body: string, head = ""): Response {
  return new Response(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${escape(title)}</title>${head}<style>body{font:16px -apple-system,system-ui;margin:24px}input,button{font:inherit;display:block;margin:8px 0;padding:8px;width:100%;box-sizing:border-box}[role=alert]{color:#b00}</style></head><body>${body}</body></html>`, {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" },
  });
}

export function json(value: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...headers } });
}

export function redirect(location: string, headers: Record<string, string> = {}): Response {
  return new Response(null, { status: 303, headers: { location, "cache-control": "no-store", ...headers } });
}

export async function form(request: Request): Promise<Record<string, string>> {
  return Object.fromEntries([...(await request.formData()).entries()].map(([key, value]) => [key, String(value)]));
}

const empty = { type: "object", properties: {}, additionalProperties: false };
const nonempty = { type: "string", minLength: 1 };
const sessionList = {
  type: "array",
  items: { type: "object", additionalProperties: false, required: ["id", "label", "url"], properties: { id: nonempty, label: nonempty, url: nonempty } },
};

export function action(id: string, description: string, options: { input?: unknown; output: unknown; auth?: boolean; approval?: boolean; baseUrl?: string }) {
  return {
    id, label: id, description,
    inputSchema: options.input ?? empty,
    outputSchema: options.output,
    requireAuth: options.auth ?? false,
    requireApproval: options.approval ?? false,
    ...options.baseUrl ? { baseUrl: options.baseUrl } : {},
  };
}

export function webService(domain: string, name: string, origin: string, actions: unknown[], options: { loginPath: string; extra?: Record<string, unknown> }): Manifest {
  return {
    domain, name, description: `${name} test fixture.`, baseUrl: `${origin}/`, faviconUrl: favicon, ...options.extra,
    actions: [
      action("listSessions", "List signed-in fixture accounts.", { output: sessionList }),
      action("login", "Sign in to a fixture account.", { output: { type: "null" }, baseUrl: `${origin}${options.loginPath}` }),
      ...actions,
    ],
  };
}

export async function actionsSource(name: string): Promise<string> {
  const read = (file: string) => Bun.file(new URL(`./${file}`, import.meta.url)).text();
  return `${await read("helpers.js")}\n${await read(name)}`;
}
