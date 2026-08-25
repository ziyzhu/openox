# Agent Protocol

**Status: Draft.** OpenOx does not yet define a portable Agent wire protocol or a complete schema for persisted turns. The concepts here guide implementations without creating a compatibility promise.

## Turns and messages

A turn should have a stable identity and represent semantic content rather than provider-specific wire objects. Implementations should be able to express user and agent text, reasoning, tool executions, prompts for user input, effects, and terminal state. UI blocks and provider messages are projections of that semantic turn.

An interrupted running turn must become cancelled or failed before it is persisted. A persisted turn must not remain indefinitely in an ambiguous running state.

Agent input can include profile context, prior turns, the current request, available skills, and VM function contracts. Agent output can include text, reasoning, tool calls and results, prompts, effects, usage, and a terminal state. Provider request fields, streaming deltas, cache markers, and provider stop reasons are not portable protocol data.

## Tools

The Agent reaches external capabilities through the VM and its `ox.*` functions. A tool call identifies a function by name and supplies a closed input object. The Host validates the input and output against the function's current schemas.

Required approval must be obtained before an effect occurs. A successful tool result only proves an external effect when that guarantee is part of the function contract. Credentials and reusable secrets must never appear as tool values.

The Agent representation described here is draft. VM schema validation, approval, and capability isolation are normative under `../vm/README.md` and `../security/README.md`.

## Terminal states

The design targets explicit terminal states for completion, cancellation, failure, context exhaustion, and waiting for user input. Provider-specific stop reasons may be retained for diagnostics but must not be the application's only state model.

The current persisted reference format is documented in `../../docs/STORAGE.md`.
