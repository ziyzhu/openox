# Protocol Conformance

A valid fixture must match its canonical schema and all applicable semantic rules. An invalid fixture must be rejected for the reason named by the test.

Conformance covers:

- direct TypeScript validation against the canonical schemas;
- service SDK validation and canonical-schema drift detection;
- implementation drift checks for exported protocol and schema-version constants;
- semantic service, profile, and development Host rules represented by committed fixtures.

Agent fixtures are intentionally absent while the Agent surface remains draft.

The service fixtures in `services/` cover portable repository and manifest metadata only. Full service exports, runtime code, and sanitized replay fixtures live with the built-in service repository and its compiler tests.
