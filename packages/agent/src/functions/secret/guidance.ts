export const guidance: Record<string, string> = {
  "ox.secret.list": "List secret metadata without exposing values: `await ox.secret.list({ purpose })`. Returns each secret's key, displayName, sorted JSON field names in fields, available status, type (account, apiKey, token, or null when it needs setup), and owning serviceID.",
  "ox.secret.add": "Ask the person to add or replace a typed secret in a native card: `await ox.secret.add({ purpose, key, type, serviceID? })`. type is account ({ username, password }), apiKey, or token; serviceID names the owning service, such as web:accounts.google.com. The value is never a JavaScript argument or result. For model provider credentials, use ox.provider.authenticate instead.",
  "ox.secret.delete": "Ask the person to delete a secret and clear its connections: `await ox.secret.delete({ purpose, key })`.",
  "namespace.secret": "Manage named secrets without exposing their values to the agent.",
};
