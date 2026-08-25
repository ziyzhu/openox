# Profile Versioning

`profile.json` records a schema milestone. Migrations are ordered, retry-safe,
and stamped only after every operation for a milestone succeeds.

Readers must reject a future milestone they cannot safely interpret. Writers
must not silently downgrade or discard unknown state. Legacy-format handling
belongs in the reference implementation's dedicated migration boundary rather
than normal storage code.
