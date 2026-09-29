---
name: visualize
description: Create or revise visual explanations and interactive tools, including charts, diagrams, comparisons, maps, simulations, and calculators, as HTML canvases. Use when spatial structure or interaction improves understanding.
---

# Visualize

Choose a Canvas when a visual relationship or adjustable scenario communicates better than prose. Keep simple answers, lists, and small tables in chat. Ordinary Markdown notes and artifact file operations use `ox.fs` and `ox.artifact` directly.

Canvas appears inline in Ox chat on iPhone and iPad, with an option to expand it. Design the inline mobile view first: make its first screen useful at phone width, keep controls touch-friendly, and let the same content grow naturally when expanded. Do not rely on expansion, hover, or a desktop-sized viewport to reveal the main result.

Read `skills/visualize/references/canvas.md` before creating or revising a Canvas. It defines the supported HTML format, responsive and accessible design, local media and maps, and the Canvas service SDK.

Build one focused visual around the user's question. Use inspected service contracts when the visual needs live data or actions. Preserve Host authentication and Action policies, and show pending, successful, and failed states accurately.

Read an existing Canvas before revising it. Edit the same artifact path when a later message changes that Canvas; use a new path for a distinct visual. Write or edit its self-contained HTML under `artifacts/`; successful writes and edits display it automatically. Verify the content constraints, layout, labels, and interaction states, then keep the chat response brief.
