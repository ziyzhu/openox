# Profile Versioning

Status: Normative migration behavior.

`profile.json` records a string schema milestone. The current reference
milestone is exported as `PROFILE_SCHEMA_VERSION` from `schema.ts`. A Host MAY
read an older milestone only when it has an ordered migration from that exact
value. Migrations MUST be retry-safe and MUST stamp the next milestone only
after every operation for that step succeeds.

Readers MUST reject an unknown milestone they cannot safely interpret. Writers
MUST NOT silently downgrade or discard unknown state. Legacy-format handling
belongs in the reference implementation's dedicated migration boundary rather
than normal storage code.
