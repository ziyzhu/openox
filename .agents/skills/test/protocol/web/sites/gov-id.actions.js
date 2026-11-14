const SERVICE = "web:ox-govid.localhost";

window.ox.install(({ action }) => {
  action("listSessions", {
    async invoke() {
      const { account } = await fetchJSON("/api/session");
      return account ? [{ id: account.id, label: account.label, url: `${location.origin}/` }] : [];
    },
  });

  action("login", {
    async invoke(input = {}, context) {
      const step = await waitForStep({
        challenge: () => document.querySelector("input[autocomplete='one-time-code']"),
        returning: () => document.querySelector("#returning, #signed-in"),
        password: () => document.querySelector("form[action='/signin/password']"),
        email: () => document.querySelector("form[action='/signin/email']"),
      });
      if (step.kind === "unknown") throw new Error("Gov ID sign-in controls did not appear");
      if (document.querySelector("#returning")) await new Promise(resolve => setTimeout(resolve, 4000));
      if (step.kind === "challenge" || step.kind === "returning") return null;
      if (document.querySelector("[role='alert']")) throw new Error("Gov ID reported a sign-in error");
      if (!input.account || input.account.serviceID !== SERVICE) return null;
      const credentials = await context.secret(input.account);
      const field = step.kind === "email" ? "input[autocomplete='username']" : "input[autocomplete='current-password']";
      typeInto(step.match.querySelector(field), step.kind === "email" ? credentials.username : credentials.password);
      step.match.querySelector("#submit").click();
      return null;
    },
  });
});
