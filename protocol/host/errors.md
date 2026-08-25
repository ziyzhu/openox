# Host Errors

A command response repeats the request identifier and indicates success or
failure. Failure is terminal for that command and must not be represented as a
successful value.

The current version 1 simulator transport returns a human-readable `error`
string. Portable error codes, retry classification, and structured details are
reserved work. Clients must not parse current error prose as a stable API.

Transport failure, unsupported protocol version, invalid arguments, denied
approval, unavailable session, and Host execution failure remain distinct
conditions even when a transport cannot yet encode them separately.
