# Canvas

Create a Canvas when a visual relationship, adjustable scenario, simulation, chart, map, comparison, or small tool will communicate better than chat prose or a note. Use the smallest composition that makes the idea clear.

## Choose the form

- Use labeled HTML or inline SVG for static flows, hierarchies, timelines, and comparisons.
- Use native controls and local JavaScript for adjustable inputs, simulations, calculators, and stateful explainers.
- Start numeric analysis with the plot. Put values and takeaways on marks, axes, or annotations instead of surrounding the chart with dashboard cards.
- Use one dominant visual, compact controls, and at most one short selected-state detail. Avoid permanent toolbars, repeated legends, decorative metrics, and duplicate views of the same data.
- Keep ordinary prose, a short list, or a simple table in chat unless interaction or spatial structure materially helps.

## Write the artifact

Write one self-contained UTF-8 HTML fragment to a short lowercase `artifacts/<name>.html` path with `ox.fs.write`. Put markup, `<style>`, and `<script>` in that file; omit `<!doctype>`, `<html>`, `<head>`, and `<body>`. Keep it below 200 KB. A successful write presents the Canvas automatically, so do not present it again.

Canvases run under a restrictive content policy. Do not use browser network requests, remote subresources, external libraries, `<form>` submission, frames, file input, workers, object embeds, sensors, geolocation, camera, or microphone. Keep markup and scripts inline. Native `button`, `input`, and `select` controls may update local state or invoke Host services through the injected `ox.service` SDK.

Give the fragment one unique root ID. Scope CSS and DOM queries to that root. Put the script after its markup, verify every queried element exists, and make the primary interaction update both the visual and its accessible state. Do not depend on browser storage or ambient globals.

## Use Host services

The Host injects `window.ox.service` before canvas scripts run. Use the same options objects, `purpose`, service action contracts, and synchronous `.help()` methods as in the agent VM. Only the service namespace is available; do not call `ox.fs`, `ox.web`, `ox.user`, or other VM namespaces from a canvas.

Canvas runs independently of its creating chat. Services resolve and initialize on demand. Do not call `attach`, `detach`, or `listAttached`; these methods are chat-only. Use `find` for discovery and `inspect` for action contracts. Always use a qualified `web:<domain>:<action>`, `ios:<app>:<action>`, or `mcp:<server>:<action>` name. Discovery and inspection report `attached: false` because canvas has no chat attachments.

Invoke a known action with `await ox.service.invoke({ name, input, purpose })`. Host authentication, sensitive-action approvals, sign-in, verification, payment, and existing Always approve settings work as they do in chat. Do not implement a second approval form in HTML or claim an action succeeded before the promise resolves. Disabling a button while its operation is pending prevents accidental duplicate actions. Show loading, failure, and success states; never retry mutations automatically. Render returned text with `textContent`, not interpolated HTML.

Closing or replacing a canvas cancels pending calls and releases its service resources. Keep interactive state in the page; do not depend on chat state or a Profile filesystem. Service-produced files are temporary and closing the canvas removes them.

Calls are serialized per canvas, with at most 16 pending calls, 120 admissions per minute, 1 MiB request arguments, and an 8 MiB response. Cancellation is requested after 60 seconds of active execution; time waiting for canvas prompts and handoffs does not count. Cancellation cannot undo service requests already sent or dismiss operating-system permission alerts. Temporary outputs are limited to 32 files and 20 MiB. Surface limit errors instead of retrying in a loop.

## Compose for iPhone and iPad

- Use a transparent or neutral page and one readable column by default. Favor a few large, legible elements over dense layouts.
- Support widths from 320 px through iPad without horizontal page scrolling, clipped labels, fixed viewport heights, or fixed outer widths. Let controls wrap or stack with a media query.
- Use native body type around 17 px, no more than two type sizes per visible region, an 8 px spacing rhythm, 12-18 px radii, and touch targets at least 44 px tall.
- Separate structure with spacing and tonal surfaces, not borders or shadows. Use Ox harvest gold `#FFA500` for at most one primary action or active series per visible region; use pale hay `#FDF2D9` only for small recessed accents.
- Support light and dark appearance with `color-scheme` and `prefers-color-scheme`. Keep text contrast readable and large color fills subtle.

## Make interaction accessible

Use semantic headings, lists, tables, buttons, and labeled native controls. Keep the native tab order and focus behavior. Pair color with labels, shapes, or line styles. Give SVG a concise accessible name and provide a text alternative for any relationship that cannot be understood from its labels. Announce changing results with a restrained `aria-live` region.

Keep presentation state local. Use one control mechanism per state, derive the entire visual from current inputs, and test the default plus both extremes of every adjustable value. Avoid animation unless it explains a state change; honor `prefers-reduced-motion` when motion is useful.

## Use local media and maps

Reference sibling image, audio, or video artifact basenames directly in `src`; never embed a host filesystem path. For a map, use:

```html
<ox-map latitude="…" longitude="…" radius="…" aria-label="…">
  <ox-marker latitude="…" longitude="…" label="…"></ox-marker>
</ox-map>
```

Read an existing Canvas before revising it and use `ox.fs.edit` for targeted changes. After writing, read the file back and verify its path, size, content-policy constraints, responsive structure, control labels, element IDs, and default state. Keep the chat reply brief because the Canvas carries the explanation.
