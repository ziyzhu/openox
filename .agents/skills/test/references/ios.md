# iOS verification

Follow [setup](../../setup/SKILL.md) for simulator ownership, assigned ports, and baseline
state; use `ios-simulator` for native tools. Use task-specific DerivedData and rebuild
after source changes. `--app` reuses an existing build. PID claims coordinate runners
only, so coordinate manual tools separately.

Host-based runners require enabled connections on the selected device's assigned port.
Wait for `ox host describe` after relaunch. `ci:ios --loopback` opts a Debug Simulator
launch into loopback networking; relaunch without it to restore ordinary networking.
This does not enable connections or widen physical-device/Release access.

Restore simulator preferences with Ox stopped through `xcrun simctl spawn <UDID> defaults`, then verify them after relaunch. Host-side preference-file edits can be overwritten by the simulator's cached values; restore absent keys as well as saved values.

`ci:ios` requires Xcode and idb, builds in evidence-local DerivedData, and verifies a
Mock reply through Host APIs and visible UI. It does not cover composer/Send interaction.
It attempts to restore the prior saved conversation and shuts down only a simulator it
booted. Use dedicated QA state: relaunch can discard an unsaved temporary conversation.

`test:agent-ui-ios` exercises native Mock through the temporary-conversation UI,
including Stop/queued input, committed history, and process reopen. Requires an idle
conversation with Mock selected; restores ordinary launch. It uses no Host transport.
`OX_DURABLE_TEMPORARY_SESSION` attaches an isolated fixture without adopting persisted
Profiles. Diagnostic RPCs remain DEBUG Simulator-only. SQLite copies must include
WAL/SHM; they are diagnostics, not Profile exports or power-loss evidence.

Verify behavior or independent effects, not just taps, queued sends, or idle status.
After Profile selection, reconnect the Host socket before issuing another request. For persisted conversations, use the conversation ID returned by Send; the initial ID from New can change when the conversation is first saved.
For native switches that ignore an idb default tap, verify the current hit target, use `idb ui tap --duration 0.15`, and assert the resulting AX value. Refresh frames after CLI mutations change a visible list.
For transcript comparisons, use immutable historical turns: VM calls append receipts.
For conversation opening, verify the final visible tail after Markdown layout expands, then
scroll away and reopen; an initial bottom geometry sample alone does not prove success.

Verify streaming-rendering changes in video across paragraph/fence boundaries and completion; content assertions and settled screenshots do not establish visual continuity.
For Liquid Glass chrome, compare frame-by-frame geometry and material lifetimes, not just
spring duration or settled screenshots. Hidden controls must disappear visually as well as from AX.

Verify Send handoffs in video for empty/populated conversations, short/multiline/long drafts,
keyboard visible/hidden, and scrolled history. Confirm non-queued cases have `posted`
receipts; inspect rising motion separately from queue promotion and final anchoring.
Track previous visible rows alongside the incoming bubble; a stable final anchor
does not establish a continuous push through the handoff.
Confirm activity and thinking loaders stay hidden until the Send handoff is anchored.

Measure Client–Host latency over a warmed persistent RPC connection using identical fresh
fixtures for A/B runs. Report stop acknowledgement separately from observed idle state,
and inspection snapshots separately from embedded presentation reads. Use physical
footprint, not RSS, for memory comparisons; run profiling separately from latency samples.
Pass the Simulator UDID to `xctrace --device` when attaching to its app process.
For bimodal RPC timings, compare mean and tail latency as well as median; distinguish
native enqueue timestamps from wire acknowledgement.

For scroll-performance regressions, compare identical saved transcripts before and after
a native Send. Count full conversation view evaluations as well as CPU time; geometry
samples needed only by event handlers must not invalidate the transcript every frame.
