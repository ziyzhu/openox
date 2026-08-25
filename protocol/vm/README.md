# VM Contract

This surface owns JavaScript execution, values, limits, cancellation, `ox.*`
function discovery and invocation, permissions, approvals, and the virtual
filesystem. The current detailed contract is in `docs/VM.md`.

- `execution.md` defines isolation, lifetime, limits, and cancellation.
- `values.md` defines values that cross the VM boundary.
- `functions.md` defines `ox.*` discovery and invocation.
- `filesystem.md` defines the mounted namespace and authority rules.
