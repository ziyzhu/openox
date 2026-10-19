export function defaultProviderAuthContext() {
  return {
    env: async () => undefined,
    fileExists: async () => false,
  };
}
