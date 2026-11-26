export interface DeviceScope { deviceID: string; profileID: string }
export interface PromptDevice extends DeviceScope {
  functions: string[];
  serviceKinds: ("web" | "api" | "ios" | "mcp")[];
  presentation: "conversation-bubbles" | "text";
  externalFiles: boolean;
}
export interface DeviceContext { active: DeviceScope; devices: PromptDevice[] }

export function sameScope(a: DeviceScope, b: DeviceScope) {
  return a.deviceID === b.deviceID && a.profileID === b.profileID;
}

export function activeDevice(context: DeviceContext) {
  if (!context || !Array.isArray(context.devices) || !context.active) throw new Error("Device context requires an active scope and devices");
  const scopes = new Set<string>();
  for (const device of context.devices) {
    if (typeof device?.deviceID !== "string" || !device.deviceID || typeof device.profileID !== "string" || !device.profileID
      || !Array.isArray(device.functions) || !device.functions.every(name => typeof name === "string" && (name === "ox" || name.startsWith("ox.")))
      || !Array.isArray(device.serviceKinds) || !device.serviceKinds.every(kind => ["web", "api", "ios", "mcp"].includes(kind))
      || !["conversation-bubbles", "text"].includes(device.presentation) || typeof device.externalFiles !== "boolean") throw new Error("Invalid prompt device facts");
    const key = JSON.stringify([device.deviceID, device.profileID]);
    if (scopes.has(key)) throw new Error("Duplicate device/Profile scope");
    scopes.add(key);
  }
  const device = context.devices.find(candidate => sameScope(candidate, context.active));
  if (!device) throw new Error("Active device/Profile scope is unavailable");
  return device;
}

export function deviceContextText(context: DeviceContext) {
  const device = activeDevice(context);
  const label = (scope: DeviceScope) => `${JSON.stringify(scope.deviceID)} / ${JSON.stringify(scope.profileID)}`;
  return [`Active device/Profile: ${label(device)}`, ...context.devices.map(owner =>
    `- ${label(owner)}: ${[...new Set(owner.functions)].sort().join(", ") || "no native functions"}`),
    "Capabilities, file paths, permissions, handoffs, and output references are owned by their device and Profile. Use only exposed contracts for the owning scope. Do not substitute another device or Profile when continuing or retrying an operation."].join("\n");
}
