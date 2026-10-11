# iOS verification

Follow [setup](../../setup/SKILL.md) for simulator ownership, assigned ports, and baseline
state; use `ios-simulator` for native tools. Use task-specific DerivedData and rebuild
after source changes. `--app` reuses an existing build. PID claims coordinate runners
only, so coordinate manual tools separately.

Host-based runners require enabled connections on the selected device's assigned port.
Wait for `ox host describe` after relaunch. `ci:ios --loopback` opts a Debug Simulator
launch into loopback networking; relaunch without it to restore ordinary networking.
This does not enable connections or widen physical-device/Release access.

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
For transcript comparisons, use immutable historical turns: VM calls append receipts.

Verify streaming-rendering changes in video across paragraph/fence boundaries and completion; content assertions and settled screenshots do not establish visual continuity.

Measure Client–Host latency over a warmed persistent RPC connection using identical fresh
fixtures for A/B runs. Report stop acknowledgement separately from observed idle state,
and inspection snapshots separately from embedded presentation reads. Use physical
footprint, not RSS, for memory comparisons; run profiling separately from latency samples.
Pass the Simulator UDID to `xctrace --device` when attaching to its app process.
