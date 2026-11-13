window.ox.install(({ action }) => {
  action("listSessions", {
    async invoke() {
      const { account } = await fetchJSON("/api/session");
      return account ? [{ id: account.id, label: account.label, url: `${location.origin}/` }] : [];
    },
  });

  action("login", {
    async invoke() {
      const step = await waitForStep({
        signedIn: () => document.querySelector("#me"),
        entry: () => document.querySelector("#sign-in"),
      });
      if (step.kind === "unknown") throw new Error("Card sign-in controls did not appear");
      if (step.kind === "signedIn") return null;
      step.match.click();
      const frame = await waitForStep({ widget: () => usable(document.querySelector("iframe[name='idp-auth-widget']")) && document.querySelector("iframe[name='idp-auth-widget']") });
      if (frame.kind === "unknown") throw new Error("Card sign-in preparation failed: Fixture ID frame did not become available");
      return null;
    },
  });

  action("getBalance", { async invoke() { return fetchJSON("/api/balance"); } });
});
