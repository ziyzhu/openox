# iCloud Mail

Status: proposed implementation plan; no runtime changes. Start with on-demand, read-only access on iOS and macOS, then add sending. Confirm the service identity, dependency, and credential-binding approach before implementation.

## Scope

Connect directly to iCloud Mail from the active Ox Host without a hosted backend. Do not access Apple Mail's local database, automate iCloud.com, or use Sign in with Apple as mailbox authorization.

First milestone: connect one account per Profile, list mailboxes, search messages, read bodies without marking them read, and download selected attachments. Credentials stay device-local; account availability must respect the active Profile even if secrets use the existing app-wide store.

Second milestone: compose and send plain-text messages and replies, including selected attachments, after explicit review and confirmation. Folder moves, flags, trash, aliases, multiple accounts, server drafts, full mailbox caching, background monitoring, and push notifications are deferred. Permanent deletion is out of scope.

## Existing integration points

- `apps/shared/Host/Services/Native/NativeServiceOperations.swift` dispatches native actions. Add mail operations through the existing service invocation and approval path, using shared implementation rather than platform duplicates.
- `apps/shared/Host/Services/Native/NativeServiceCatalog.swift` and platform catalogs resolve bundled native definitions. `apps/macos/Host/Services/MacNativeServiceCatalog.swift` currently allowlists supported services; both platforms need registration.
- `apps/shared/Resources/OxServices.bundle/ios/*/service.json` contains existing native action contracts. Follow the existing source/build pipeline rather than editing generated resources blindly. Native definitions currently use `ios:` identities even for shared functionality; settle mail naming before adding an identity.
- `apps/shared/Host/Credentials/Secret.swift` provides secret entries and consumer bindings; `Credentials.swift` provides checked Keychain operations. Existing consumer kinds do not include native mail, so credential integration is a real implementation decision, not a drop-in HTTP basic-auth configuration.
- `apps/ios/Host/Services/ServiceImplementations.swift` and its macOS counterpart own service authentication/capabilities. Native permission-only UI is insufficient for an email/password connection; extend the existing account-entry and service-detail flow narrowly.
- Keep agent-facing guidance and any bundled workflow in `packages/agent`. Do not introduce a general mail-provider framework, new service kind, or generic socket tool for this feature without approval.

## Phase 1: feasibility and decisions

1. Establish the current baseline: show that iCloud Mail is unavailable through service discovery on both Hosts. Record the intended conversation flow and current service/credential UI using disposable data.
2. Verify current Apple guidance for third-party iCloud Mail access, app-specific passwords, username rules, aliases, and custom domains. Standard configuration is IMAP `imap.mail.me.com:993` with TLS and SMTP `smtp.mail.me.com:587` with required STARTTLS. Never fall back to plaintext or accept invalid certificates.
3. Evaluate maintained libraries for IMAP, SMTP, and MIME against deployment targets, Swift concurrency, cancellation, streaming, TLS validation, licensing, maintenance, dependency size, and build tooling. Do not assume an acceptable library exists or write a protocol stack as the default fallback. Report a blocker if none qualifies.
4. Build a small disposable-account transport spike outside the repository: authenticate, list mailboxes, fetch a message without changing flags, parse representative MIME, and verify SMTP authentication. Avoid sending until explicitly authorized. Build the candidate dependency for both apps.
5. Approve the dependency, service identity, Profile account ownership, secret binding, and proposed limits. Prefer the smallest shared implementation with platform UI adapters. Do not broaden existing HTTP API services to raw sockets.

