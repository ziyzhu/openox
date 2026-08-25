# Credentials

Status: Normative.

Reusable credentials belong to the platform credential store or the isolated
service session that owns them. They do not belong in Profiles, repositories,
logs, VM values, model prompts, command-line arguments, fixtures, or artifacts.

Services may return authentication state and trusted sign-in URLs without
returning credential material. Diagnostic output redacts tokens, cookies,
authorization headers, signing material, and provider keys.
