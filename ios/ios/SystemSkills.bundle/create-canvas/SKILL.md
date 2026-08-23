---
name: create-canvas
description: Create and present a responsive visual or interactive Canvas, including explainers, simulators, charts, comparisons, maps, and small offline tools.
---

# Create a Canvas

Create a Canvas when a visual relationship, adjustable scenario, simulation, chart, map, comparison, or small tool will communicate better than chat prose or a note. Use the smallest composition that makes the idea clear.

## Choose the form

- Use labeled HTML or inline SVG for static flows, hierarchies, timelines, and comparisons.
- Use native controls and local JavaScript for adjustable inputs, simulations, calculators, and stateful explainers.
- Start numeric analysis with the plot. Put values and takeaways on marks, axes, or annotations instead of surrounding the chart with dashboard cards.
- Use one dominant visual, compact controls, and at most one short selected-state detail. Avoid permanent toolbars, repeated legends, decorative metrics, and duplicate views of the same data.
- Keep ordinary prose, a short list, or a simple table in chat unless interaction or spatial structure materially helps.

## Write the artifact

Write one self-contained UTF-8 HTML fragment to a short lowercase `artifacts/<name>.html` path with `ox.fs.write`. Put markup, `<style>`, and `<script>` in that file; omit `<!doctype>`, `<html>`, `<head>`, and `<body>`. Keep it below 200 KB. A successful write presents the Canvas automatically, so do not present it again.

Canvases run offline under a restrictive content policy. Do not use network requests, remote subresources, external libraries, `<form>` elements or submission, frames, file input, workers, object embeds, sensors, geolocation, camera, or microphone. Native `button`, `input`, and `select` controls are allowed only for local interaction. Keep all data and logic inline.

Give the fragment one unique root ID. Scope CSS and DOM queries to that root. Put the script after its markup, verify every queried element exists, and make the primary interaction update both the visual and its accessible state. Do not depend on browser storage or ambient globals.

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

Read an existing Canvas before revising it and use `ox.fs.edit` for targeted changes. After writing, read the file back and verify its path, size, offline constraints, responsive structure, control labels, element IDs, and default state. Keep the chat reply brief because the Canvas carries the explanation.
