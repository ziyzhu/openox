---
name: security-questions
description: Handle USTravelDocs security-question prompts during sign-in. Use when the user asks which security questions are configured, authentication reaches the security-question step, or sign-in must be handed back to the user securely.
---

# USTravelDocs security questions

The documented security questions are:

1. What was the name of your first/current/favorite pet?
2. What is the name of the road/street you grew up on?
3. In what city or town was your first job?

The supplied capture showed the first two questions. The third question was provided by the user.

## Authentication boundary

- Treat answers as credentials.
- Never infer, request in chat, read from captures or page fields, print, log, store, or submit an answer.
- Use `getSignInUrl` to hand sign-in to the user. The user must enter answers directly on USTravelDocs.
- After the user finishes, use `getSignInState` to check sign-in.
- If sign-in is incomplete or rejected, return control to the user. Never retry answers or use `service eval` to inspect them.
- Use `getAppointmentAvailability` only after `getSignInState` reports `signedIn: true`.
