# Service Actions

Status: Normative for version 1 web services.

Action identifiers MUST be unique within a service and match
`^[A-Za-z_][A-Za-z0-9_]*$`. `requireApproval` and `requireAuth` are REQUIRED
booleans. `inputSchema` and `outputSchema` MUST use only `$ref`, `type`,
`properties`, `required`, `additionalProperties`, `items`, `oneOf`, `anyOf`,
`allOf`, `enum`, `minimum`, `maximum`, `minLength`, `maxLength`, `pattern`,
`default`, and `description`.

Local references MUST have the form `#/$defs/<name>` and resolve within the
same `service.json`. An object output MUST set `additionalProperties: false` or
provide a schema for additional values. An array output MUST define `items`.
Every output branch MUST define a type, enum, reference, or composition.

When `defaultArgs` is present, it MUST validate against `inputSchema`.

The service `baseUrl` MUST be an absolute HTTP or HTTPS URL whose host equals
`domain` or is its subdomain. It MUST be static. An action `baseUrl` follows the
same ownership rule and MAY contain input placeholders only as complete query
values such as `?query={query}`. Every placeholder MUST name a string property
in `inputSchema`.

## Standard actions

The following pairs are reserved:

| URL action | State action | Additional requirements |
| --- | --- | --- |
| `getSignInUrl` | `getSignInState` | Both have empty closed inputs, require neither auth nor approval. URL output is exactly required string `url`; state output is exactly required boolean `signedIn`. Any action with `requireAuth: true` requires this pair. |
| `getBotControlUrl` | `getBotControlState` | Both require neither auth nor approval. State input requires string `pageUrl`; state output requires boolean `ok`. |
| `getPaymentUrl` | `getPaymentState` | Both require neither auth nor approval. State output requires `status` with exactly `none`, `pending`, or `completed`, plus `reference` allowing exactly string or null. |

Declaring either member of a reserved pair requires the other.

`actions.js` MUST install implementations for the declared actions. The Host
MUST validate arguments, apply authentication and approval gates, invoke the
bounded service runtime, and validate the returned value before exposing it to
the Agent.
