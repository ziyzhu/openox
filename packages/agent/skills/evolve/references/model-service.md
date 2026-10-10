# Website conversation services

Websites are services, never Ox model providers. Adding `conversation` or `listModels` Actions does not register a provider. The Ox agent runs through API-backed providers; an AI website receives only explicit service inputs, not automatic Ox history, system instructions, or tool declarations.

Use the normal web-service discovery, copy-to-Local, conflict resolution, validation, and Save workflow. Built-ins remain read-only. Preserve unrelated Local edits and existing website drafts.

Read `references/model-schemas.md` for the exact `conversation` schema. It supports `submit`, `read`, and `cancel` on one Host-owned page. Keep the normal label, authentication, and approval fields; do not change the manifest format or standard schemas. Legacy model-generation Actions remain reserved for installed-service validation, not agent execution or ordinary tool discovery. Do not author new ones.

- Pages belong separately to the calling chat, Canvas, or direct Client. They share website accounts, not DOM, session storage, conversation references, or submissions. Keep website state in the page installer closure.
- `submit` receives explicit messages, options, and attachment references. Reject unsupported input before submission. Submit once, return promptly, and retain asynchronous work on the page. Never queue or retry implicitly.
- Report acceptance as uncertain unless verified against the website's remote conversation and message identities. An exception after possible acceptance must not trigger resubmission. Keep the original failure in diagnostics.
- Return page-local submission and conversation IDs. The Host wraps these in process-local opaque handles; archived handles cannot restore work after page or process loss.
- Advertise continuation only when verified. Continue only the latest completed, uncancelled submission with the same model/options and new explicit messages. Reject unknown, stale, busy, failed, or cancelled references; keep previous submissions readable.
- Reads return immutable, ordered events with bounded cursors. Text snapshots extend previously published text. A completion marker must correlate with the submitted conversation; a stopped animation or enabled Send button is not proof.
- Preserve conversation URLs and generated-file metadata when available. Website file IDs are not local paths; URLs may be session-bound. Never execute or automatically download untrusted references.
- Cancellation remains callable while a read waits. Report cancelled only when confirmed; otherwise requested, completed, or unsupported. Closing a page does not prove remote cancellation.
- Use a literal base URL and a nonblocking Action. The Host bounds open/opening pages to 12 and submissions per page to 32. Idle sessions expire after ten minutes when pruned; active pages have a one-hour absolute lifetime without claiming cancellation. Cleanup invalidates handles without resubmitting.
- `listModels` may expose website choices to service callers. It never alters the Ox provider catalog or current model.

Verify through actual service Actions, not Browser inspection alone. Exercise fresh submissions, continuation, attachments, generated-file references, read/cancel concurrency, and concurrent same-account callers on separate pages. Check both fetch and XHR on fresh pages. Confirm the complete explicit prompt and matching remote conversation/reply identities.

Test signed-out and expired-session behavior only with synthetic fixtures or isolated sessions. Removing authentication from a live website request can trigger its unauthorized handler and clear the user's session. Sign-in probes must read fresh shared state without credential-clearing handlers; verify a separate sign-in handoff page.
