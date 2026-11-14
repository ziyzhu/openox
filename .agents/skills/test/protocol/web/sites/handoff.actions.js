window.ox.install(({ action }) => {
  action("listSessions", { async invoke() { return []; } });
  action("login", {
    async invoke() {
      const scenario = new URL(location.href).searchParams.get("scenario") || "control";
      const response = await fetch("/dispatch?scenario=" + encodeURIComponent(scenario), { method: "POST" });
      if (!response.ok) throw Error("Fixture dispatch failed");
      location.assign("/start?scenario=" + encodeURIComponent(scenario));
      return null;
    },
  });
});
