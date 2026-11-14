import { clear, count, counter, json, page, redirect, Sessions, setCookie, accounts, webService, type Site } from "./shared.ts";

const consumer = "ox-popup.localhost";
const provider = "ox-popup-idp.localhost";
const counters = counter();
const sessions = new Sessions("popup_session");
export const popup: Site = {
  name: "popup", hosts: [consumer, provider], counters,
  reset() { clear(counters); sessions.clear(); },
  services: origin => [
    { manifest: webService(consumer, "Popup Consumer Fixture", origin(consumer), [], {
      loginPath: "/", extra: { auth: [{ type: "provider", service: `web:${provider}` }] },
    }), actions: "popup.actions.js" },
    { manifest: webService(provider, "Popup Provider Fixture", origin(provider), [], { loginPath: "/authorize" }), actions: "popup-idp.actions.js" },
  ],
  handle(request, url, origin) {
    if (url.hostname === provider) {
      if (url.pathname === "/authorize") {
        count(counters, "authorization");
        return page("Popup provider", `<h1>Popup provider</h1><a id="complete" href="${origin(consumer)}/callback">Complete sign-in</a>`);
      }
      return json([]);
    }
    if (url.pathname === "/callback") {
      count(counters, "callback");
      return redirect("/", { "set-cookie": setCookie("popup_session", sessions.create(accounts[0]!)) });
    }
    if (url.pathname === "/sessions") {
      const account = sessions.account(request);
      return json(account ? [{ id: account.id, label: account.label, url: `${origin(consumer)}/` }] : []);
    }
    return page("Popup consumer", `<h1>Popup consumer</h1><a id="sign-in" target="_blank" href="${origin(provider)}/authorize">Sign in in a new window</a>`);
  },
};
