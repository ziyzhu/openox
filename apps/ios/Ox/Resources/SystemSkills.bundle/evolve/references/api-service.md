# API Service

Build Local API services inside Ox from published API documentation and verified responses. The Host executes handlers in an isolated JavaScript runtime and owns HTTP authentication. No website page, cookies, DOM, browser globals, or shell is available.

## Contract

Create with `ox.service.create({ kind: "api", domain, purpose })`. Use a stable lowercase identifier such as `google-calendar`; it is independent of the API hostname. Source lives at `services/api/<domain>/service.json` and `actions.js`. Copy an existing repository service into Local before editing it.

The manifest uses `kind: "api"`, `domain`, `name`, optional `description`, a static HTTPS `baseUrl`, required `auth`, optional `$defs`, and `actions`. Actions retain `id`, `label`, `description`, concrete `inputSchema` and `outputSchema`, `requireAuth`, `requireApproval`, and optional `defaultArgs`. Use Capability in visible copy. API actions cannot declare `baseUrl`, `blocking`, or web sign-in, bot-control, or payment pairs.

Authentication configurations:

- `{ "type": "none" }`
- `{ "type": "apiKey", "in": "header", "name": "X-API-Key" }`, or `in: "query"`
- `{ "type": "http", "scheme": "basic" }`, or `scheme: "bearer"`
- `{ "type": "oauth2", "flow": "authorizationCode", "authorizationURL": "https://accounts.example.com/authorize", "tokenURL": "https://accounts.example.com/token", "clientID": "registered-public-client", "redirectURI": "com.example.app:/callback", "scopes": ["read"], "pkce": "S256" }`

OAuth requires an existing registered public client and its application callback URI. Do not invent a working client ID, use a desktop loopback redirect for an iOS client, or put client secrets in source. Authorization and token URLs must be HTTPS without credentials, query, or fragment. The Host opens the system sign-in flow and refreshes tokens. The user enters API keys, passwords, and bearer tokens through the service sign-in interface; never request them in chat, action inputs, or files.

Mark authenticated capabilities `requireAuth: true`; public capabilities can use false. For authentication use `ox.service.signIn`. Changing the API base URL or authentication configuration requires setup again. Setting credentials does not prove the API accepts them; verify a small authenticated read.

## Handlers

```js
window.ox.install(({ action, request }) => {
  action("listItems", {
    async invoke({ cursor, limit = 50 }) {
      const page = await request({
        path: "items",
        query: { pageToken: cursor ?? null, maxResults: limit }
      });
      return {
        items: (page.items ?? []).map(item => ({ id: item.id, name: item.name })),
        nextCursor: page.nextPageToken ?? null
      };
    }
  });
});
```

`request({ path, method?, query?, json? })` returns decoded JSON, or null for an empty successful response. The default method is GET. Paths resolve against `baseUrl` and must stay within its origin and path prefix. Use a trailing slash on `baseUrl`. Query values are URL-encoded; null values are omitted. Supply JSON bodies through `json`; the Host sets the content type. Other response formats and custom request headers are not supported in this first version.

Declare approval for mutations. The Host rejects POST, PUT, PATCH, and DELETE from capabilities without `requireApproval: true`. It does not retry requests automatically or follow redirects. HTTP and decoding failures throw. Never blindly repeat a mutation after an uncertain result; inspect resulting state first.

Install synchronously exactly once and register every declared action exactly once. Keep work inside handlers. The installer passes only `action` and `request`; put any text helpers directly in `actions.js` and use `console.log` for diagnostics. Return narrow results matching output schemas; use actual server pagination cursors. Tokens and authorization headers are unavailable to handlers.

## Workflow

1. Discover existing coverage and read official API documentation. For Google, use Google Discovery documents and googleworkspace/cli as request and workflow references.
2. Identify bounded operations, permissions, pagination, and mutation effects. Reuse the user's approved scope; ask only about meaningful unresolved decisions.
3. Create or copy the service, edit through `ox.fs`, then call `ox.service.validate` and `ox.service.attach`.
4. Complete setup through `ox.service.signIn`. Inspect contracts and invoke names such as `api:google-calendar:listCalendars`.
5. Verify successful reads, empty results, continuation, missing resources, and auth errors. Exercise mutations only with authorization. Report inaccessible or unverified capabilities explicitly.
6. Inspect Local status and diff, then request **Save** for the verified service. Preserve unrelated changes and use the existing Local Git workflow internally.

Credentials are stored separately in the Host's Keychain, bound to this service, repository, base URL, and auth configuration. Source and replay fixtures must contain only public configuration and synthetic or sanitized examples.
