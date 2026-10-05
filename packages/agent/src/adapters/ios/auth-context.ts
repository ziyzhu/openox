/** Bare JavaScriptCore has neither process environment nor credential-file access.
 * Native providers own credentials. Replaces only pi-ai 1.0.0's Node-aware default auth context at build time.
 */
export function defaultProviderAuthContext() {
  return {
    env: async () => undefined,
    fileExists: async () => false,
  };
}
