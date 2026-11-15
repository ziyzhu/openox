window.ox.install(({ action }) => {
  for (const id of ["exercise", "boundaries", "benchmark"]) {
    action(id, {
      async invoke() {
        throw new Error("Author the Local fixture with embedded automation before invocation");
      },
    });
  }
});
