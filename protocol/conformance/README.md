# Conformance

This directory will hold implementation-independent valid, invalid, and
scenario fixtures consumed by Clients, Hosts, SDKs, and repository validators.
Fixtures belong here only when multiple implementations must agree on their
meaning.

`services/` contains version 1 service metadata fixtures exercised through the
canonical SDK validators. Future Host, Agent, VM, and Profile fixtures should
be added only alongside a portable reader or implementation-independent
validator.
