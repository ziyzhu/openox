# Security Protocol

The trust, approval, credential, and isolation boundaries in this document are **Normative**.

The reference implementation's detailed threat model and residual risks are documented in `../../docs/SECURITY.md`.

## Trust model

The user, the user-selected Host, and the installed application are trusted policy authorities. Model output, VM code, service repositories, remote and web content, MCP results, imported profiles, and transport peers are untrusted input.

Untrusted text cannot grant authority. Authority comes only from profile configuration, source policy, service metadata, platform policy, or an explicit user decision.

## Approvals

Approval must occur before a sensitive or external effect. The prompt must identify the operation and its material arguments. Approval is scoped to that operation unless the user explicitly grants a durable policy.

Cancellation, timeout, changed material arguments, or a changed profile or session invalidates a pending approval.

## Credentials

Reusable credentials belong in the platform credential store or an isolated authenticated session. They must not enter profiles, repositories, logs, VM values, model context, command-line arguments, fixtures, or artifacts.

Authentication state and trusted sign-in URLs may cross the protocol when their schemas permit it. Implementations must redact tokens, cookies, authorization headers, signing material, and keys from diagnostics.

## Isolation

The VM has no ambient network, shell, device, or Host-filesystem authority. Browser capabilities are restricted to the declared domain and its website data store. Repository content remains data until it passes validation and enters a bounded runtime.

A profile may access only its declared resources. Local, built-in, remote, and development service sources remain separate, with explicit precedence and write authority.
