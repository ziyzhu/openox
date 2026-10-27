import Foundation

nonisolated enum BrowserPageState {
    static func script(selector: String?) -> String {
        let data = try! JSONEncoder().encode(selector)
        let scope = String(decoding: data, as: UTF8.self)
        return """
        const selector = \(scope);
        const root = selector ? document.querySelector(selector) : document.body;
        let truncated = false;
        const text = value => {
          const normalized = String(value || '').replace(/\\s+/g, ' ').trim();
          if (normalized.length > 160) truncated = true;
          return normalized.slice(0, 160);
        };
        const attribute = (element, name) => {
          const value = element.getAttribute(name);
          if (value === null) return null;
          if (value.length > 256) truncated = true;
          return value.slice(0, 256);
        };
        const visible = element => {
          if (element.closest('[hidden],[inert],[aria-hidden="true"]')) return false;
          const style = getComputedStyle(element);
          return style.display !== 'none' && style.visibility !== 'hidden' && element.getClientRects().length > 0;
        };
        const collect = (query, limit, map) => {
          if (!root) return [];
          const matches = root.querySelectorAll(query);
          if (matches.length > 2000) truncated = true;
          const candidates = [...(root.matches(query) ? [root] : []), ...Array.from(matches).slice(0, 2000)];
          const result = [];
          for (const element of candidates) {
            if (!visible(element)) continue;
            if (result.length === limit) { truncated = true; break; }
            result.push(map(element));
          }
          return result;
        };
        const label = element => {
          const labelled = (element.getAttribute('aria-labelledby') || '').split(/\\s+/).filter(Boolean)
            .map(id => document.getElementById(id)?.textContent || '').join(' ');
          return text(labelled || element.getAttribute('aria-label') ||
            Array.from(element.labels || []).map(node => node.textContent).join(' ') ||
            (element.matches('button,a,[role="button"],[role="tab"]') ? element.textContent : '') ||
            element.getAttribute('placeholder') || element.getAttribute('title'));
        };
        const controls = collect('input,textarea,select,button,a[href],[role="button"],[role="combobox"],[role="checkbox"],[role="radio"],[role="tab"]', 40, element => {
          const type = element.getAttribute('type') || element.localName;
          const control = {
            id: attribute(element, 'id'),
            name: attribute(element, 'name'),
            role: element.getAttribute('role') || element.localName,
            label: label(element),
            type,
            disabled: element.matches(':disabled') || element.getAttribute('aria-disabled') === 'true',
            required: element.required === true || element.getAttribute('aria-required') === 'true',
            invalid: element.getAttribute('aria-invalid') === 'true',
          };
          if (element.matches('input[type="checkbox"],input[type="radio"]')) control.checked = element.checked;
          else if (element.hasAttribute('aria-checked')) control.checked = element.getAttribute('aria-checked') === 'true';
          if (element.hasAttribute('aria-expanded')) control.expanded = element.getAttribute('aria-expanded') === 'true';
          if (element.hasAttribute('aria-selected')) control.selected = element.getAttribute('aria-selected') === 'true';
          if (element.matches('input:not([type="password"]):not([type="hidden"]),textarea,select')) control.hasValue = Boolean(element.value);
          return control;
        });
        return {
          scope: selector,
          scopeFound: Boolean(root),
          readyState: document.readyState,
          busy: Boolean(root && (root.closest('[aria-busy="true"]') || root.querySelector('[aria-busy="true"]'))),
          headings: collect('h1,h2,h3,[role="heading"]', 10, element => text(element.textContent)),
          dialogs: collect('dialog[open],[role="dialog"],[role="alertdialog"]', 5, element => ({label: label(element)})),
          messages: collect('[role="alert"],[role="status"],[aria-live="polite"],[aria-live="assertive"]', 10, element => text(element.textContent)),
          controls,
          truncated,
          coverage: 'Visible light-DOM elements in the selected scope; frames and shadow roots are not inspected. Loading and application readiness are not inferred.',
        };
        """
    }
}
