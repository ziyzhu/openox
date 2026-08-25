# In-Process Transport

Status: Normative ownership mapping; language bindings are implementation-specific.

An embedded Client dispatches typed operations directly to its Host. It does
not serialize requests, open a loopback socket, or create a second runtime.

Direct dispatch must preserve the same ownership, authorization, approval, and
session-binding behavior as any remote transport. Language-specific values may
be used internally, but observable values at the protocol boundary must remain
representable by the shared contracts.
