import { describe, expect, test } from "bun:test";
import { validateServiceManifest, type APIAuth } from "../src/manifest.ts";
import { validateRepositoryPackage } from "../src/repository.ts";

const makeService = (auth: APIAuth = { type: "none" }) => ({
  kind: "api", domain: "calendar-fixture", name: "Calendar fixture",
  baseUrl: "https://api.example.com/v1/", auth,
  actions: [{ id: "listItems", label: "List items", requireAuth: auth.type !== "none", requireApproval: false,
    inputSchema: { type: "object", additionalProperties: false },
    outputSchema: { type: "object", properties: { count: { type: "integer" } }, required: ["count"], additionalProperties: false },
  }],
});

const oauth: APIAuth = { type: "oauth2", flow: "authorizationCode", authorizationURL: "https://accounts.example.com/authorize",
  tokenURL: "https://accounts.example.com/token", clientID: "public-client", redirectURI: "com.example.ox:/callback",
  scopes: ["read"], pkce: "S256" };

describe("API service contracts", () => {
  for (const auth of [{ type: "none" }, { type: "apiKey", in: "header", name: "X-API-Key" },
    { type: "apiKey", in: "query", name: "key" }, { type: "http", scheme: "basic" },
    { type: "http", scheme: "bearer" }, oauth] as APIAuth[]) {
    test(`supports ${JSON.stringify(auth)}`, () => {
      expect(validateServiceManifest(makeService(auth)).ok).toBe(true);
    });
  }
  test("API repository identities do not require website domains", () => {
    expect(validateRepositoryPackage({ version: 1, name: "API", services: ["api:calendar-fixture"] })).not.toHaveProperty("error");
  });
  test("rejects secret-bearing auth configuration", () => {
    expect(validateServiceManifest(makeService({ ...oauth, clientSecret: "must-not-be-in-source" } as APIAuth)).ok).toBe(false);
  });
  test("rejects unsafe API and OAuth destinations", () => {
    for (const baseUrl of ["http://api.example.com/", "https://user:password@api.example.com/", "https://api.example.com/?key=value"]) {
      expect(validateServiceManifest({ ...makeService(), baseUrl }).ok).toBe(false);
    }
    for (const tokenURL of ["http://accounts.example.com/token", "https://user:password@accounts.example.com/token"]) {
      expect(validateServiceManifest(makeService({ ...oauth, tokenURL })).ok).toBe(false);
    }
  });
  test("does not require web sign-in actions for OAuth", () => {
    expect(validateServiceManifest(makeService(oauth)).ok).toBe(true);
  });
  test("rejects auth on a web service", () => {
    expect(validateServiceManifest({ ...makeService(), kind: undefined, domain: "api.example.com" }).ok).toBe(false);
  });
  test("rejects page configuration and web handoffs on API actions", () => {
    const service = makeService(oauth);
    for (const patch of [{ baseUrl: service.baseUrl }, { blocking: true }, { id: "getSignInUrl" }]) {
      expect(validateServiceManifest({ ...service, actions: [{ ...service.actions[0], ...patch }] }).ok).toBe(false);
    }
  });
});
