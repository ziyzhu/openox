window.ox.install(({ action }) => {
  const SERVICE = "web:accounts.google.com";
  const cleanText = value => String(value ?? "").replace(/\s+/g, " ").trim();
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
  const find = selector => [...document.querySelectorAll(selector)].find(usable) ?? null;
  const displayed = element => {
    if (!usable(element)) return false;
    for (let node = element.parentElement; node; node = node.parentElement) {
      if (!usable(node)) return false;
    }
    return true;
  };
  const detectStep = () => {
    const path = location.pathname;
    const main = document.querySelector('main');
    if (!main || !usable(main)) return null;
    if (/\/signin\/challenge\/(?!pwd(?:\/|$))/.test(path) || /\/signin\/(?:challenge|consent|approval)/.test(path) && !path.endsWith('/pwd')) return { kind: 'challenge', match: main };
    if (/\/signin\/accountchooser(?:\/|$)/.test(path)) {
      const rows = [...document.querySelectorAll('[data-identifier][role="link"]')].filter(displayed);
      if (rows.length) return { kind: 'chooser', match: rows };
    }
    if (/\/signin\/identifier(?:\/|$)/.test(path)) {
      const field = [...document.querySelectorAll('input#identifierId[autocomplete~="username"]')].find(displayed);
      if (field) return { kind: 'identifier', match: field };
    }
    if (/\/signin\/challenge\/pwd(?:\/|$)/.test(path)) {
      const captcha = [...document.querySelectorAll('input[name="ca"]')].find(displayed);
      if (captcha) return { kind: 'challenge', match: captcha };
      const field = [...document.querySelectorAll('input[name="Passwd"][autocomplete~="current-password"]')].find(displayed);
      if (field) return { kind: 'password', match: field };
    }
    return null;
  };
  const decode = text => {
    const trimmed = text.trim();
    if (trimmed.startsWith("[")) return trimmed;
    const match = trimmed.match(/postMessage\('((?:\\.|[^'])*)'/);
    if (!match) throw new Error("Google account list response was not recognized");
    return match[1]
      .replace(/\\x([0-9a-f]{2})/gi, (_, value) => String.fromCharCode(Number.parseInt(value, 16)))
      .replace(/\\u([0-9a-f]{4})/gi, (_, value) => String.fromCharCode(Number.parseInt(value, 16)))
      .replace(/\\\//g, "/")
      .replace(/\\'/g, "'")
      .replace(/\\\\/g, "\\");
  };
  const accounts = async () => {
    const response = await fetch("/ListAccounts?gpsia=1&source=ogb&mo=1&origin=https%3A%2F%2Faccounts.google.com", { credentials: "include", cache: "no-store" });
    if (!response.ok) throw new Error('Google account list: HTTP ' + response.status);
    const payload = JSON.parse(decode(await response.text()));
    if (!Array.isArray(payload) || !Array.isArray(payload[1])) throw new Error("Google account list response was invalid");
    return payload[1]
      .filter(entry => Array.isArray(entry) && typeof entry[3] === "string" && entry[3].includes("@")
        && (entry[9] === 1 || entry[9] === true) && entry[14] !== 1 && entry[14] !== true)
      .map(entry => String(entry[3]));
  };
  action("listSessions", {
    async invoke() {
      return (await accounts()).map(email => ({
        id: email,
        label: email,
        url: 'https://accounts.google.com/AccountChooser?Email=' + encodeURIComponent(email),
      }));
    },
  });
  action("login", {
    async invoke(input, context) {
      const current = await waitForStep({
        chooser: () => { const step = detectStep(); return step?.kind === 'chooser' ? step.match : null; },
        identifier: () => { const step = detectStep(); return step?.kind === 'identifier' ? step.match : null; },
        password: () => { const step = detectStep(); return step?.kind === 'password' ? step.match : null; },
        challenge: () => { const step = detectStep(); return step?.kind === 'challenge' ? step.match : null; },
      });
      if (current.kind === 'unknown') throw new Error('Google sign-in controls did not appear; page may be loading or unrelated');
      if (!input.account || input.account.serviceID !== SERVICE || current.kind === 'challenge') return null;
      const active = (current.kind === 'chooser' ? current.match[0] : current.match).closest('c-wiz') ?? document.querySelector('main') ?? document;
      const error = pageError(active);
      if (error) throw new Error('Google sign-in reported: ' + error);
      const { username, password } = await context.secret(input.account);
      if (current.kind === 'chooser') {
        const choice = current.match.find(element => element.getAttribute('data-identifier')?.toLowerCase() === username.toLowerCase());
        if (!choice) throw new Error('The saved Google account is not in the account chooser');
        choice.click();
        return null;
      }
      if (current.kind === 'identifier') {
        const next = [...document.querySelectorAll('#identifierNext button')].find(displayed);
        if (!next || !displayed(next)) throw new Error('Google username Next control was not usable');
        typeInto(current.match, username);
        next.click();
        return null;
      }
      const next = [...document.querySelectorAll('#passwordNext button')].find(displayed);
      if (!next || !displayed(next)) throw new Error('Google password Next control was not usable');
      typeInto(current.match, password);
      next.click();
      return null;
    },
  });
});
