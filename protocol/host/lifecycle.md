# Host Lifecycle

A Client selects one Host and may select one chat-backed session on that Host.
The Host owns Profiles, chats, model adapters, services, and VM instances. A
Client never opens those resources behind the Host's back.

An embedded Client connects by direct dispatch. A remote Client establishes a
transport connection, negotiates a compatible protocol version and
capabilities, then binds operations to a session identifier when required.

Connection loss ends transport delivery, not Host-owned work. Reconnection,
event resumption, and remote authentication are not yet exposed by the current
iOS reference Host and must not be inferred from its simulator control socket.
