# Reactive Binding Example

Optional pattern for local calculators and explanations, not an injected Ox API. Calculate derived results in one function, then render dependent prose, graphics, labels, and accessible summaries from it. Bind text with `data-var` and `textContent`, scope to one root, initialize once, recalculate on input, and use the same renderer for reset. Invalid inputs yield unavailable results.

This example uses an illustrative 50 calories per cookie, not nutritional advice. Apply the layout/theme rules in `references/html.md` when composing a complete file; do not load an external binding library.

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
