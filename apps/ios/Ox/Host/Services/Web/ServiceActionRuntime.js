(() => {
  window.__openOxCreateServiceRuntime = domain => {
    const actions = new Map();
    let installed = false;
    const log = message => {
      try {
        window.webkit?.messageHandlers?.oxConsole?.postMessage({
          level: "log",
          msg: `[service:${domain}] ${message}`,
        });
      } catch {}
    };
    const action = (name, definition) => {
      if (installed) throw new Error("service installer has already completed");
      if (typeof name !== "string" || !name) throw new Error("action name must be a non-empty string");
      if (actions.has(name)) throw new Error(`duplicate action: ${name}`);
      if (typeof definition?.invoke !== "function") throw new Error(`action ${name} has no invoke function`);
      actions.set(name, definition.invoke);
    };
    const api = new Proxy(Object.freeze({ action }), {
      get(target, name) {
        if (name in target) return target[name];
        throw new Error(`service installer does not provide ${String(name)}`);
      },
    });
    const install = (installer, ...extra) => {
      if (installed || actions.size > 0) throw new Error("service installer may run only once");
      if (typeof installer !== "function" || extra.length) throw new Error("window.ox.install takes only the installer");
      try {
        const result = installer(api);
        if (result && typeof result.then === "function") throw new Error("service installer must be synchronous");
        installed = true;
      } catch (error) {
        actions.clear();
        log(`service installer threw: ${String(error?.stack ?? error?.message ?? error)}`);
        throw error;
      }
    };
    const callServiceAction = async (name, args = {}) => {
      if (!installed) throw new Error("service installer has not completed");
      const handler = actions.get(name);
      if (!handler) throw new Error(`unknown action: ${name}`);
      try {
        return await handler(args ?? {});
      } catch (error) {
        log(`action ${JSON.stringify(name)} threw: ${String(error?.stack ?? error?.message ?? error)}`);
        throw new Error(`action ${JSON.stringify(name)} failed: ${String(error?.message ?? error)}`);
      }
    };
    return { install, callServiceAction };
  };
})();
