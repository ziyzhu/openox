# HTML Results and Apps

Read before creating or substantially revising HTML. Build the requested experience, not a generic dashboard. Static comparisons need no interaction; explanations should be readable by default and let readers inspect assumptions. Simulations need meaningful starting conditions, clear controls, and pause/reset when useful. Apps need a useful starting or empty state and a clear primary workflow.

## Interface and state

- Keep related labels, controls, results, and feedback together. Use labeled native inputs or tap-to-edit controls, not hover-only or drag-only affordances. Add only useful navigation; preserve unfinished input across views and distinguish selection from execution.
- Place plots beside their supporting claims. Show values on marks, axes, or annotations. Keep labels/scales stable for comparison or explicitly disclose scale changes. Update conditional prose and conclusions along with numbers.
- Separate independent inputs, constants, and view state. Validate bounds and units before calculation or submission. Use reset/clear only when useful. For reactive calculators, read `references/reactive-example.md` only if a model-and-binding example would help; it is optional, not an injected API.
- Distinguish hypothetical inputs and local drafts from service records. Sliders and field edits must not silently perform real-world actions. Use explicit refresh/action controls rather than invoking on every input change.
- Model asynchronous work as idle, pending, succeeded, and failed. Capture submitted inputs, prevent duplicate mutations, retain drafts on failure, and never attribute a stale response to newer inputs.
- The file is durable; its live page state is not. Do not promise persistence across closing/replacement unless an inspected service contract provides it. HTML cannot write Profile files or rely on browser storage.

## Phone and tablet layout

Design the bounded inline conversation card first, with useful content and the primary control visible at phone width; expansion is optional. Support 320 px through iPad without horizontal page scrolling, clipped labels, fixed outer widths, or fixed viewport heights. Wrap or stack controls. Do not rely on expansion, hover, or desktop width.

Default to Ox's existing theme, not a custom dashboard skin, font, gradient, or decorative chrome unless requested. Use one readable column, equal outer-edge padding normally 16 px, transparent outer background, spacing and tonal grouping rather than borders/shadows. Do not imitate Host navigation, composer, or approval controls.

Define root-scoped palette variables and reuse them in HTML and SVG:

| Variable | Light | Dark |
| --- | --- | --- |
| surface | #FFFFFF | #1C1C1E |
| surface-sunken | #F2F2F7 | #2C2C2E |
| background | #F2F2F7 | #0A0A0A |
| on-surface | #000000 | #ECECEC |
| on-surface-muted | #8E8E93 | #9A9A9A |
| primary | #FFA500 | #F5A030 |
| primary-pressed | #D87A0A | #C77410 |
| error | #B8422E | #E25A45 |

Support `color-scheme: light dark` and `prefers-color-scheme: dark`; maintain text contrast and subtle large fills. Reserve gold for at most one primary action or active series per visible region. Use surface-sunken for recessed accents.

Match system body typography at 17 px/400 (`-apple-system, system-ui, sans-serif`), rounded headings at 22 px/600, and rounded labels at 17 px/600 (`ui-rounded, -apple-system, system-ui, sans-serif`). Monospace is for code or numeric diagnostics; use at most two sizes per visible region. Use the 4/8/12/16/24/32 px spacing scale, 12 px input radii, 18 px group radii, capsule buttons, and touch targets at least 44 px in both dimensions.

## Write the file

Write one self-contained UTF-8 fragment below 200 KB to a short lowercase `<name>.html` path in the conversation working directory with `ox.fs.write`. Begin with `<meta name="viewport" content="width=device-width, initial-scale=1">` and `<meta name="color-scheme" content="light dark">`. Include markup, style, and script inline; omit doctype/html/head/body wrappers. Writing does not display it: embed `![Short title](<name>.html)` on its own reply line.

Use one unique root ID and scope CSS/DOM queries to it. Put scripts after markup, check queried elements, initialize once, and update accessible state with primary interactions. Do not depend on ambient globals or browser storage. Read existing files completely before revision and keep the same path unless an independent copy is requested.

The content policy forbids browser network requests, remote subresources, external libraries, form submission, frames, file input, workers, object embeds, sensors, geolocation, camera, and microphone. Inline native buttons, inputs, and selects can update local state or call the injected Host service SDK.

## Host service SDK

The Host injects `window.ox.service` before scripts. Only this namespace is available, not `ox.fs`, `ox.web`, `ox.user`, or other VM APIs. Use inspected action contracts, normal options objects and `purpose`, and synchronous `.help()`.

HTML runs independently of its creating conversation. Services initialize on demand; do not call conversation-only `attach`, `detach`, or `listAttached`. Use `find`/`inspect` and qualified `web:<domain>:<action>`, `ios:<app>:<action>`, or `mcp:<server>:<action>` names. Discovery reports `attached: false` because the page has no conversation attachments.

Invoke with `await ox.service.invoke({ name, input, purpose })`. Authentication, Action policies, sign-in, verification, payment, and Always allow settings remain authoritative. Do not add a second approval form or claim success before resolution. Disable pending mutation controls, show loading/failure/success, never automatically retry mutations, and render returned text with `textContent`, not interpolated HTML. Verify effects from actual returned or re-read state.

Closing/replacing a page cancels pending calls and releases resources, not effects already sent or OS permission alerts. Keep state in the page, not the conversation or Profile filesystem. Service outputs are temporary and removed at close.

Calls serialize per page: at most 16 pending, 120 admissions/minute, 1 MiB arguments, 8 MiB response. Cancellation is requested after 60 seconds of active execution, excluding prompt/handoff waiting. Temporary outputs are capped at 32 files and 20 MiB. Show limit errors rather than retrying in a loop.

## Media and maps

Reference sibling media paths directly in `src`, never host filesystem paths. For maps use:

```html
<ox-map latitude="…" longitude="…" radius="…" aria-label="…">
  <ox-marker latitude="…" longitude="…" label="…"></ox-marker>
</ox-map>
```

## Verify

Use semantic headings/lists/tables, labeled native controls, native tab order, retained focus, and labels/shapes in addition to color. Name SVG accessibly and provide text alternatives for relationships. Announce changing results with restrained `aria-live`. Avoid animation unless it explains a state change; honor reduced motion.

Read the file back to check path, size, content policy, responsive layout, labels, IDs, and default state. Test baseline/reset, adjustable extremes, invalid/missing inputs, and both sides of thresholds. Check units, calculations, and agreement between prose, labels, and graphics; show unavailable results instead of NaN, infinity, or stale data. Exercise primary workflow, navigation, draft preservation, pending/failure states, duplicate prevention, and closing/reopening without assuming persistence. Report what was actually exercised; source inspection alone is not rendered UI or live-service verification.
