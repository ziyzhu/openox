# Service Actions

Each action has a stable identifier, user-facing label, closed input schema,
concrete output schema, and explicit approval and authentication requirements.
Action identifiers are unique within one service.

`actions.js` installs implementations for the metadata declared by
`service.json`. The Host validates arguments, applies authentication and
approval gates, invokes the implementation in the service runtime, and
validates its result.

Structural JSON Schema validation is not sufficient. The SDK also enforces URL
ownership, supported schema keywords, closed object outputs, paired standard
actions, default arguments, and service-specific invariants.
