---
name: visualize
description: "Create or revise HTML files for visual results, explorable explanations, simulations, interactive tools, and small apps. Keep ordinary answers, lists, and small tables in chat."
---

# Visualize

Create an HTML file when the user wants a visual result, an interactive experience, or a small app. Choose the simplest composition that serves the task; explanations are one option, not a requirement. Keep ordinary answers, lists, and small tables in chat. Ordinary Markdown and file operations use `ox.fs` directly.

## Choose the experience

- Static visuals: use labeled HTML or inline SVG for diagrams, flows, hierarchies, timelines, and comparisons; use plots for data patterns and maps for spatial relationships. Do not add interaction without a purpose.
- Explorable explanations: combine authored prose with an inspectable model. Make the default readable without interaction, then let the reader question assumptions and see the consequences change.
- Simulations: show how a system behaves as inputs or time change. Use meaningful starting conditions, clear controls, and a way to pause or restore the baseline.
- Tools and apps: help the user calculate, select, organize, configure, or perform a task. Provide a useful starting or empty state and a clear primary workflow; do not force the interface into a narrative or chart.
- Combine forms when they serve the same goal. A trip-planning app can use a map, editable itinerary, and explicit service actions; not every screen needs an explanation or visualization.

## Compose the interface

- Organize content around the user's task. Keep labels, relevant controls, results, and feedback close together. Use labeled native inputs or tap-to-edit buttons rather than hidden hover affordances or drag-only numbers.
- Give apps only the navigation and views their workflow needs. Preserve unfinished input when switching views, distinguish selection from execution, and avoid decorative metrics, redundant panels, and toolbars without useful actions.
- Place plots beside the data or claims they support. Put values and takeaways on marks, axes, or annotations. Link prose, diagrams, plots, and maps when each reveals a different aspect; a changing sentence can be the main result and a chart is not mandatory.
- For analysis and explanations, distinguish sourced facts, adjustable assumptions, and calculated estimates. Show relevant source attribution, dates, units, formulas, and model limits in the generated file. Never invent provenance or present an illustrative model as a verified prediction; use precision justified by the data.
- Preserve context during exploration. Keep labels and scales stable when comparison requires it, show scale changes explicitly, and retain the baseline when useful. Update conditional language and conclusions as well as numbers when a threshold changes the result.

## Model state and interaction

- Keep independent inputs, named constants, and view state explicit. Validate input before calculation or submission, give adjustable values units and sensible bounds, and provide reset or clear only where it serves the task.
- Distinguish local drafts and hypothetical scenarios from service-backed records. Editing a field or slider must not silently perform a real-world action. Do not invoke services on every slider movement; use explicit refresh and action controls.
- Represent asynchronous operations with explicit idle, pending, succeeded, and failed states. Capture the submitted inputs, prevent duplicate mutations, and show failures without discarding the draft. If inputs change during a request, do not present the older result as belonging to the new inputs.
- The HTML file is durable, but its live page state is not. Do not claim drafts or records survive closing or replacing the page unless an inspected Host service contract provides persistence. HTML scripts cannot write Profile files or rely on browser storage.

For local calculators and reactive explanations, use Tangle's model-and-binding pattern without loading an external library: calculate derived results in one function and render dependent prose, graphics, labels, and accessible summaries from that result. Bind text outputs with `data-var` and `textContent`. Keep bindings scoped to the document root, initialize once, and recalculate on input. Use the same render function for reset and show an unavailable result for invalid inputs. This is an optional authoring convention, not an injected Ox API or a requirement for every app.

This minimal binding example uses an illustrative 50 calories per cookie, not nutritional advice. Apply the theme and layout rules below when composing the complete HTML file.

