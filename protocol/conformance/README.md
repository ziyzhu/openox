# Conformance

Conformance fixtures are grouped by protocol surface. Files under `valid/` MUST
match the canonical structural schema and pass applicable semantic validators.
Files under `invalid/` MUST be rejected for the named reason.

The tests execute the TypeScript schemas directly. Service tests additionally
execute the public SDK validators and compare SDK structural schemas with the
protocol source of truth. Implementation drift checks pin the reference Host
and Profile version constants to the published protocol version.

No Agent conformance fixtures exist because Agent turns and messages are Draft.
