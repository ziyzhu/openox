---
name: visualize
description: "Use when the user wants a diagram, drawing, visual explanation, simulation, interactive tool, or small app. Choose Mermaid, native maps, SVG, or self-contained HTML according to the task. Keep ordinary answers, lists, and small tables in conversation."
---

# Visualize

Choose the lightest form serving the user's task. Ordinary Markdown and file operations use `ox.fs` directly; do not make a visual file for every answer.

| Result | Default |
| --- | --- |
| Flow, sequence, state, class, entity relationship, mind map, timeline, Gantt, or pie diagram | Mermaid in the reply; no file |
| Places on a map with optional tappable details or routes between them | A fenced `map` block in the reply; no file |
| Static illustration, icon, or fixed drawing Mermaid cannot express | Self-contained SVG file |
| Data plot, spatial comparison, explorable explanation, simulation, interactive tool, or app | Read `references/html.md` before authoring HTML |

Do not load HTML guidance for a Mermaid-only or SVG-only task. Add interaction only when it serves the task; tools and apps need a useful primary workflow, not a forced narrative or chart.

## Mermaid

Put standard Mermaid source in a fenced `mermaid` block. The completed reply renders it as a static, theme-aware, phone-width diagram; tapping opens a zoomable view. Keep one idea per diagram, short labels, and about 15 nodes at most; split larger structures.

Do not add `%%{init}%%`, `classDef` colors, `click` callbacks, links, or images; these are ignored or break the Ox theme. Check brackets, arrows, and quoting; invalid source remains a plain code block. Make relationships understandable through labels rather than color alone.

## Maps

Put a JSON object in a fenced `map` block to show places in an iOS conversation. After streaming finishes, tapping the card opens an interactive native map; tapping a marker shows its supplied details and an Open in Maps action on the viewing device. Other clients may show the JSON instead. Include a short text summary outside the block.

```map
{"markers":[{"latitude":37.77,"longitude":-122.42,"label":"Example place","detail":{"title":"Example place","description":"Illustrative marker, not a verified business.","address":"Optional verified address","url":"https://example.com"}}]}
```

Use 1–50 markers, finite latitude from -90 to 90 and longitude from -180 to 180, and at most 64 KiB of JSON. Only latitude and longitude are required. Optional label and placeID are at most 200 characters each; optional detail fields title, description, address, and url are at most 2,000 characters each. Website links must be HTTPS without embedded credentials. Use plain text in detail fields, not Markdown, HTML, scripts, or service calls. Detail content is supplied by you, not fetched or verified by MapKit. Use coordinates and facts from inspected service results or the user; do not invent places or descriptions. Invalid blocks remain code. Add up to 5 optional `routes` between markers, for example `"routes":[{"from":0,"to":1,"transport":"walking"}]`. `from` and `to` are distinct marker indices; `transport` is `automobile` (default) or `walking`; transit is not supported. Apple Maps calculates each route on the viewing device and shows its distance and travel time; do not state your own times or distances for those routes. Every route endpoint must be a marker you supplied. Do not use or insert the user's live location as an origin or to center a map.

## SVG

Write a self-contained UTF-8 drawing to a short lowercase `<name>.svg` path with `ox.fs.write`. Give the root `<svg>` an `xmlns`, `viewBox`, and concise `<title>`. Use system fonts and inline attributes or `<style>`, with no scripts, event handlers, links, external references, or embedded fonts. SVG renders as a non-interactive image on white; use HTML for controls, theme-aware colors, or live data. Keep SVG below 1 MB.

Show the drawing with `![Short title](<name>.svg)` on its own line. Give necessary relationships a text alternative; do not rely solely on color. Read the file back to verify size, structure, accessible name, and requested content before reporting completion.

## Revise and finish

Read an existing file completely before editing, following `ox.fs.read` continuation offsets. Revise the same path: existing messages open its current contents, not historical bytes. Moving or renaming retires old references, so embed the new path again. Use `ox.fs.copy` only for an independent copy.

Distinguish sourced facts, adjustable assumptions, and calculated estimates. For analysis, include relevant attribution, dates, units, formulas, and limits in the result. Do not invent provenance or describe an illustrative model as a verified prediction. Keep the reply brief when the file carries the result.