```html
<section id="cookie-example">
  <label>Cookies <input type="number" min="0" max="20" step="1" value="3" required></label>
  <p data-var="summary" aria-live="polite">Those cookies contain 150 calories.</p>
  <p>Illustrative assumption: 50 calories per cookie.</p>
  <button type="button">Reset</button>
</section>
<script>
(() => {
  const root = document.getElementById("cookie-example");
  const input = root?.querySelector("input");
  const reset = root?.querySelector("button");
  if (!root || !input || !reset) throw new Error("Missing cookie example controls");
  const baseline = { cookies: 3, caloriesPerCookie: 50 };
  const state = { ...baseline };
  function calculate({ cookies, caloriesPerCookie }) {
    return {
      summary: Number.isFinite(cookies)
        ? `Those cookies contain ${cookies * caloriesPerCookie} calories.`
        : "Enter a whole number of cookies from 0 to 20."
    };
  }
  function render() {
    const result = calculate(state);
    for (const output of root.querySelectorAll("[data-var]")) {
      output.textContent = result[output.dataset.var];
    }
  }
  input.addEventListener("input", () => {
    state.cookies = input.validity.valid ? input.valueAsNumber : null;
    render();
  });
  reset.addEventListener("click", () => {
    Object.assign(state, baseline);
    input.value = String(state.cookies);
    render();
  });
  render();
})();
</script>
```

## Design for iPhone and iPad

- HTML appears inline in Ox chat, with an option to expand it. Design the bounded inline card first: make its first screen useful at phone width, with the main content and primary control visible. Let the same content grow naturally when expanded; do not rely on expansion, hover, or a desktop-sized viewport to reveal the main result.
- Make the HTML feel like part of Ox. Default to its existing theme rather than inventing a dashboard skin, custom font, gradient, or decorative chrome. Follow a different style only when the user requests it.
- Use one readable column with equal outer-edge padding, normally 16 px. Favor a few large, legible elements over dense layouts. Keep the outer background transparent to blend into the Host surface; use tonal fills only where content needs grouping.
- Define root-scoped CSS variables for the Ox palette: `surface: #FFFDF7`, `surface-sunken: #FBE9C7`, `background: #FFF6E6`, `on-surface: #3A2410`, `on-surface-muted: #7A5A3A`, `primary: #FFA500`, `primary-pressed: #D87A0A`, and `error: #B8422E`. Reuse them throughout HTML and SVG rather than scattering color literals.
- Support dark appearance with `color-scheme: light dark` and `prefers-color-scheme: dark` overrides: `surface: #1C1C1E`, `surface-sunken: #2C2C2E`, `background: #0A0A0A`, `on-surface: #ECECEC`, `on-surface-muted: #9A9A9A`, `primary: #F5A030`, `primary-pressed: #C77410`, and `error: #E25A45`. Keep text contrast readable and large color fills subtle.
- Support widths from 320 px through iPad without horizontal page scrolling, clipped labels, fixed viewport heights, or fixed outer widths. Let controls wrap or stack with a media query.
- Use system body type (`-apple-system, system-ui, sans-serif`) around 17 px, rounded system headings and labels (`ui-rounded, system-ui, sans-serif`), and monospaced type only for code or numeric diagnostics. Make controls inherit typography; use no more than two type sizes per visible region.
- Use Ox's 4, 8, 12, 16, 24, and 32 px spacing scale, 12 px input radii, 18 px grouped-content radii, capsule buttons, and touch targets at least 44 px in both dimensions.
- Separate structure with spacing and tonal surfaces, not decorative borders or shadows. Reserve harvest gold for at most one primary action or active series per visible region; use `surface-sunken` for small recessed accents. Do not imitate the Host's navigation, composer, or approval controls inside the HTML page.

## Write and revise the file

Write one self-contained UTF-8 HTML fragment to a short lowercase `<name>.html` path in the conversation's working directory with `ox.fs.write`. Start with `<meta name="viewport" content="width=device-width, initial-scale=1">` and `<meta name="color-scheme" content="light dark">` so the browser uses phone-width layout and an appearance-aware page background. Put markup, `<style>`, and `<script>` in that file; omit `<!doctype>`, `<html>`, `<head>`, and `<body>`. Keep it below 200 KB. File creation and presentation are separate operations. Report the final Profile-relative path after writing.