Apple references to review before implementation: [iCloud Mail settings](https://support.apple.com/en-us/102525), [app-specific passwords](https://support.apple.com/en-us/102654), [Keychain Services](https://developer.apple.com/documentation/security/keychain-services), and [Network framework](https://developer.apple.com/documentation/network) if used by the chosen transport. Validate current guidance rather than treating this plan as an API specification.

## Phase 2: account connection

- Add localized connection UI for email/IMAP username and app-specific password. Explain the two-factor authentication prerequisite and password creation/revocation; never request the primary Apple Account password. Keep the authenticated username separate from the display/from address where Apple requires it.
- Reuse existing secret entry controls and checked Keychain writes. Scope bindings to the approved account identity and fixed Apple destinations, not a model-supplied host. Credentials must never pass through action arguments, conversation history, model context, exported Profiles, or diagnostic payloads.
- Model account state explicitly: disconnected, connecting, connected, and credentials rejected. Report transient network failures without discarding valid credentials. Existence of a stored password alone does not prove connectivity.
- Validate IMAP before enabling read actions. Validate SMTP separately when sending becomes available. Provide retry, credential replacement, and disconnect; confirm destructive credential removal and explain effects on any shared binding.
- Cancel pending work and close sessions on disconnect, Profile change, or Host teardown. Prevent an operation authorized in one Profile from completing into another.
- Keep only necessary account metadata and credential references. Review predecessor compatibility before changing persisted secret enums or metadata: adding a Codable enum case can break older readers. If storage changes are needed, capture before/after fixtures, update the canonical storage map, and require an explicit compatibility decision.

## Phase 3: read-only actions

Define strict input/output schemas and bounded defaults before wiring the UI. Proposed actions, subject to naming review:

- `listMailboxes`: names, opaque mailbox identifiers, and special-use roles when available.
- `searchMessages`: mailbox, bounded filters for sender/recipient/subject/date/read status, page size, and continuation cursor; return message summaries, not bodies or an entire mailbox.
- `readMessage`: headers, bounded readable body, attachment metadata, and explicit truncation indicators. Use non-mutating fetch semantics such as `BODY.PEEK`.
- `downloadAttachment`: fetch a selected MIME part into the existing conversation file/attachment path; return a file reference, not model-visible Base64.

Use account + mailbox + UIDVALIDITY + UID to identify a message, never sequence numbers or Message-ID alone. Bind continuation cursors to account, mailbox, and query; detect stale UIDVALIDITY and return an actionable restart condition. Define search order and pagination behavior under incoming mail and concurrent deletions.

Parse multipart/alternative, nested multipart, transfer encodings, encoded headers, character sets, inline parts, and empty bodies. Prefer text/plain and convert HTML safely when necessary. Never execute email HTML, load remote images, follow links, or treat message contents as agent instructions. Pass mailbox names, search values, and headers through typed/escaped library APIs rather than raw protocol interpolation.

Set limits for result count, body bytes, attachment bytes, total output, connection concurrency, and operation duration. Fetch headers first and bodies/parts only on demand. Reject oversized or unsafe filenames, traversal, and attachment collisions through existing file safety rules. Keep transport work and parsing off the main actor; implement cancellation, bounded reconnects, and cleanup without a full local mail index.

## Phase 4: sending

- Add one send operation with structured To/Cc/Bcc addresses, subject, plain-text body, optional reply reference, and explicit attachment file references. Initially allow only the authenticated, verified sender; do not assume aliases are valid.
- Show the exact recipients, sender, subject, body, and attachments for explicit confirmation through the existing approval UI. Bind approval to immutable content and invalidate it if anything changes. Block header injection and invalid addresses before submission.
- Establish TLS via STARTTLS before authentication. Generate standards-compliant MIME and reply headers. Preserve Bcc privacy in transmitted headers and diagnostics.
- Distinguish SMTP acceptance from delivery. A dropped connection after submission is an unknown outcome, not permission to retry automatically; prevent duplicate sends and give the user an honest reconciliation path. Never claim exactly-once delivery.
- Verify actual iCloud Sent-folder behavior before deciding whether to append a sent copy; avoid duplicate copies. Clearly report partial recipient acceptance and sent-copy failure without resending accepted mail.

## Verification and release gates

Use E2E coverage, not new unit tests. Use a controlled IMAP/SMTP server for repeatable protocol and failure scenarios, plus a disposable real iCloud mailbox for Apple-specific acceptance. Keep credentials and evidence outside the repository. Obtain confirmation before sending real messages or destructive mailbox operations.

- Account lifecycle: invalid/revoked passwords, locked/unavailable Keychain, offline operation, reconnect, credential replacement, restart, disconnect, Profile switching, and isolation between Profiles. Verify credentials are absent from model-visible data, logs, and exports.
- Mail: empty and large mailboxes, Unicode names/subjects, changed UIDVALIDITY, concurrent arrivals/deletions, search boundaries, pagination, missing parts, malformed MIME, HTML-only bodies, non-UTF-8 text, inline images, and large/unsafe attachment names. Verify reading leaves flags unchanged.
- Failures: cancellation, timeouts, process termination, server disconnect, TLS rejection, bounded resource use, and actionable errors without secret or message leakage.
- Sending: approval cancel/edit, reply headers, attachments, Bcc, rejected/partially accepted recipients, ambiguous submission, and Sent-folder behavior. Confirm receipt independently in a controlled recipient mailbox.
- Exercise the real agent/service path with a configured model provider as well as direct service invocation. Email content is deliberately untrusted; verify it cannot trigger unauthorized actions.
- Capture localized connection, error, reading, attachment, and approval UI on simulators for visual review. Use stable automation IDs on actual controls, equal outer padding, and accessibility checks. Verify a physical iPhone for device-specific Keychain and network behavior.
- Record structured operation ID, action, stage, duration, counts/bytes, retry count, and sanitized error category. Exclude credentials, addresses, subjects, bodies, raw MIME, and raw protocol transcripts. Measure memory and latency with large messages before selecting final limits.
- Build affected iOS and macOS app targets before committing shared native changes. Run applicable service packaging, schema/static, protocol, and storage compatibility checks; report blockers and obtain approval before committing if a required native build cannot run.
- Review LOC delta, file tree diff, call stack diff, cyclomatic complexity, and performance for each implementation change. Keep README, onboarding, and website copy consistent only if this feature changes public claims.

## Completion criteria

Read milestone is complete when a user can connect iCloud Mail on either Host, search/read without mailbox mutations, save an attachment, and disconnect safely with verified credential isolation. Sending is a separate acceptance gate requiring reviewed content, independently observed receipt, and demonstrated handling of ambiguous SMTP outcomes. Estimates follow the dependency spike; background sync and mailbox management are not prerequisites for either milestone.
