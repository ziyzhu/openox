# Embedded page automation

Use this small Playwright-style DOM subset for page-owned service actions. It is not Playwright: events are synthetic, accessible-name/role matching is simplified, and selectors do not pierce shadow roots or frames. Prefer observed structured requests when DOM interaction is unnecessary. Native input, keyboard automation, browser navigation, network interception, and full Playwright compatibility are not provided.

Write service code with `ox.fs.write({ purpose, path, content })`. Text writes to web `actions.js` automatically embed a self-contained `createEmbeddedAutomation` function. Create `page` inside the installer. DOM lookup happens during handler execution.

```js
window.ox.install(({ action }) => {
  const page = createEmbeddedAutomation({ timeout: 5000 });
  action("search", {
    async invoke(input) {
      await page.getByRole("textbox", { name: "Search", exact: true }).fill(input.query);
      await page.getByRole("button", { name: "Search", exact: true }).click();
      await page.getByTestId("results").waitFor({ state: "visible" });
      return { items: await page.locator("[data-result]").allTextContents(), nextCursor: null };
    },
  });
});
```

Reads return the full source. Use targeted `ox.fs.edit` for service or helper changes. Full writes preserve a leading `createEmbeddedAutomation` declaration in the supplied source. To embed the current implementation from `references/helpers.js`, supply the service code starting at the installer. Do not import or fetch that file at runtime. Validate the installer with `ox.service.validate` and invoke affected actions to verify behavior after changes.

| Construction | Contract |
| --- | --- |
| `page.locator(css)` | Light-DOM CSS query. |
| `page.getByRole(role, { name?, exact?, includeHidden? })` | Common implicit roles plus explicit role; hidden elements excluded by default. |
| `page.getByLabel(text, { exact? })` | Labels, aria-label, aria-labelledby on controls. |
| `page.getByText(text, { exact? })` | Smallest matching text-bearing elements. |
| `page.getByPlaceholder(text, { exact? })` | Placeholder attribute. |
| `page.getByTestId(value)` | Exact data-testid value. |
| Locator query chaining | Same constructors, scoped to descendants. |
| `locator.filter({ hasText })` | Normalized text substring. |
| `locator.nth(index)`, `.first()`, `.last()` | Explicit positional narrowing; use observed stable ordering. |

String matching normalizes whitespace; substring matching is case-insensitive and exact matching is case-sensitive. Regular expressions are not supported. Role/name matching is not a complete accessibility implementation. Do not assume parity with Playwright selectors.

| Operation | Contract |
| --- | --- |
| `click({ timeout? })` | Wait for one visible enabled target; reject an obscured target; dispatch once. |
| `fill(string, { timeout? })` | Supported text-like input, textarea, or contenteditable; native value setter and input/change events. |
| `check`, `uncheck`, `setChecked(boolean, { timeout? })` | Native checkbox/radio, dispatch only when needed, verify checked state. |
| `selectOption(stringOrStrings, { timeout? })` | Native select values; reject missing/disabled options before dispatch. |
| `waitFor({ state?, timeout? })` | attached, detached, visible (default), hidden. |
| `innerText`, `textContent`, `getAttribute(name, { timeout? })` | Wait for exactly one attached element; return the requested value. |
| `count`, `isVisible`, `allTextContents` | Immediate snapshots, not readiness or absence proofs. |

All single-target operations reject ambiguous matches. Locators resolve afresh rather than retaining elements. Timeouts are wall-clock bounded, default 5000 ms, maximum 30000 ms; zero means one immediate check. Waiting happens before dispatch only. The helper does not retry a dispatched effect or establish business success. Inspect an action-specific outcome after interaction and report uncertain effects without replay. Full-document navigation destroys this implementation's execution context; preserve the page and inspect its fresh document through the normal Browser/service flow. Keep external mutations inside approval-gated service actions and never expose secret values through locator reads or logs.
