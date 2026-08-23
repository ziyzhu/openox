# Manifest and copy contract

Read this before creating or changing `manifest.json`, action schemas, labels,
descriptions, or locale overlays. `services/manifest.ts` is authoritative.

## Contents

- Manifest shape
- Schema profile
- Structural rules
- Consumer-facing copy

## Manifest shape

The closed manifest contains `domain`, `name`, optional `description`, required
absolute service-domain `baseUrl`, optional `$defs`, `actions`, and optional
`locales`. Each action contains:

- `id`: JavaScript identifier matching `action("<id>")`
- `label` and `description`
- optional absolute service-domain `baseUrl`
- required `inputSchema` and `outputSchema`
- optional `defaultArgs`, validated at build time
- optional `blocking`, defaulting to `false`; set it to `true` when the action needs exclusive ownership of the service page
- required `requireApproval` and `requireAuth`

Locale overlays may set the service name/description and action labels or
descriptions. Do not add manifest keys that are absent from
  `services/manifest.ts`.

## Schema profile

Use only `$ref` to local `$defs`, `type`, `properties`, `required`,
`additionalProperties`, `items`, `oneOf`, `anyOf`, `allOf`, `enum`, `minimum`,
`maximum`, `minLength`, `pattern`, `default`, and `description`. Do not use
`format`, `const`, or `nullable`; express null with a union or composition.

Make output schemas concrete recursively. Every object must define
`additionalProperties: false` or a schema for additional values. Every array
must define `items`. See `matchatennis.com/manifest.json`.

## Structural rules

- The service `baseUrl` and every action `baseUrl` must be on the service domain
  or a subdomain.
- Actions may run concurrently by default. Actions with `baseUrl` are blocking
  automatically because the runtime navigates the shared service page before
  invoking them. Set `blocking` to `true` for any other action that needs
  exclusive access to shared page state or must not overlap with itself.
- A complete query value may be `{stringInput}` for a direct string property.
  The client encodes present values and removes absent optional parameters.
  Never place placeholders in schemes, hosts, paths, query names, partial
  values, or fragments.
- Do not add `allowedDomains`; the client handles public off-domain sign-in
  navigation.
- Declare URL/state pairs together for auth, bot control, and payment
  handoff. Neither member requires auth or approval.
- Auth URL/state use exact empty input and return only `{url}` / `{signedIn}`.
- Bot-control state requires `pageUrl` and returns `{ok}`.
- Payment state returns required `status` and nullable `reference` using the
  exact contract in [actions.md](actions.md).
- Any action with `requireAuth: true` requires the auth pair.

## Consumer-facing copy

- Start the service description with what the service is in fewer than ten
  words, without repeating its name; then summarize capabilities.
- Describe capabilities, results, choices, and visible consequences for an
  average person. Keep implementation terms such as endpoints, proxies,
  captures, cookies, signing, tokens, raw payloads, and cursor mechanics out of
  labels and descriptions.
- Describe action behavior rather than ids or field names. Put exact argument
  and result mechanics in schema-property descriptions.
- Mention sign-in only as a user requirement. State mutation effects,
  approvals, finality, and money movement plainly.
- Prefer “Open <service>,” “Sign in to <service>,” and “Check <service>
  sign-in.” Give every action a description.
- Translate every service and action string when a locale overlay exists.
  Preserve meaning and safety, use natural local terminology, and avoid mixed
  language through fallback.
