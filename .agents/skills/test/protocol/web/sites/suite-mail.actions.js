window.ox.install(({ action }) => {
  action("listSessions", {
    async invoke() {
      const { accounts } = await fetchJSON("/api/accounts");
      return accounts.map(account => ({ id: account.id, label: account.label, url: `${location.origin}/` }));
    },
  });

  action("login", {
    async invoke() {
      const step = await waitForStep({
        signedIn: () => document.querySelector("#me"),
        entry: () => document.querySelector("#sign-in"),
      });
      if (step.kind === "unknown") throw new Error("Suite Mail sign-in controls did not appear");
      if (step.kind === "entry") step.match.click();
      return null;
    },
  });

  action("getInbox", {
    async invoke() {
      const document = await fetchDocument("/");
      const me = document.querySelector("#me");
      if (!me) throw new Error("Inbox requires sign-in");
      return { account: me.dataset.account, messages: [...document.querySelectorAll("#inbox li")].map(item => item.textContent.trim()) };
    },
  });
});
