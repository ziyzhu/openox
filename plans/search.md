# Unified service search

Status: integrated into `main` from the isolated search worktree based on `1d25e4d7`. Existing uncommitted authentication work was preserved. Combined service packaging, build checks, protocol tests, and both native builds pass. Authenticated live verification remains pending.

Goal: keep the public name `ox.web.search`, replacing its separate native backend with ordinary service search actions. Do not introduce `ox.search` or a compatibility wrapper.

## Agreed direction

- Services opt in by exposing an action named `search` that satisfies the standard contract. No `searchAction` manifest field.
- Targets use qualified IDs such as `web:google.com`. Each target invokes `<service>:search` through normal attachment, validation, authentication, execution, and Action policy.
- One default scope per service. Keep other scopes specialized, such as `searchUsers`, `searchJobs`, and `searchOrders`.
- Provider-specific navigation and extraction belong in bundled services. Remove the native public-search engine, not the public function name.
- Keep `ox.service.find` for repository discovery; do not couple every content search to service suggestions.

## Function contract

```ts
await ox.web.search({
  purpose: "Find Swift documentation",
  query: "Swift structured concurrency",
  services: ["web:google.com", "web:duckduckgo.com"],
  limit: 10,
  cursors: {},
  sessions: {}
});
```

- Omitted services uses the bundled Brave, DuckDuckGo, and Google services. Reject an empty list; search at most four services sequentially to bound page concurrency and preserve deterministic per-service ordering.
- Explicit targets search exactly those services, with no substitution or expansion into private services.
- `limit` is per service, defaults to ten, and respects each action's lower maximum, up to fifty.
- Cursor and authenticated-session maps are keyed by exact service ID. A cursor belongs to the same query and account. Never fabricate descriptors or select accounts implicitly.
- Return `{ query, results, errors }`, grouping each successful page under its source service. Preserve partial success and individual errors; throw on total failure. Denial or cancellation stops the call.
- Preserve normal attachment policy on a fresh setup. Do not bypass approvals to make defaults work.

## Standard action contract