HTML pages run under a restrictive content policy. Do not use browser network requests, remote subresources, external libraries, `<form>` submission, frames, file input, workers, object embeds, sensors, geolocation, camera, or microphone. Keep markup and scripts inline. Native `button`, `input`, and `select` controls may update local state or invoke Host services through the injected `ox.service` SDK.

Give the fragment one unique root ID. Scope CSS and DOM queries to that root. Put the script after its markup, verify every queried element exists, and make the primary interaction update both the interface and its accessible state. Do not depend on browser storage or ambient globals.

Read an existing HTML file before revising it, following `ox.fs.read` continuation offsets until complete. Edit or overwrite the same file when revising it. Messages refer to its current contents at that path; they do not retain historical bytes. Moving or renaming the file leaves old message references deleted, so present the file again at its new path. Use `ox.fs.copy` only when the user wants an independent file.

## Use Host services

The Host injects `window.ox.service` before HTML scripts run. Use inspected service action contracts, the same options objects, `purpose`, and synchronous `.help()` methods as in the agent VM. Only the service namespace is available; do not call `ox.fs`, `ox.web`, `ox.user`, or other VM namespaces from an HTML page.

An HTML page runs independently of its creating chat. It is an HTML app surface, not a full agent VM or a Local service implementation. Services resolve and initialize on demand. Do not call `attach`, `detach`, or `listAttached`; these methods are chat-only. Use `find` for discovery and `inspect` for action contracts. Always use a qualified `web:<domain>:<action>`, `ios:<app>:<action>`, or `mcp:<server>:<action>` name. Discovery and inspection report `attached: false` because an HTML page has no chat attachments.

Invoke a known action with `await ox.service.invoke({ name, input, purpose })`. Host authentication, Action policies, sign-in, verification, payment, and existing Always allow settings work as they do in chat. Do not implement a second approval form in HTML or claim an action succeeded before the promise resolves. Disabling a button while its operation is pending prevents accidental duplicate actions. Show loading, failure, and success states; never retry mutations automatically. Render returned text with `textContent`, not interpolated HTML.

Closing or replacing an HTML page cancels pending calls and releases its service resources. Keep interactive state in the page; do not depend on chat state or a Profile filesystem. Service-produced files are temporary and closing the page removes them.

Calls are serialized per HTML page, with at most 16 pending calls, 120 admissions per minute, 1 MiB request arguments, and an 8 MiB response. Cancellation is requested after 60 seconds of active execution; time waiting for page prompts and handoffs does not count. Cancellation cannot undo service requests already sent or dismiss operating-system permission alerts. Temporary outputs are limited to 32 files and 20 MiB. Surface limit errors instead of retrying in a loop.

## Use local media and maps

Reference sibling image, audio, or video file paths directly in `src`; never embed a host filesystem path. For a map, use:

```html
<ox-map latitude="…" longitude="…" radius="…" aria-label="…">
  <ox-marker latitude="…" longitude="…" label="…"></ox-marker>
</ox-map>
```

## Verify and finish

Use semantic headings, lists, tables, buttons, and labeled native controls. Keep the native tab order and retain focus while updating results. Pair color with labels, shapes, or line styles. Give SVG a concise accessible name and provide a text alternative for any relationship that cannot be understood from its labels. Announce changing results with a restrained `aria-live` region. Avoid animation unless it explains a state change; honor `prefers-reduced-motion` when motion is useful.

After writing, read the file back and verify its path, size, content-policy constraints, responsive structure, control labels, element IDs, and default state. Test the baseline and reset, both extremes of every adjustable value, invalid or missing inputs, and values on either side of any threshold that changes the conclusion. Check units, calculations, and agreement between labels, results, prose, and graphics; show an unavailable result rather than NaN, infinity, or stale data. For apps, exercise the primary workflow, navigation, draft preservation, pending and failed operations, duplicate-action prevention, and closing or reopening without assuming unsaved state persists. Verify service-backed changes through the actual returned or re-read state, not just a success label. Keep the chat response brief because the HTML file carries the result.
