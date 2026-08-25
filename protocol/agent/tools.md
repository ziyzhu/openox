# Tools

The Agent executes code through the VM and reaches Host capabilities through
advertised `ox.*` functions. Each call has a name, closed input contract,
declared output contract, and an observable result or error.

Approval is a Host decision made before the protected effect. A tool result
does not imply that an effect occurred unless the result contract says so.
Credentials remain inside their owning adapter and never become tool values.
