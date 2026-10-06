import { composeOxPrompt, oxScaffold } from "../../core/ox-prompts";
import type { SystemPromptInput } from "../../core/prompts";
import type { HostContext } from "../../core/host-context";

export function composeIOSPrompt(input: SystemPromptInput, isolated = false) {
  const scope = { hostID: "ios", profileID: "local" };
  const hostContext: HostContext = input.hostContext ?? { active: scope, hosts: [{ ...scope, functions: ["ox"],
    serviceKinds: ["web", "ios", "mcp"], presentation: "chat-bubbles", externalFiles: true }] };
  return composeOxPrompt({ ...input, hostContext }, isolated, oxScaffold);
}
