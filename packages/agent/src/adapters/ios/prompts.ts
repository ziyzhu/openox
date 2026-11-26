import { composeOxPrompt } from "../../core/ox-prompts";
import type { SystemPromptInput } from "../../core/prompts";
import type { DeviceContext } from "../../core/device-context";

export function composeIOSPrompt(input: SystemPromptInput, isolated = false) {
  const scope = { deviceID: "ios", profileID: "local" };
  const deviceContext: DeviceContext = input.deviceContext ?? { active: scope, devices: [{ ...scope, functions: ["ox"],
    serviceKinds: ["web", "ios", "mcp"], presentation: "conversation-bubbles", externalFiles: true }] };
  return composeOxPrompt({ ...input, deviceContext }, isolated);
}
