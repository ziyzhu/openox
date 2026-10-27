# Website Request Capture

Use capture only when metadata or narrow direct probes cannot establish the request/response shape. Default to observed same-origin structured fetch, then stable HTML parsed with DOMParser. Page-owned signing may require a one-shot inherited response capture; do not recreate signatures or retain credentials.

1. Start Browser capture in the target state without bodies or a reload and add a named mark. Reload only for initial document-load traffic. Enable bounded bodies only for a targeted exchange whose shape remains unknown.
2. Exercise one representative non-consequential interaction through an inspected Browser function or narrow page script. Observe relevant requests in that interaction instead of repeating it solely for capture. External mutations belong to approval-gated service actions.
3. Select exchanges using metadata before reading bounded bodies. Keep method, host/path shape, request fields, status, MIME type, response fields, authentication state, and pagination behavior. Exclude private bodies, cookies, authorization/CSRF values, reusable tokens, and signatures from evidence and logs.
4. Stop when the requested action surface has sufficient evidence. Discard capture after inspecting records unless another immediate authoring step needs it. Stop capture and clear injected scripts before human sign-in; never capture credential entry.

When direct requests cannot reproduce page-generated signing, read `references/helpers.js` for copyable `createFetchCapture`. Install `createFetchCapture(window)` at document start, retain its returned function locally, register before triggering the request, and register a fresh capture for each page. It observes fetch/XHR; it is not an installed runtime module. Never import or fetch the reference file from service source.

For stable SPA state instead, navigate within the document, invalidate stale values, and wait for target-specific identity and freshness. Browser evidence never replaces invoking generated handlers on their actual execution pages.

Before completion or abandonment, stop capture with `discard: true` and clear document-start scripts, confirming both cleanup operations succeeded. Do not leave capture or instrumentation active across unrelated work.
