window.ox.install(({ action, request }) => {
  action("publicRead", { invoke: () => request({ path: "/public", method: "GET" }) });
  action("read", { invoke: () => request({ path: "/read", method: "GET" }) });
  action("write", { invoke: () => request({ path: "/write", method: "POST", json: {} }) });
});
