---
name: visualize
description: "Use when the user wants a diagram, drawing, visual explanation, simulation, interactive tool, or small app. Choose Mermaid, SVG, or self-contained HTML according to the task. Keep ordinary answers, lists, and small tables in conversation."
---

# Visualize

Choose the lightest form serving the user's task. Ordinary Markdown and file operations use `ox.fs` directly; do not make a visual file for every answer.

| Result | Default |
| --- | --- |
| Flow, sequence, state, class, entity relationship, mind map, timeline, Gantt, or pie diagram | Mermaid in the reply; no file |
| Static illustration, icon, or fixed drawing Mermaid cannot express | Self-contained SVG file |
| Data plot, spatial comparison, explorable explanation, simulation, interactive tool, or app | Read `references/html.md` before authoring HTML |

Do not load HTML guidance for a Mermaid-only or SVG-only task. Add interaction only when it serves the task; tools and apps need a useful primary workflow, not a forced narrative or chart.

## Mermaid

Put standard Mermaid source in a fenced `mermaid` block. The completed reply renders it as a static, theme-aware, phone-width diagram; tapping opens a zoomable view. Keep one idea per diagram, short labels, and about 15 nodes at most; split larger structures.

Do not add `%%{init}%%`, `classDef` colors, `click` callbacks, links, or images; these are ignored or break the Ox theme. Check brackets, arrows, and quoting; invalid source remains a plain code block. Make relationships understandable through labels rather than color alone.

## SVG

Write a self-contained UTF-8 drawing to a short lowercase `<name>.svg` path with `ox.fs.write`. Give the root `<svg>` an `xmlns`, `viewBox`, and concise `<title>`. Use system fonts and inline attributes or `<style>`, with no scripts, event handlers, links, external references, or embedded fonts. SVG renders as a non-interactive image on white; use HTML for controls, theme-aware colors, or live data. Keep SVG below 1 MB.

Show the drawing with `![Short title](<name>.svg)` on its own line. Give necessary relationships a text alternative; do not rely solely on color. Read the file back to verify size, structure, accessible name, and requested content before reporting completion.

## Revise and finish

Read an existing file completely before editing, following `ox.fs.read` continuation offsets. Revise the same path: existing messages open its current contents, not historical bytes. Moving or renaming retires old references, so embed the new path again. Use `ox.fs.copy` only for an independent copy.

Distinguish sourced facts, adjustable assumptions, and calculated estimates. For analysis, include relevant attribution, dates, units, formulas, and limits in the result. Do not invent provenance or describe an illustrative model as a verified prediction. Keep the reply brief when the file carries the result.
