const SERVICE = "web:ox-ssr.localhost";

window.ox.install(({ action }) => {
  action("listSessions", {
    async invoke() {
      const document = await fetchDocument("/");
      const me = document.querySelector("#me");
      if (me) return [{ id: me.dataset.account, label: me.textContent.trim(), url: `${location.origin}/` }];
      if (document.querySelector("#sign-in")) return [];
      throw new Error("Unclassified SSR account state");
    },
  });

  action("login", {
    async invoke(input = {}, context) {
      const step = await waitForStep({
        signedIn: () => document.querySelector("#me"),
        password: () => document.querySelector("form[action='/login/password']"),
        identifier: () => document.querySelector("form[action='/login/identifier']"),
        entry: () => document.querySelector("#sign-in"),
      });
      if (step.kind === "unknown") throw new Error("SSR sign-in controls did not appear");
      if (step.kind === "signedIn") return null;
      if (step.kind === "entry") {
        step.match.click();
        return null;
      }
      const error = document.querySelector("[role='alert']");
      if (error) throw new Error(`SSR sign-in reported: ${error.textContent.trim()}`);
      if (!input.account || input.account.serviceID !== SERVICE) return null;
      const credentials = await context.secret(input.account);
      if (step.kind === "identifier") {
        typeInto(step.match.querySelector("input[autocomplete='username']"), credentials.username);
        step.match.querySelector("#next").click();
        return null;
      }
      typeInto(step.match.querySelector("input[autocomplete='current-password']"), credentials.password);
      step.match.querySelector("#submit").click();
      return null;
    },
  });

  action("listArticles", {
    async invoke() {
      const data = JSON.parse(document.querySelector("#__NEXT_DATA__")?.textContent ?? "null");
      if (!data) throw new Error("Hydration data missing");
      return { articles: data.props.pageProps.articles };
    },
  });

  action("getInbox", {
    async invoke() {
      const document = await fetchDocument("/inbox");
      const heading = document.querySelector("#inbox");
      if (!heading) throw new Error("Inbox requires sign-in");
      return {
        account: heading.dataset.account,
        messages: [...document.querySelectorAll("li[data-id]")].map(item => ({ id: item.dataset.id, subject: item.textContent.trim() })),
      };
    },
  });
});
