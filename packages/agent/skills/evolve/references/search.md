# Standard web search

Web services optionally expose one read-only action named `search` for use by `ox.web.search`. Other `search*` actions do not opt in. Do not invent a `searchAction` manifest field or require every service to support this contract. API, MCP, and iOS services are not targets of this orchestration.

Choose one evidence-backed default scope: notes for Xiaohongshu, posts for X, products for a store, or articles for a publication. State it in the action description. Keep other scopes and structured searches as specialized actions. If additional inputs such as dates, server, employer, framework, project, or workspace are required, do not guess them or claim query-only search support.

Use the exact standard input shape. The service may lower the limit maximum below fifty; keep the default within its bounds. Query syntax remains website-specific. Sessions belong in top-level invocation context, not action inputs.

```json
{
  "type": "object",
  "properties": {
    "query": {"type": "string", "minLength": 1},
    "limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 10},
    "cursor": {"type": "string", "minLength": 1}
  },
  "required": ["query"],
  "additionalProperties": false
}
```

Return this envelope and declare concrete matching output schemas:

```ts
{
  items: [{
    title: string,
    url: string | null,
    snippet: string | null,
    id?: string,
    data?: object
  }],
  nextCursor: string | null,
  scope: string,
  coverage: "complete" | "partial" | "unknown"
}
```

Require `items`, `nextCursor`, `scope`, and `coverage`; require item `title`, `url`, and `snippet`. Close both objects with `additionalProperties: false` and enforce the requested limit in the handler, never exceeding fifty. The service-manifest schema vocabulary does not support `maxItems`; do not add it. Declare the optional ID as a string and any `data` fields through explicit properties or a local resource schema reference. Preserve source fields needed by detail actions rather than discarding them during normalization.

Normalize names to title, links to URL, and excerpts/previews to snippet. Use a nonblank source title or short source-derived display label; do not invent headlines. Use null for unavailable URLs or snippets, never fabricated links. IDs are optional, source-owned, and service-scoped. Preserve required opaque resource links for detail lookup but exclude their token components from diagnostics.

Return a source continuation unchanged. Never fabricate a cursor over a rendered snapshot. If no continuation is exposed, return null and reject supplied cursors rather than silently repeating page one. Bind continuations to the same query and selected account. A non-null cursor requires `coverage: "partial"`. Null does not prove completeness: use `unknown` unless source evidence establishes either incomplete coverage (`partial`) or exhaustive results (`complete`). Ranked, typeahead, capped, or degraded searches must not claim exhaustive coverage. Scope must accurately describe any narrower title-only, account, or content subset.

Install `action("search", { async invoke(input, context) { ... } })` through the normal installer. Set `requireApproval: false`; set `requireAuth` according to actual access. Do not opt in chat, send, generation, or other mutations. Do not bypass sessions or runtime policy. Rename compatible default actions and update affected skill references; retain a specialized action only for meaningfully different inputs or scope, sharing implementation where needed instead of duplicating it.

Use `ox.web.search({ purpose, query, domains: ["<domain>"] })` to verify orchestration. It invokes `web:<domain>:search` through normal policy without attaching or saving the service. Up to six explicit domains are searched concurrently. If a requested domain has no service or compatible search action, build or extend it through Evolve, verify it, then retry that domain. For authenticated search, discover sessions through `listSessions` and pass `{ sessions: { "<domain>": descriptor } }`. Continuations use `{ cursors: { "<domain>": nextCursor } }`. Explicit targets are not substituted; do not switch accounts or fall back to public engines after a private failure.

Verify the action first through `ox.service.invoke` on a fresh execution page, without Browser or sibling-action priming. Check a real result and detail lookup with its returned identifier, bounded limits, first/next pages where supported, genuine empty results, selected-account evidence, and a blocked or unready state. CAPTCHA, consent, missing login, timeout, changed markup, or malformed source data must throw rather than return an empty successful page. Do not repeat mutations to test search. Keep logs to safe action/phase/count evidence, not raw queries or private content.
