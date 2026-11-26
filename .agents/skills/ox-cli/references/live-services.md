# Live services

## Exercise live services in a Profile

```sh
ox [--profile <ws-url>] service list [--json] [--timeout 30000]
ox [--profile <ws-url>] service invoke <domain>:<action> --args '<json>' [--session '<descriptor>' | --session-file <path|->] [--page-url <https-url>] [--approve] [--timeout 30000]
ox [--profile <ws-url>] service eval <domain> --script '<javascript>' [--timeout 30000]
ox [--profile <ws-url>] service reload <domain> [--timeout 30000]
ox [--profile <ws-url>] service refresh-auth <domain> [--timeout 30000]
ox [--profile <ws-url>] service sync [--timeout 60000]
```

Opening or attaching a service does not check access or request setup. Invoke the service type's standard actions through `ox.service.invoke`: web listSessions/login, API credentialStatus/configureCredentials, MCP connectionStatus/authorize, and iOS permissionStatus/requestPermission. These actions accept empty input; web target routing uses the input-resolved action/service baseUrl unless top-level pageUrl overrides it; session selects account/context, not the destination. Full standard contracts are supplied upfront. `ox.service.inspect` returns service metadata, standardActions availability, complete non-standard contracts (up to ten), typed secret references, and nextCursor. Reuse those contracts immediately; inspect with nextCursor for additional pages or without it for a later refresh. Inspection policies still apply; discovery failure throws and never establishes that actions are absent. API configuration is not server verification; MCP connectivity is not tool authorization; device permission is not account access. Ask/Block fail without discovery, and errors never establish absence. Website completion only acknowledges interaction. Ordinary website invocations without `--session` or `--session-file` discover fresh sessions under normal Action policies and use the first returned descriptor, including when `--page-url` is provided. Explicit descriptors take precedence, are revalidated, and fail rather than switching accounts if stale. Discover and pass a descriptor for a specific account/tenant or account-stable consequential work; do not preflight every action. No sessions leaves public actions public and protected actions authentication-required. `--page-url` independently selects the initial navigation target within the selected account/context and also routes initial default discovery. It can combine with `--session` or `--session-file`. Without `--page-url`, the input-resolved action/service baseUrl wins even when a session is selected; session.url is validated context metadata only. Both destinations must remain within the service domain, and fresh target-page discovery must confirm the selected account/tenant. Website interaction requires the conversation VM; direct CLI invocation does not bypass it. Existing saved signIn and access-check policies remain authoritative for the corresponding Ox setup/status actions.

Use `ox [--profile <ws-url>] service mcp [--timeout 30000]` as a stdio MCP server. It exposes Ox's available actions with stable tool names and input/output schemas; arguments wrap action data in `input`, with optional `session` and `pageUrl` beside it. Successful results wrap action output in `value`, returned as both MCP `structuredContent` and JSON text; failures use `isError` without structured success output. Action metadata requires an updated Ox. Discovery refreshes every ten seconds and signals tool-list changes. Remote MCP tools appear after Profile discovery; the adapter never initiates authorization or grants approval. Stdout is reserved for MCP messages; diagnostics use stderr.

Treat `invoke` as a real action that may read authenticated data or mutate
external state. Supply `--approve` only when the user's request authorizes the
effect. Treat `service eval` as arbitrary code on a Ox-managed service page
and keep it narrowly scoped.

All service invocations automatically attach the matching service to the selected
conversation when needed. The existing attachment and action policies still apply.
Inspection alone does not attach a service, and automatic attachment does not grant
native permissions or authenticate an account.

For conversation-driven login or human verification, use VM page lifecycle functions
and browser.showPage with the exact pageId. Explain the user's step before calling,
await the result in the same execution, stop dependent work on cancelled, and verify fresh
state after completed. Never select a page engine or replay an action to recover its page.

## Browser pages and attachments

Do not select or infer a web-page engine. Ox owns service adapters and rendering.
In a conversation VM, the agent explicitly opens/lists/closes pages through ox.web.browser,
uses pageId for lifecycle/navigation/handoff, and frameId for document inspection,
scripts, and web service invocation. Discover fresh document IDs after navigation.
The active Profile allows eight agent pages total; frames do not count separately. pages exposes lastActiveAt and busy, sorted oldest first. At capacity newPage closes the oldest idle page across conversations and returns fresh IDs; active operations, opening/loading pages, secrets, and user handoffs are protected. Close owned idle pages when no longer needed.
Direct ox service commands retain Ox-managed routing and address services by domain.
Service inspection loads the current valid source without attaching it. Invocation automatically attaches its service to the conversation when needed, under normal attachment policy. Use `ox.service.attach`, `ox.service.listAttached`, and `ox.service.detach` through the VM to manage attachments explicitly. A later invocation reattaches a detached service. Attachment does not grant permissions or authentication.
