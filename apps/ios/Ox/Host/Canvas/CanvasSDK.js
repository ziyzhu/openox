globalThis.__oxCreateCanvasSDK = (catalog, send) => {
  const ox = Object.create(null);
  ox.service = Object.create(null);
  const forbidden = new Set(["__proto__", "constructor", "prototype"]);
  const serialize = value => {
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
      throw new TypeError("Expected one options object");
    }
    const json = JSON.stringify(value, (_, item) => {
      if (["function", "symbol", "bigint"].includes(typeof item)) throw new TypeError("Arguments must be JSON values");
      if (typeof item === "number" && !Number.isFinite(item)) throw new TypeError("Arguments must contain finite numbers");
      return item;
    });
    if (new TextEncoder().encode(json).length > 1048576) throw new RangeError("Canvas request exceeds 1 MiB");
    return JSON.parse(json);
  };
  for (const name of Object.keys(catalog.schemas)) {
    if (!name.startsWith("ox.service.")) continue;
    const path = name.slice(3).split(".");
    if (path.some(part => forbidden.has(part) || !part)) throw new TypeError("Invalid function name");
    let parent = ox;
    for (const part of path.slice(0, -1)) parent = parent[part] ??= Object.create(null);
    const call = async argumentsValue => {
      const argumentsJSON = serialize(argumentsValue);
      const response = await send({ function: name, arguments: argumentsJSON });
      if (!response || typeof response.ok !== "boolean") throw new Error("Invalid Host response");
      if (!response.ok) throw new Error(response.error || "Service operation failed");
      return response.value;
    };
    Object.defineProperty(call, "help", {
      value: () => (catalog.help[name] || name) + "\n\nCanvas resolves services automatically; chat attachment instructions do not apply.",
    });
    parent[path.at(-1)] = Object.freeze(call);
  }
  const freeze = value => {
    for (const child of Object.values(value)) if (child && typeof child === "object") freeze(child);
    return Object.freeze(value);
  };
  return freeze(ox);
};
