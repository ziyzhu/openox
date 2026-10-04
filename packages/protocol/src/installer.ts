export type InstallerTarget = {
  kind?: string;
  actions: { id: string }[];
};

export function inspectInstaller(source: string, service: InstallerTarget): string[] {
  const registered: string[] = [];
  const unavailable = () => { throw new Error("not callable during registration inspection"); };
  let installations = 0;
  const action = (name: unknown, definition: { invoke?: unknown } | undefined) => {
    if (typeof name !== "string" || !name) throw new Error("action name must be a non-empty string");
    if (registered.includes(name)) throw new Error(`duplicate action: ${name}`);
    if (typeof definition?.invoke !== "function") throw new Error(`action ${name} has no invoke function`);
    registered.push(name);
  };
  const api = new Proxy(Object.freeze(service.kind === "api" ? { action, request: unavailable } : { action }), {
    get(target, name) {
      if (name in target) return Reflect.get(target, name);
      throw new Error(`service installer does not provide ${String(name)}`);
    },
  });
  const window = {
    ox: {
      install(installer: unknown, ...extra: unknown[]) {
        installations++;
        if (installations > 1) throw new Error("service installer may run only once");
        if (typeof installer !== "function" || extra.length) throw new Error("window.ox.install takes only the installer");
        const result = installer(api);
        if (result && typeof result.then === "function") throw new Error("service installer must be synchronous");
      },
    },
  };
  try {
    new Function("window", source)(window);
  } catch (error) {
    return [`actions failed to register: ${(error as Error).message}`];
  }
  if (installations !== 1) return ["actions must install exactly once"];
  const declared = new Set(service.actions.map(action => action.id));
  const missing = [...declared].filter(id => !registered.includes(id)).sort();
  const extra = registered.filter(id => !declared.has(id)).sort();
  if (!missing.length && !extra.length) return [];
  const parts = [
    missing.length ? `missing implementations: ${missing.join(", ")}` : "",
    extra.length ? `undeclared implementations: ${extra.join(", ")}` : "",
  ].filter(Boolean);
  return [`action registration mismatch; ${parts.join("; ")}`];
}
