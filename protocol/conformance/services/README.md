# Service Conformance Fixtures

The `valid/` fixtures MUST be accepted by the version 1 TypeScript schemas and
SDK validators. The `invalid/` fixtures each isolate one interoperability violation and MUST be
rejected.

These fixtures validate metadata contracts. Full repository export, action
runtime, and replay behavior remain covered by the service package tests.
