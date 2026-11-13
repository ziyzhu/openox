const SERVICE = "web:ox-idp.localhost";

window.ox.install(({ action }) => {
  action("listSessions", {
    async invoke() {
      const { account } = await fetchJSON("/api/session");
      return account ? [{ id: account.id, label: account.label, url: `${location.origin}/signin` }] : [];
    },
  });

  action("login", {
    async invoke(input = {}, context) {
      const step = await waitForStep({
        signedIn: () => document.querySelector("#signed-in"),
        credentials: () => document.querySelector("form[action='/signin'], form#credentials"),
      });
      if (step.kind === "unknown") throw new Error("Fixture ID sign-in controls did not appear");
      if (step.kind === "signedIn") return null;
      if (!input.account || input.account.serviceID !== SERVICE) return null;
      const credentials = await context.secret(input.account);
      typeInto(step.match.querySelector("input[autocomplete='username']"), credentials.username);
      typeInto(step.match.querySelector("input[autocomplete='current-password']"), credentials.password);
      step.match.querySelector("#submit").click();
      return null;
    },
  });
});
