const SERVICE = "web:ox-gql.localhost";

const graphql = async (operationName, variables = {}) => {
  const token = document.cookie.split("; ").find(entry => entry.startsWith("gql_csrf="))?.slice("gql_csrf=".length);
  if (!token) throw new Error("CSRF cookie missing");
  const result = await fetchJSON("/graphql", {
    method: "POST", headers: { "content-type": "application/json", "x-csrf-token": decodeURIComponent(token) },
    body: JSON.stringify({ operationName, variables }),
  });
  if (result.errors?.length) throw new Error(`GraphQL ${operationName}: ${result.errors[0].message}`);
  return result.data;
};

window.ox.install(({ action }) => {
  action("listSessions", {
    async invoke() {
      const { viewer } = await graphql("Viewer");
      return viewer ? [{ id: viewer.id, label: viewer.name, url: `${location.origin}/` }] : [];
    },
  });

  action("login", {
    async invoke(input = {}, context) {
      const step = await waitForStep({
        signedIn: () => document.querySelector("#me"),
        credentials: () => document.querySelector("form[action='/login']"),
      });
      if (step.kind === "unknown") throw new Error("GraphQL fixture sign-in controls did not appear");
      if (step.kind === "signedIn") return null;
      const error = document.querySelector("[role='alert']");
      if (error) throw new Error(`GraphQL fixture sign-in reported: ${error.textContent.trim()}`);
      if (!input.account || input.account.serviceID !== SERVICE) return null;
      const credentials = await context.secret(input.account);
      typeInto(step.match.querySelector("input[autocomplete='username']"), credentials.username);
      typeInto(step.match.querySelector("input[autocomplete='current-password']"), credentials.password);
      step.match.querySelector("#submit").click();
      return null;
    },
  });

  action("listNotes", { async invoke() { return { notes: (await graphql("Notes")).notes }; } });

  action("addNote", { async invoke(input) { return (await graphql("AddNote", { title: input.title })).addNote; } });
});
