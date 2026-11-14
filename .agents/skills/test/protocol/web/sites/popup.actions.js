window.ox.install(({ action }) => {
  action("listSessions", { invoke: () => fetchJSON("/sessions") });
  action("login", { invoke() { document.querySelector("#sign-in").click(); return null; } });
});
