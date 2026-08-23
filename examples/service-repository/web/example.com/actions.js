(() => {
  const actions = new Map([
    ["getPage", async () => ({
      title: document.title,
      heading: document.querySelector("h1")?.textContent?.trim() || null,
    })],
  ]);

  window.ox = {
    async callServiceAction(name, args) {
      const action = actions.get(name);
      if (!action) throw new Error(`unknown action: ${name}`);
      return await action(args ?? {});
    },
  };
})();