```ts
input: { query: string, limit?: number, cursor?: string }
output: {
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

- Require a nonblank query; retain website-specific query syntax. Keep sessions in invocation context.
- Normalize source fields at the action boundary: subject/name to title, excerpt/preview to snippet, product URL to URL. Use evidence-based display labels for untitled results, not invented headlines.
- IDs are optional and service-scoped. Preserve detail-lookup identifiers in explicitly typed `data`; never invent stable IDs or deduplicate private resources by unrelated IDs.
- A remaining cursor implies partial coverage. Null means no continuation is exposed, not that all matching content was searched. Claim complete only with source evidence; preserve degraded or limited scope.
- Blocked, unauthenticated, malformed, or unready search is an error, not zero matches.
- Validate existing actions named `search`; the name alone is not proof of compatibility. Incompatible services remain normally invocable through their existing contracts.
- No generic multi-scope or structured travel-search interface in this change.

## Bundled service migration

- [x] Google: add general web `search`; retain news, images, videos, and suggestions as specialized actions. Places stays on its existing product service.
- [x] Brave and DuckDuckGo: add ordinary bundled web services and bounded search handlers using existing extraction behavior. No native fallback or challenge bypass.
- [x] Wikipedia: rename default article search to `search`, normalize fields, and disclose bounded coverage without continuation.
- [x] Our World in Data: normalize existing `search`; keep chart search specialized.
- [x] X: default `search` covers posts; retain user search and specialized `searchTweets` filters through a shared implementation. Source changes only; legacy authentication blocks manifest validation and live verification.
- [x] Xiaohongshu: rename default note search to `search`; retain user search. Do not fabricate cursors over rendered snapshots. Source changes only; legacy authentication blocks manifest validation and live verification.
- [ ] Taobao: evaluate product search opt-in after account-contract verification.
- [ ] Update affected qualified-name references, translations, fixtures, and skills. Avoid aliases without a demonstrated compatibility requirement.

Further candidates after live verification: FDA site search, Nature articles, NCBI records, Hacker News, Amazon products, LinkedIn, Gmail, Outlook, Models.dev, and AI conversation searches. Preserve account identity, search scope, detail identifiers, and partial-result semantics. Leave board-, server-, framework-, project-, workspace-, and date-dependent searches specialized.

## Evolve and runtime changes

- [x] Teach standard `search` opt-in in `packages/agent/skills/evolve/SKILL.md` and `references/web-service.md`, including exact schemas, field normalization, one default scope, coverage, authentication, and verification.
- [x] Clarify web-only orchestration in `references/api-service.md`; public research still uses `ox.web.search`.
- [x] Require fresh-page invocation, genuine success and empty/error evidence, bounded results, source pagination, account checks, and detail lookup with returned identifiers. Never opt in chat/send/generation as website search.
- [x] Replace the native search bridge with composition over existing service functions. Preserve service policies and cancellation; avoid another browser pool or execution engine.
- [x] Remove obsolete native engine, models, search-only diagnostics, and development configuration. Keep Browser, fetch, and historical invocation rendering intact.
- [x] Update function guidance/contracts and regenerate owned outputs. Edit bundled source under `apps/shared/Resources/OxServices.bundle/`, not package dist artifacts.

## Verification and review

- [ ] Record baseline behavior and blockers before changes. Baseline service build reproduced the existing legacy-authentication failure after dependency installation.
- [ ] Validate default search, explicit targets, unsupported/incompatible contracts, bounds, cursor/session maps, partial and total failure, cancellation, denial, pagination, and no private-target expansion.
- [ ] Verify real website handlers on fresh execution pages. Report blocked authenticated checks separately; do not repair or replace unrelated authentication work.
- [ ] Confirm fresh-setup defaults are reachable through normal attachment policy.
- [ ] Run portable protocol, static/type, packaging, generated-artifact, and bounded provider checks as applicable. Do not add unit tests.
- [ ] Consult Apple WebKit documentation and build both iOS and macOS before committing native changes. Report build blockers; do not commit without approval if either required build cannot run.
- [ ] Review latency, page concurrency, response size, structured diagnostics, and privacy. Keep raw queries, private contents, and opaque tokens out of new logging.
- [ ] Report LOC delta, file-tree diff, call-stack diff, cyclomatic complexity, and performance implications. Capture simulator evidence if presentation changes; otherwise mark visual review non-applicable.

Call-stack change:

```text
Before: ox.web.search → native search bridge → WebSearchEngine → provider-specific native pages
After:  ox.web.search → standard search validation → normal attachment/invocation → service search handler
```

## Verification evidence

- Native macOS Host on `ws://127.0.0.1:19876`, isolated Search QA Profile. No occupied simulator was changed.
- PASS live Brave, DuckDuckGo, Wikipedia, and Our World in Data searches; Wikipedia detail lookup from a returned key; actual source pagination on Our World in Data; genuine empty Wikipedia result.
- PASS default public targets with partial success. Google reports CAPTCHA instead of zero matches; no bypass attempted. A successful Google result remains unverified.
- PASS native VM E2E: nine invalid-input cases without changing attachments, unsupported search, incompatible existing `search` contract, partial success, and absence of an `ox.search` alias. Total failure was observed as an error.
- PASS native search catalog against its portable contract; type checks; offline build checks; eval-definition validation; iOS and macOS compilation.
- PASS individual service builds for all five public opted-in services. Before integration, full service packaging was blocked by 38 baseline authentication contracts. After merging with the preserved authentication work on main, full service packaging and all 15 portable protocol tests pass. CI reaches its generated-source cleanliness guard, which reports the existing uncommitted service edits rather than a build or test failure.
- One fresh-query default-search timing sample: 17,036 ms for Brave and DuckDuckGo success plus Google CAPTCHA failure. Sequential execution bounds active search work to one; no before/after latency claim is made.
- Not verified: authenticated accounts, denial/cancellation UI, real-provider model behavior, all empty/markup-change branches, and Google success. No new presentation controls or layouts; visual UI review is non-applicable.
- Evidence is outside Git under `/tmp/openox-search-*`. The temporary E2E script is not a new unit-test suite. New service icons were not added or fetched from external hosts.

Acceptance: one public search function, one service-action execution path, optional standard `search` actions, explicit account/error/coverage boundaries, and no separate native public-search implementation.
