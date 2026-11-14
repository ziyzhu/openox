const PROVIDER = "web:ox-govid.localhost";

window.ox.install(({ action }) => {
  action("listSessions", {
    async invoke() {
      const { account } = await fetchJSON("/api/session");
      return account ? [{ id: account.id, label: account.label, url: `${location.origin}/` }] : [];
    },
  });

  action("login", {
    async invoke(input = {}) {
      const step = await waitForStep({
        signedIn: () => document.querySelector("#me"),
        entry: () => document.querySelector("#sign-in-provider"),
      });
      if (step.kind === "unknown") throw new Error("Gov Account sign-in controls did not appear");
      if (step.kind === "entry" && input.auth?.type === "provider" && input.auth.service === PROVIDER) step.match.click();
      return null;
    },
  });

  action("getCases", {
    async invoke() {
      return fetchJSON("/api/cases");
    },
  });
});
