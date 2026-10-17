export const guidance: Record<string, string> = {
  "ox.secret.list": "List secret metadata without exposing values: `await ox.secret.list({ purpose })`. Returns each secret's key, displayName, sorted JSON field names in fields, and available status.",
  "ox.secret.add": "Ask the person to add or replace a named JSON secret in a native inline card: `await ox.secret.add({ purpose, key })`. The value is never a JavaScript argument or result. For model provider credentials, use ox.provider.authenticate instead.",
  "ox.secret.delete": "Ask the person to delete a secret and clear its connections: `await ox.secret.delete({ purpose, key })`.",
  "namespace.secret": "Manage named secrets without exposing their values to the agent.",
};
