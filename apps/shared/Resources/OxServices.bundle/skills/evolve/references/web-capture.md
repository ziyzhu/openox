# Website Request Evidence

Use network events only when metadata or narrow direct probes cannot establish the request/response shape. Default to observed same-origin structured fetch, then stable HTML parsed with DOMParser. Page-owned signing may require a one-shot inherited response capture; do not recreate signatures or retain credentials.

1. Every agent page records events from its first load. Open the target with `newPage({ purpose, url })`; pass `networkContent: "embed"` only when a targeted exchange's body shape remains unknown. No reload is needed for document-load traffic.
2. Save `nextCursor` from `events({ purpose, pageId })` before one representative non-consequential interaction, then exercise it through an inspected Browser function or narrow page script. Observe the relevant requests instead of repeating the interaction. External mutations belong to approval-gated service actions.
3. Read only what followed with `events({ purpose, pageId, after: cursor, event? })`; `request`, `response`, `requestfinished`, `requestfailed`, and `websocket` describe traffic, and `console`/`pageerror` explain failures. Use `waitForEvent` to await one future event. `readEventBody` with `mode: "shape"` shows bounded JSON structure without scalar values; body completeness remains unknown and field names may still be private. Keep method, host/path shape, request fields, status, MIME type, response fields, authentication state, and pagination behavior. Exclude private bodies, cookies, authorization/CSRF values, reusable tokens, and signatures from evidence and logs.
4. Stop when the requested action surface has sufficient evidence. showPage pauses recording, so credential entry is never recorded; close pages opened with embedded bodies when authoring ends.

When direct requests cannot reproduce page-generated signing, read `references/helpers.js` for copyable `createFetchCapture`. Install `createFetchCapture(window)` at document start, retain its returned function locally, register before triggering the request, and register a fresh capture for each page. It observes fetch/XHR; it is not an installed runtime module. Never import or fetch the reference file from service source.

For stable SPA state instead, navigate within the document, invalidate stale values, and wait for target-specific identity and freshness. Browser evidence never replaces invoking generated handlers on their actual execution pages.

Before completion or abandonment, close authoring pages and confirm no init script remains on reused pages. Do not leave embedded-body pages open across unrelated work.
