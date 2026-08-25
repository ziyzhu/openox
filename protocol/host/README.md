# Host Contract

Status: mixed. The VM control envelopes in `schema.ts` are Normative for version
1 development Hosts. Remote lifecycle and event delivery are Draft.

The version 1 control surface contains exactly four request kinds:

- `vm-inspect`
- `vm-functions`
- `vm-call`
- `vm-eval`

Other commands accepted by the iOS DEBUG simulator are test automation APIs and
MUST NOT be advertised as OpenOx Host protocol commands.

`vm-control-request.schema.json` and `vm-control-response.schema.json` are
generated from `schema.ts`. `commands.md`, `errors.md`, and `transports/`
define behavior not captured structurally.
