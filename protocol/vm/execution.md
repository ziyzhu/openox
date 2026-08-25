# VM Execution

Status: Normative.

VM source runs in an isolated language runtime with no ambient network, shell,
device, or Host filesystem access. Host capabilities are available only through
the injected `ox.*` catalog.

Executions for one VM are serialized. Cancellation stops tracked Host bridge
work and produces an explicit terminal result. A Host may reuse a language
context between executions, but must replace Profile-scoped VM state when the
active Profile changes.

The iOS reference implementation uses JavaScriptCore. JavaScriptCore is an
implementation choice, not a requirement for compatible Hosts.
