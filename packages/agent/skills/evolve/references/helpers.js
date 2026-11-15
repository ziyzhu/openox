const cookie = name => {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = document.cookie.match(new RegExp(`(?:^|;\\s*)${escaped}=([^;]*)`));
  if (!match) return null;
  try {
    return decodeURIComponent(match[1]);
  } catch {
    return match[1];
  }
};

const cleanText = value => String(value ?? "").replace(/\s+/g, " ").trim();

const pageCursor = (value, firstPage) =>
  Math.max(firstPage, Number.parseInt(value ?? String(firstPage), 10) || firstPage);

const retryFetch = async (input, init, options) => {
  const retries = options?.retries ?? 3;
  const delay = options?.delay ?? 400;
  const factor = options?.factor ?? 2;
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await window.fetch(input, init);
      const retryable = response.status === 408 || response.status === 429
        || (response.status >= 500 && response.status <= 599);
      if (response.ok || !retryable || attempt >= retries) return response;
      console.log(`retryFetch: status ${response.status}, attempt ${attempt + 1}/${retries}`);
    } catch (error) {
      const message = String(error?.message ?? "");
      const retryable = message.includes("Load failed")
        || message.includes("NetworkError")
        || message.includes("Failed to fetch");
      if (!retryable || attempt >= retries) throw error;
      console.log(`retryFetch: network ${JSON.stringify(message)}, attempt ${attempt + 1}/${retries}`);
    }
    await new Promise(resolve => setTimeout(resolve, delay * Math.pow(factor, attempt)));
  }
};

const createFetchCapture = target => {
  const registrations = new Set();
  const recent = [];
  const patternMatches = (pattern, value) => {
    pattern.lastIndex = 0;
    const matched = pattern.test(value);
    pattern.lastIndex = 0;
    return matched;
  };
  const matching = url => [...registrations].filter(registration => patternMatches(registration.pattern, url));
  const settle = (matched, result) => {
    for (const registration of matched) {
      if (!registrations.delete(registration)) continue;
      clearTimeout(registration.timeout);
      if (result.error) registration.reject(result.error);
      else registration.resolve(result.value);
    }
  };
  const canReplay = url => {
    try {
      const page = new URL(target.location.href);
      const request = new URL(url, page);
      return request.hostname === page.hostname && /^\/(?:api|web_api)\//.test(request.pathname);
    } catch {
      return false;
    }
  };
  const capture = (url, read) => {
    const matched = matching(url);
    const replayable = canReplay(url);
    if (matched.length === 0 && !replayable) return;
    const value = read();
    if (replayable) {
      const entry = { url, value };
      recent.push(entry);
      while (recent.length > 32) recent.shift();
      void value.catch(() => {
        const index = recent.indexOf(entry);
        if (index >= 0) recent.splice(index, 1);
      });
    }
    if (matched.length === 0) return;
    void value.then(
      result => settle(matched, { value: result }),
      error => settle(matched, {
        error: new Error(`captured response returned invalid JSON: ${String(error?.message ?? error)}`),
      }),
    );
  };

  const waitForCapture = (pattern, options) => {
    if (options?.replayLatest) {
      for (let index = recent.length - 1; index >= 0; index--) {
        if (patternMatches(pattern, recent[index].url)) return recent[index].value;
      }
    }
    return new Promise((resolve, reject) => {
      const timeoutMs = options?.timeoutMs ?? 10000;
      const registration = { pattern, resolve, reject };
      registration.timeout = setTimeout(() => {
        if (!registrations.delete(registration)) return;
        reject(new Error(`fetch capture timed out after ${timeoutMs}ms for ${pattern}`));
      }, timeoutMs);
      registrations.add(registration);
    });
  };

  if (typeof target.fetch === "function") {
    const originalFetch = target.fetch.bind(target);
    target.fetch = (input, init) => originalFetch(input, init).then(response => {
      const url = input instanceof Request ? input.url : String(input);
      capture(url, () => response.clone().json());
      return response;
    });
  }

  const XHR = target.XMLHttpRequest;
  if (!XHR) return waitForCapture;
  const urls = new WeakMap();
  const originalOpen = XHR.prototype.open;
  const originalSend = XHR.prototype.send;
  XHR.prototype.open = function (...args) {
    urls.set(this, String(args[1] ?? ""));
    return originalOpen.apply(this, args);
  };
  XHR.prototype.send = function (...args) {
    this.addEventListener("loadend", () => {
      const url = urls.get(this) ?? this.responseURL;
      capture(url, async () => this.responseType === "json" ? this.response : JSON.parse(this.responseText));
    }, { once: true });
    return originalSend.apply(this, args);
  };
  return waitForCapture;
};

const usable = element => {
  if (!element || element.disabled || element.readOnly || element.type === "hidden") return false;
  if (element.closest("[hidden], [aria-hidden='true'], [inert]")) return false;
  const style = getComputedStyle(element);
  return style.display !== "none" && style.visibility !== "hidden";
};

