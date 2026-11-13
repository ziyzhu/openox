# Remaining service login work

Core web login is implemented. Simulator fixtures verify two-page saved login, same-page login, provider redirects, destination session verification, and manual login capture inside nested cross-site iframes. Those checks do not establish the broader cases below. Audit current code and evidence before treating a follow-up as missing implementation.

- Verify legacy secret typing, “Needs setup” field mapping, existing bindings, Settings permission rules, and macOS credential entry with predecessor-written data.
- Verify action-over-service permission resolution, combined approvals, Always approve scope, block and revocation, deletion during an attempt, and background work that requires approval.
- Verify malformed, missing, untyped, and wrong-type references; references not passed into the invocation; non-owning services and frames; cross-Host use; and attempts to send retrieved values outside the owner domain.
- Check model outputs, action results, errors, and diagnostics for raw and encoded secret values. Verify inspection/screenshot locks and the API handler network boundary.
- Verify selection among several saved accounts, explicit manual-login requests, expired sessions, account switchers, and concurrent conversations without silently substituting an account or clearing shared cookies.
- Verify rejection and lockout behavior, CAPTCHA, MFA, trust/consent screens, password changes, replacement of saved credentials, cancellation, timeout, and process exit. Preserve an existing secret until its replacement is verified and accepted.
- Exercise capture across navigation and dynamic forms: token matching, hidden or remembered usernames, missing tokens, formless login, forged messages, mismatched owner domains, OTP/new-password exclusion, duplicate capture, and declined remember prompts.
- Verify third-party provider popups, regional domains, already-signed-in accounts, account choosers, missing provider services, consent handoff, and provider success without destination success. Real-account Drive verification remains unestablished by fixture results.
- Audit API typed credential entry, owner-bound retrieval through `request`, safe authenticated-read verification, remember/decline behavior, and bounded transient credential lifetime. Preserve managed OAuth behavior.
- Audit MCP/iOS reference resolution and conversation-scoped sensitive output references before scheduling further implementation; these were follow-up scope in the original plan.
- Verify credential exclusion during Profile export/import and behavior before first device unlock. Keep credentials device-owned and out of model-visible values.

Website session isolation and passkeys remain in [the browser plan](browser.md). Do not infer isolated sessions from account routing. Use disposable accounts, keep evidence outside Git, and record pass, fail, and unverified outcomes separately.
