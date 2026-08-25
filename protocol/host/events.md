# Host Events

Host events describe observable state changes rather than provider wire data.
They include chat lifecycle changes, ordered turn updates, streaming agent
output, approval requests, service attachment changes, and terminal outcomes.

Within a session, a transport must preserve event order. A terminal event must
not precede the updates it completes. Duplicate delivery must be detectable by
stable event or state identifiers before remote resumption is standardized.

The embedded iOS Client currently receives typed Swift state directly. A
portable remote event envelope and replay cursor remain to be specified.