const waitForStep = async (detectors, timeout = 15000) => {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    for (const [kind, detect] of Object.entries(detectors)) {
      const match = detect();
      if (match) return { kind, match };
    }
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  return { kind: "unknown", match: null };
};

const typeInto = (field, value) => {
  field.focus();
  field.select?.();
  if (!document.execCommand("insertText", false, value) || field.value !== value) {
    Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value").set.call(field, value);
    field.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: value }));
  }
  field.dispatchEvent(new Event("change", { bubbles: true }));
};

const pageError = (root = document) => [...root.querySelectorAll("[role='alert'], [aria-live='assertive'], [aria-live='polite']")]
  .filter(usable)
  .map(element => cleanText(element.innerText))
  .filter(Boolean)
  .join(" | ")
  .slice(0, 200);

function createEmbeddedAutomation({ timeout = 5000 } = {}) {
  const normalize = value => String(value ?? "").replace(/\s+/g, " ").trim();
  const matches = (actual, expected, exact = false) => exact
    ? normalize(actual) === normalize(expected)
    : normalize(actual).toLowerCase().includes(normalize(expected).toLowerCase());
  const visible = element => {
    if (!element.isConnected || element.closest('[hidden], [inert], [aria-hidden="true"]')) return false;
    for (let node = element; node?.nodeType === 1; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") return false;
    }
    return element.getClientRects().length > 0;
  };
  const disabled = element => element.matches(":disabled") || !!element.closest('[aria-disabled="true"], [inert]');
  const label = element => {
    const ids = element.getAttribute("aria-labelledby");
    if (ids) {
      const text = normalize(ids.split(/\s+/).map(id => element.ownerDocument.getElementById(id)?.textContent ?? "").join(" "));
      if (text) return text;
    }
    if (element.hasAttribute("aria-label")) return normalize(element.getAttribute("aria-label"));
    if (element.labels?.length) return normalize(Array.from(element.labels, item => item.textContent).join(" "));
    if (element.tagName === "IMG") return normalize(element.getAttribute("alt"));
    if (element.tagName === "INPUT" && ["submit", "reset", "button"].includes(element.type)) return normalize(element.value);
    return normalize(element.getAttribute("title") || (["INPUT", "TEXTAREA", "SELECT"].includes(element.tagName) ? "" : element.textContent));
  };
  const role = element => {
    const explicit = element.getAttribute("role")?.trim().split(/\s+/)[0];
    if (explicit) return explicit;
    const tag = element.tagName;
    if (tag === "INPUT") {
      const type = element.type;
      if (["button", "submit", "reset", "image"].includes(type)) return "button";
      if (["checkbox", "radio"].includes(type)) return type;
      if (type === "range") return "slider";
      if (type === "number") return "spinbutton";
      if (type === "search") return "searchbox";
      if (["text", "email", "tel", "url"].includes(type)) return "textbox";
      return "";
    }
    if (tag === "A") return element.hasAttribute("href") ? "link" : "";
    if (tag === "SELECT") return element.multiple || element.size > 1 ? "listbox" : "combobox";
    if (/^H[1-6]$/.test(tag)) return "heading";
    return ({ BUTTON: "button", TEXTAREA: "textbox", OPTION: "option", IMG: "img", UL: "list", OL: "list", LI: "listitem", TABLE: "table", TR: "row", TD: "cell", TH: "columnheader", DIALOG: "dialog", MAIN: "main", NAV: "navigation" })[tag] ?? "";
  };
  const duration = value => {
    const ms = value ?? timeout;
    if (!Number.isFinite(ms) || ms < 0 || ms > 30000) throw new Error("Automation timeout must be between 0 and 30000 ms");
    return ms;
  };
  duration(timeout);
  const pause = () => new Promise(resolve => setTimeout(resolve, 25));
  const locator = (resolve, description) => {
    const unique = () => {
      const elements = resolve();
      if (elements.length > 1) throw new Error(`Strict locator matched ${elements.length} elements: ${description}`);
      return elements[0];
    };
    const wait = async (predicate, options = {}) => {
      const deadline = Date.now() + duration(options.timeout);
      for (;;) {
        const element = unique();
        if (predicate(element)) return element;
        if (Date.now() >= deadline) throw new Error(`Locator condition timed out: ${description}`);
        await pause();
      }
    };
    const actionable = options => wait(element => element && visible(element) && !disabled(element), options);
    const clickElement = element => {
      element.scrollIntoView({ block: "center", inline: "center" });
      const rect = element.getBoundingClientRect();
      const hit = element.ownerDocument.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
      if (!hit || hit !== element && !element.contains(hit)) throw new Error(`Locator is obscured: ${description}`);
      if (!element.isConnected || disabled(element)) throw new Error(`Locator became unavailable: ${description}`);
      element.click();
    };
    const api = {
      ...queries(() => resolve()),
      filter({ hasText }) {
        if (typeof hasText !== "string") throw new Error("filter requires a string hasText");
        return locator(() => resolve().filter(element => matches(element.textContent, hasText)), `${description}.filter`);
      },
      nth(index) {
        if (!Number.isSafeInteger(index) || index < 0) throw new Error("nth requires a nonnegative integer");
        return locator(() => resolve().slice(index, index + 1), `${description}.nth(${index})`);
      },
      first() { return api.nth(0); },
      last() { return locator(() => resolve().slice(-1), `${description}.last()`); },
      async count() { return resolve().length; },
      async isVisible() { const element = unique(); return !!element && visible(element); },
      async waitFor({ state = "visible", ...options } = {}) {
        if (!["attached", "detached", "visible", "hidden"].includes(state)) throw new Error("Unsupported locator state");
        await wait(element => state === "attached" ? !!element : state === "detached" ? !element : state === "visible" ? !!element && visible(element) : !element || !visible(element), options);
      },
      async innerText(options) { return (await wait(element => !!element, options)).innerText; },
      async textContent(options) { return (await wait(element => !!element, options)).textContent; },
      async getAttribute(name, options) { return (await wait(element => !!element, options)).getAttribute(name); },
      async allTextContents() { return resolve().map(element => element.textContent ?? ""); },
      async click(options) { clickElement(await actionable(options)); },
      async fill(value, options) {
        if (typeof value !== "string") throw new Error("fill requires a string");
        const element = await actionable(options);
        if (element.readOnly) throw new Error(`Locator is read-only: ${description}`);
        if (element.tagName === "INPUT" && !["text", "email", "password", "search", "tel", "url", "number"].includes(element.type)) throw new Error("Unsupported input type for fill");
        const view = element.ownerDocument.defaultView;
        const prototype = element.tagName === "INPUT" ? view.HTMLInputElement.prototype : element.tagName === "TEXTAREA" ? view.HTMLTextAreaElement.prototype : null;
        element.focus();
        if (prototype) Object.getOwnPropertyDescriptor(prototype, "value").set.call(element, value);
        else if (element.isContentEditable) element.textContent = value;
        else throw new Error("fill requires an input, textarea, or contenteditable element");
        element.dispatchEvent(new view.Event("input", { bubbles: true }));
        element.dispatchEvent(new view.Event("change", { bubbles: true }));
      },
      async check(options) { await api.setChecked(true, options); },
      async uncheck(options) { await api.setChecked(false, options); },
      async setChecked(checked, options) {
        if (typeof checked !== "boolean") throw new Error("setChecked requires a boolean");
        const element = await actionable(options);
        if (element.tagName !== "INPUT" || !["checkbox", "radio"].includes(element.type)) throw new Error("setChecked requires a checkbox or radio input");
        if (element.checked === checked) return;
        clickElement(element);
        if (element.checked !== checked) throw new Error("Checked state unverified after dispatch; inspect before retrying");
      },
      async selectOption(value, options) {
        const values = Array.isArray(value) ? value : [value];
        if (values.some(item => typeof item !== "string")) throw new Error("selectOption accepts string values only");
        const element = await actionable(options);
        if (element.tagName !== "SELECT" || !element.multiple && values.length !== 1) throw new Error("Invalid selectOption target or values");
        const selected = Array.from(element.options).filter(option => values.includes(option.value));
        if (values.some(value => !selected.some(option => option.value === value)) || selected.some(option => option.disabled || option.parentElement?.disabled)) throw new Error("Select option is missing or disabled");
        for (const option of element.options) option.selected = values.includes(option.value);
        const view = element.ownerDocument.defaultView;
        element.dispatchEvent(new view.Event("input", { bubbles: true }));
        element.dispatchEvent(new view.Event("change", { bubbles: true }));
        return selected.map(option => option.value);
      },
    };
    return api;
  };
  function queries(roots) {
    const find = predicate => [...new Set(roots().flatMap(root => Array.from(root.querySelectorAll("*"))))].filter(predicate);
    return {
      locator(selector) { return locator(() => [...new Set(roots().flatMap(root => Array.from(root.querySelectorAll(selector))))], "css locator"); },
      getByRole(expected, { name, exact = false, includeHidden = false } = {}) {
        return locator(() => find(element => role(element) === expected && (includeHidden || visible(element)) && (name === undefined || matches(label(element), name, exact))), `role=${expected}`);
      },
      getByLabel(text, { exact = false } = {}) {
        return locator(() => find(element => element.matches("input, textarea, select, button, [contenteditable], [aria-label], [aria-labelledby]") && matches(label(element), text, exact)), "label locator");
      },
      getByText(text, { exact = false } = {}) {
        return locator(() => find(element => !element.matches("script, style, head, title") && matches(element.textContent, text, exact)
          && !Array.from(element.children).some(child => matches(child.textContent, text, exact))), "text locator");
      },
      getByPlaceholder(text, { exact = false } = {}) {
        return locator(() => find(element => element.hasAttribute("placeholder") && matches(element.getAttribute("placeholder"), text, exact)), "placeholder locator");
      },
      getByTestId(value) { return locator(() => find(element => element.getAttribute("data-testid") === value), "test id locator"); },
    };
  }
  return queries(() => [document]);
}
