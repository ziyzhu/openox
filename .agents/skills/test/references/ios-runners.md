# iOS runner coverage and preparation

Read the selected section before a live run. Use runner `--help` for current arguments and [iOS verification](ios.md) for shared launch requirements.

## Bundled skills

Bundled skill boundaries use `bun .agents/skills/test/apps/ios/bundled-skills.ts --device ox-N --host ws://<assigned-host>:<assigned-port> --conversation <seeded-saved-QA-conversation> --temporary-conversation <empty-temporary-QA-conversation>` after installing a fresh build. Seed the saved Mock conversation with `QA bundled skill verification seed. Reply QA only.` before creating the temporary conversation; inspect after creation for its prepared ID. It verifies Pi-derived native schemas, canonical package bytes, references/helpers, discovery/search, mutation denial, old-path aliases, paginated Unicode reads, exact multi-edits and diffs, parallel-edit serialization, an editable run-owned copy with cleanup, and mutations without prior System activation while preserving temporary-conversation restrictions. After relaunch, wait for `ox host describe` to succeed; a successful native launch does not establish Host readiness. Open the saved QA conversation before creating the empty temporary conversation so both are hydrated without discarding the temporary one. For the default delete-approval policy, leave the app on that Profile's Skills screen and pass `--ui-cleanup`; this confirms deletion of only the run-owned copy without widening policy. Mock `72 bundled` covers model-visible loading and System activation; it is not full workflow verification.

## Settings

`settings.ts` requires an already reachable Host on the selected simulator's assigned port and an idle saved conversation. It exercises language/theme, app-default and conversation-model setters, automatic-model reset, and repository listing/enablement through `ox`, checks validation, no-op results, and hidden compatibility aliases, relaunches the supplied app to verify persistence, and restores the original preferences and saved conversation. VM helper namespace changes do not rename persisted Action identifiers; preserve existing approvals and user-authored helper calls. It does not enable Host access, change credentials, or reset data. Host ingress failures block live verification. For authorized local QA, launch the Debug Simulator app with `OX_HOST_LOOPBACK=1`; never widen physical-device/Release access or bypass approvals to make a test pass.

## Local repository

`local-repository.ts --device ox-N --host <ws-url> --conversation <saved-QA-conversation> --bundle <bundle-id> --domain <qa-draft-domain>` verifies disabled Local mutation refusals against the native Host and byte-identical source, Git, and configuration snapshots. Use enabled Local, an empty run-owned `qa-` web draft, and an idle saved Mock conversation seeded with `QA Local repository enablement regression. Reply QA only.` It restores enablement and writes identical source after reenabling; it creates no drafts or commits. Delete the prepared run-owned draft through the normal UI afterward. This checks runtime safety, not real-model prompting.

## Service icons

`service-icons.ts --device ox-N --host <ws-url> --conversation <saved-QA-conversation> --domain <run-owned-MCP-domain>` serves an attached QA MCP fixture at `http://127.0.0.1:<registryPort>/mcp-favicon-qa` with the matching launch-only `OX_SERVICES_ENDPOINT`. It verifies bundled discovery guidance, small PNGs, ICO frame selection, malformed/unsupported images, candidate fallback, dimension/download limits, and unchanged no-redirect policy for MCP-advertised URLs through actual native loading. It restores the fixture's saved favicon URL; remove the run-owned connection through the UI after the campaign. `--live` additionally contacts Google, httpbingo, and httpbin for explicit HTTPS ICO, redirect success, redirect-limit, unsafe-redirect, and HTTPS-downgrade checks. No provider credentials or website-state changes are required.

## Model selection

`durable-conversation.ts --models` uses native Mock scenario `23` through the actual UI without Host ingress. It verifies deferred switches, pending no-ops, Stop/failure cancellation, and the next queued turn's model, then runs `23 defaults` to verify default selection/reset, invalid arguments, current-conversation isolation, and restoration. It uses the explicit temporary SQLite fixture and restores the normal launch environment; it does not change provider credentials and restores the original new-conversation default. This fixture requires automatic or Mock defaults. Default relaunch checks require the Host-based suite; persisted-conversation model reload is not covered.

## Structured errors

`ox-errors.ts` checks the live VM's three-field `code`, `message`, and `recovery` errors across schema validation, filesystem/native bridges, denied System mutations, missing service attachments, serialization, console output, and uncaught failures. It also verifies help, aliases, parallel failures, and successful calls. Use an idle QA conversation and a fresh installed build; it does not change files, settings, policies, or conversation selection.

## Image widget

`image-widget.ts` verifies remote/local image display, zoom-viewer handoff, source
validation, file moves, model-context separation, process reopen, and remote
failure/retry through `ox`, `simctl`, and `idb`. Use a dedicated saved Mock QA conversation seeded with
`0` and a fresh app on the assigned loopback Host. It retains run-owned fixtures and
the conversation for human review; remove them through normal UI when finished. It never
changes approval policies, provider credentials, or website state. Mock accepts
`execute\n<JavaScript>` for runner-supplied tool calls; keep feature fixtures in E2E
rather than numbered scenarios. After seeding, use the prepared saved ID from
`conversation inspect`, not the provisional ID returned by `conversation new`.

## Profile files

`profile-files.ts` uses a saved Mock conversation whose first message starts with `QA filesystem backend verification seed.` and a fresh installed app. It verifies conversation-relative writes, co-located read-only virtual metadata/transcripts, history aliases, explicit transcript search, private paths, checked edits, directory moves retiring old references, same-path live edits, independent copies, current attachment types, empty-directory persistence, and process reopen. It creates and deletes one run-owned conversation to verify transferred-back ownership cleanup and shared-copy survival, then removes its shared fixtures through ordinary conversation approval without changing Action policies. It does not establish hidden predecessor-archive retention, predecessor upgrade, package round trips, real-provider submission, or physical-device power-loss safety. Pass `--profile-folder <active-local-name>` to also verify the public/private split, external create/edit/move/delete/recreate, physical Memory, and writable user skill resources. Original Memory bytes are restored even after failure. File checks use `ox.fs` paths; historical-reference identity retirement is not covered by this runner. A queued send followed by idle is not proof that a Mock tool ran; verify its result or independent filesystem effect, and retain submission/approval evidence when either is absent. VM calls add receipts to the current transcript; compare immutable historical turns, not whole successive transcript snapshots, when verifying history aliases.

## Manual file picker

Profile Settings → Files presents the native document picker at that Profile's public folder. Verify nested navigation, cancellation/reopen, type-based viewers, and rejection of selections outside that Profile. UIKit can dismiss the picker before delivering its selected URL; exercise the selection-to-viewer handoff rather than accepting dismissal alone. Remote picker controls can be missing from AX; inspect stable screenshots before coordinate interactions. Resolve picker URLs through explicit `/`-prefixed Profile paths so root-level filenames are not mistaken for compatibility references. System search depends on Files indexing and is not established by folder-browsing verification.

## Demo previews

`test:demo` checks native preview
presentation and unchanged profile/repository state, not live integrations; use
the `demo` skill for its workflow.
