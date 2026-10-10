export const providerIdentities: Record<string, string> = {
  "claude-subscription": "You are Claude Code, Anthropic's official CLI for Claude.",
};

export function providerIdentity(provider: string) {
  if (!Object.hasOwn(providerIdentities, provider)) throw new Error(`Unknown provider identity: ${provider}`);
  return providerIdentities[provider]!;
}
