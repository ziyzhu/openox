# Visualize

Choose a Canvas when HTML lets the reader understand a relationship, question an assumption, or explore a scenario better than static Markdown. A Canvas can be a reactive explanation, not just a chart or small app: prose, controls, and graphics can share one model. Keep simple answers, lists, and small tables in chat. Ordinary Markdown notes and artifact file operations use `ox.fs` and `ox.artifact` directly.

Canvas appears inline in Ox chat on iPhone and iPad, with an option to expand it. Design the inline mobile view first: make its first screen useful at phone width, keep controls touch-friendly, and let the same content grow naturally when expanded. Do not rely on expansion, hover, or a desktop-sized viewport to reveal the main result.

Generate HTML using Ox's existing theme by default, not an unrelated visual identity. Reuse its warm cream surfaces, brown text, selective harvest-gold accents, system typography, spacing, and soft shapes. Use a different visual style only when the user requests it.

Read `guidance/visualize/references/canvas.md` before creating or revising a Canvas. It defines the Ox theme palette, supported HTML format, responsive and accessible design, local media and maps, and the Canvas service SDK.

Build one focused explanation around the user's question. Make the initial state readable and useful without interaction, then let the reader change meaningful assumptions and see the consequences update in the prose and graphics together. Keep controls near the claims they affect; expose sources, calculations, and model limits so the reader can challenge the conclusion, not merely operate a widget.

Use Tangle's model-and-binding pattern without loading an external library: keep independent inputs and named constants in one local state object, calculate derived results in one function, and render all dependent prose and graphics from that result. Bind text outputs with `data-var` and `textContent`; use labeled native inputs rather than drag-only numbers. Keep bindings scoped to the artifact root, initialize once, and recalculate on input. Use the same render function for reset and show an unavailable result for invalid inputs. This is an authoring convention, not an injected Ox API.

This minimal binding example uses an illustrative 50 calories per cookie, not nutritional advice. Apply the Ox theme and layout rules from the Canvas reference when composing the complete artifact; add graphics only when they explain another aspect of the same result.

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

Use local JavaScript for scenario exploration; changing an assumption must not silently invoke a service or perform a real-world action. Use inspected service contracts when the explanation needs live data or explicit actions. Preserve Host authentication and Action policies, and show pending, successful, and failed states accurately.

Read an existing Canvas before revising it. Edit the same artifact path when a later message changes that Canvas; use a new path for a distinct visual. Write or edit its self-contained HTML under `artifacts/`; successful writes and edits display it automatically. Verify the content constraints, layout, labels, and interaction states, then keep the chat response brief.
