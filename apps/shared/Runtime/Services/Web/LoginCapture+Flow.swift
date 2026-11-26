import Foundation

extension LoginCapture {
    static let flowIntents = [
        "sign in", "log in", "login", "next", "continue", "submit", "use another account",
        "sign in with google", "continue with google", "sign in with apple", "continue with apple",
        "sign in with microsoft", "continue with microsoft", "sign in with github", "continue with github",
        "use password", "sign in with password", "use a passkey", "sign in with a passkey"
    ]

    static var flowScript: String {
        let intents = JSONValue.array(flowIntents.map(JSONValue.string)).jsonString()
        return #"""
        (() => {
          if (window.__oxLoginFlow) return;
          const intents = new Set(\#(intents));
          const routes = new Set(["login", "log-in", "signin", "sign-in", "auth", "authenticate", "authentication", "accounts", "account", "oauth", "oauth2", "authorize", "identifier", "password", "challenge", "verify", "verification", "consent", "sso", "v1", "v2", "v3"]);
          const visible = element => {
            if (!(element instanceof Element) || element.closest('[hidden],[aria-hidden="true"]')) return false;
            const style = getComputedStyle(element);
            return style.display !== "none" && style.visibility !== "hidden" && !element.disabled;
          };
          const selector = element => {
            const parts = [];
            for (let node = element; node instanceof Element; node = node.parentElement) {
              if (parts.length >= 20) return null;
              const index = node.parentElement ? [...node.parentElement.children].indexOf(node) + 1 : [...node.getRootNode().children].indexOf(node) + 1;
              parts.unshift(`*:nth-child(${index})`);
            }
            const local = parts.join(" > ");
            const root = element.getRootNode();
            const matches = root.querySelectorAll(local);
            if (matches.length !== 1 || matches[0] !== element) return null;
            if (root instanceof ShadowRoot) {
              const host = selector(root.host);
              return host ? `${host} >>> ${local}` : null;
            }
            return local.length <= 1024 ? local : null;
          };
          const describe = element => {
            if (!visible(element)) return null;
            const path = selector(element);
            if (!path) return null;
            const autocomplete = (element.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/);
            let kind;
            if (element instanceof HTMLInputElement) {
              if (element.type === "hidden") return null;
              kind = autocomplete.includes("one-time-code") ? "code" : element.type === "password" ? "password" : autocomplete.includes("username") || autocomplete.includes("email") || element.type === "email" ? "username" : ["submit", "button"].includes(element.type) ? "button" : "text";
            } else if (element instanceof HTMLFormElement) kind = "form";
            else if (element instanceof HTMLSelectElement) kind = "select";
            else kind = element.tagName === "A" ? "link" : "button";
            const control = { selector: path, kind };
            if (kind === "button" || kind === "link") {
              const text = (element.textContent || "").trim().toLowerCase().replace(/\s+/g, " ");
              if (intents.has(text)) control.intent = text;
            }
            return control;
          };
          const query = 'input:not([type="hidden"]),button,a,[role="button"],select';
          const controls = root => {
            const found = [];
            for (const element of root.querySelectorAll(query)) {
              const control = describe(element);
              if (control) found.push(control);
              if (found.length >= 16) break;
            }
            return found;
          };
          let count = 0;
          let last = "";
          const record = (event, element) => {
            if (count >= 65) { stop(); return; }
            const root = element?.getRootNode() || document;
            const step = {
              event,
              route: "/" + location.pathname.split("/").filter(Boolean).slice(0, 12).map(part => routes.has(part.toLowerCase()) ? part.toLowerCase() : ":segment").join("/"),
              controls: controls(root)
            };
            if (element) {
              const target = describe(element);
              if (target) step.target = target;
            }
            const encoded = JSON.stringify(step);
            if (encoded === last) return;
            last = encoded;
            try { window.webkit.messageHandlers.oxLoginFlow.postMessage(step); count++; } catch { stop(); }
          };
          const interact = event => {
            const first = event.composedPath?.()[0] ?? event.target;
            const target = first instanceof Element ? first.closest(event.type === "submit" ? "form" : query) : null;
            if (target) record(event.type === "focusin" ? "focus" : event.type, target);
          };
          const ready = () => record("page");
          const stop = () => {
            ["click", "focusin", "submit"].forEach(type => document.removeEventListener(type, interact, true));
            document.removeEventListener("DOMContentLoaded", ready);
            window.removeEventListener("pageshow", ready);
            delete window.__oxLoginFlow;
          };
          window.__oxLoginFlow = { stop };
          ["click", "focusin", "submit"].forEach(type => document.addEventListener(type, interact, true));
          document.addEventListener("DOMContentLoaded", ready, { once: true });
          window.addEventListener("pageshow", ready);
          if (document.readyState !== "loading") ready();
        })();
        """#
    }
}
