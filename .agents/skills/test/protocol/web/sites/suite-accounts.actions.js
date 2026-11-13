const SERVICE = "web:accounts.ox-suite.localhost";

window.ox.install(({ action }) => {
  action("listSessions", {
    async invoke() {
      const { accounts } = await fetchJSON("/ListAccounts");
      return accounts.map(account => ({ id: account.id, label: account.label, url: `${location.origin}/signin` }));
    },
  });

  action("login", {
    async invoke(input = {}, context) {
      const step = await waitForStep({
        signedIn: () => document.querySelector("#signed-in"),
        password: () => document.querySelector("form[action='/signin/password']"),
        identifier: () => document.querySelector("form[action='/signin/identifier']"),
      });
      if (step.kind === "unknown") throw new Error("Suite Accounts sign-in controls did not appear");
      if (step.kind === "signedIn") return null;
      const error = document.querySelector("[role='alert']");
      if (error) throw new Error(`Suite Accounts sign-in reported: ${error.textContent.trim()}`);
      if (!input.account || input.account.serviceID !== SERVICE) return null;
      const credentials = await context.secret(input.account);
      const field = step.kind === "identifier" ? "input[autocomplete='username']" : "input[autocomplete='current-password']";
      typeInto(step.match.querySelector(field), step.kind === "identifier" ? credentials.username : credentials.password);
      step.match.querySelector("#next").click();
      return null;
    },
  });
});
