window.ox.install(({ action }) => {
  action("getPage", {
    invoke: async () => ({
      title: document.title,
      heading: document.querySelector("h1")?.textContent?.trim() || null,
    }),
  });
});
