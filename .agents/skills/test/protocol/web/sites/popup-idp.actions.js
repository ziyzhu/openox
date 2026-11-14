window.ox.install(({ action }) => {
  action("listSessions", { invoke: () => [] });
  action("login", { invoke() { document.querySelector("#complete").click(); return null; } });
});
