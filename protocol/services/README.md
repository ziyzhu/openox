# Service Protocol

Service repository inventory and web-service metadata are **Normative for version 1**. `schema.ts` is the TypeBox source of truth for `repository.schema.json` and `service.schema.json`. The service SDK's structural schemas must remain identical to these canonical schemas; conformance tests detect drift.

Schema validity is necessary but not sufficient. The semantic requirements below are part of the protocol.

## Repository packages

A repository package uses `repository.json` with `version: 1`. Every listed service has a qualified identity and the exact relative path declared by the inventory. Identities that collide after qualification is removed are duplicates and must be rejected. An inventory may contain at most 256 services.

Each `contentHash` is a lowercase 64-character hexadecimal digest produced by the canonical service compiler. Hosts must reject unsupported versions, duplicate identities, unlisted service directories, invalid paths or hashes, and packages that fail SDK validation.

New manifests are named `service.json`. Readers may support `ox.json` or older manifest forms only at an explicit migration boundary; writers must emit the current format.

## Actions

Action identifiers MUST be unique and match `^[A-Za-z_][A-Za-z0-9_]*$`. `requireApproval` and `requireAuth` are REQUIRED booleans.

Action input and output schemas MUST use only `$ref`, `type`, `properties`, `required`, `additionalProperties`, `items`, `oneOf`, `anyOf`, `allOf`, `enum`, `minimum`, `maximum`, `minLength`, `maxLength`, `pattern`, `default`, and `description`. A local reference MUST have the form `#/$defs/<name>` and resolve within the same `service.json`.

Object output schemas MUST specify `additionalProperties` as `false` or as a schema. Array output schemas MUST define `items`. Every output branch MUST establish a value shape through `type`, `enum`, `$ref`, or composition. `defaultArgs`, when present, MUST validate against the action input schema.

The service `baseUrl` MUST be an absolute static HTTP or HTTPS URL whose host equals `domain` or is its subdomain. An action `baseUrl` follows the same ownership rule and MAY contain placeholders only as complete query-parameter values, such as `?query={query}`. Every placeholder MUST name a string property in `inputSchema`.

`actions.js` MUST install the runtime implementations. Before invoking an action, the Host MUST validate its arguments, enforce authentication and approval requirements, invoke the bounded service runtime, and validate the returned value against the declared output schema.

## Standard action pairs

If either member of a standard pair is present, both must be present.

| Pair | Required contract |
| --- | --- |
| `getSignInUrl` / `getSignInState` | Both inputs are closed objects with no properties; neither requires auth or approval. URL output is a closed object requiring only `url: string`; state output is a closed object requiring only `signedIn: boolean`. Any action with `requireAuth: true` requires this pair. |
| `getBotControlUrl` / `getBotControlState` | Neither requires auth or approval. State input requires `pageUrl: string`; state output requires `ok: boolean`. |
| `getPaymentUrl` / `getPaymentState` | Neither requires auth or approval. State output requires `status` with exactly `none`, `pending`, or `completed`, plus required `reference` allowing exactly a string or `null`. |

## Compatibility

Hosts must validate both structural schemas and these semantic rules before making a service available. Repository data is untrusted until validation and compilation complete. Local, built-in, remote, and development sources remain distinct and follow the Host's explicit precedence and write policies.
