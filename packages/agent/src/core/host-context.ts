export interface HostScope { hostID: string; profileID: string }
export interface PromptHost extends HostScope {
  functions: string[];
  serviceKinds: ("web" | "api" | "ios" | "mcp")[];
  presentation: "chat-bubbles" | "text";
  externalFiles: boolean;
}
export interface HostContext { active: HostScope; hosts: PromptHost[] }

export function sameScope(a: HostScope, b: HostScope) {
  return a.hostID === b.hostID && a.profileID === b.profileID;
}

export function activeHost(context: HostContext) {
  if (!context || !Array.isArray(context.hosts) || !context.active) throw new Error("Host context requires an active scope and hosts");
  const scopes = new Set<string>();
  for (const host of context.hosts) {
    if (typeof host?.hostID !== "string" || !host.hostID || typeof host.profileID !== "string" || !host.profileID
      || !Array.isArray(host.functions) || !host.functions.every(name => typeof name === "string" && (name === "ox" || name.startsWith("ox.")))
      || !Array.isArray(host.serviceKinds) || !host.serviceKinds.every(kind => ["web", "api", "ios", "mcp"].includes(kind))
      || !["chat-bubbles", "text"].includes(host.presentation) || typeof host.externalFiles !== "boolean") throw new Error("Invalid prompt host facts");
    const key = JSON.stringify([host.hostID, host.profileID]);
    if (scopes.has(key)) throw new Error("Duplicate host/Profile scope");
    scopes.add(key);
  }
  const host = context.hosts.find(host => sameScope(host, context.active));
  if (!host) throw new Error("Active host/Profile scope is unavailable");
  return host;
}

export function hostContextText(context: HostContext) {
  const host = activeHost(context);
  const label = (scope: HostScope) => `${JSON.stringify(scope.hostID)} / ${JSON.stringify(scope.profileID)}`;
  return ["## Hosts", `Active host/Profile: ${label(host)}`, ...context.hosts.map(owner =>
    `- ${label(owner)}: ${[...new Set(owner.functions)].sort().join(", ") || "no native functions"}`),
    "Capabilities, file paths, permissions, handoffs, and output references are owned by their host and Profile. Use only exposed contracts for the owning scope. Do not substitute another host or Profile when continuing or retrying an operation."].join("\n");
}
