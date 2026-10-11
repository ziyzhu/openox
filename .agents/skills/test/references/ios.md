# iOS verification

Follow [setup](../../setup/SKILL.md) for simulator ownership, runtimes, assigned ports, and baseline state.
Use the shared `ios-simulator` skill for builds, UI interaction, captures, and diagnostics;
`setup` owns OpenOx scheme/signing/launch configuration. Use task-specific
DerivedData. It avoids build-database locks, not concurrent source-generation races.
A matched tap does not prove a native switch changed: wait for stable frames, use
`idb ui tap X Y --duration 0.25 --udid "$UDID"` for switch controls, and verify AX value and behavior. Resolve coordinates from the current AX tree.
`ci:ios` requires idb, Xcode, an explicitly reserved numbered simulator, and Host
connections already enabled. `--app /absolute/Ox.app` skips building and reuses a
verified artifact; rebuild after source changes or switching worktrees. Install/launch
checks the artifact's bundle identifier. Screenshots use `simctl`, not an idb companion. For browser ingress, `simctl openurl` uses the simulator's selected browser, not necessarily Ox. A temporary macOS CoreSimulator harness can target `SimDevice.launchApplicationWithID:options:error:` with `payload_url` as an **NSURL**, not a string; keep the harness outside Git and distinguish targeted URL-delivery evidence from default-browser eligibility. It never provisions, clones, uninstalls, erases,
changes credentials, or enables Host access.

The bundle comes from `--bundle`, `OX_BUNDLE_ID`, or `apps/ios/Local.xcconfig`.
The default Host uses the selected device's assigned port; VPN ingress can use
`--host ws://<simulator-vpn-address>:9101` for ox-1. `ci:ios --loopback` explicitly
opts a Debug Simulator launch into `127.0.0.1`; it still requires Allow connections,
uses ordinary Host APIs, and is compiled out on physical devices and Release builds.
The opt-in is launch-only; relaunch without it to restore Tailscale-only networking.

The runner builds in evidence-local DerivedData unless `--app` is supplied,
installs/launches with `simctl`, and verifies UI through idb.
This is a Host/conversation smoke with visible UI evidence, not composer/Send interaction coverage.
It creates a temporary Mock conversation, sends scenario `2`, verifies the completed reply
and visible assistant message, then attempts to restore the prior saved conversation.
It only shuts down a simulator it booted. Relaunching can discard an unsaved
temporary conversation: use a dedicated QA target, not personal working state.

Inline service sign-in verification must include sending while the page is open, then expanding and returning it inline. Attach the service before running Mock `50`; verify the queued message and continued app process, since transcript layout changes can recreate row-owned WebViews.

PID claims coordinate these runners only, not manual native-tool use or other agents. `test:agent-ui-ios --device ox-1 --app /absolute/Ox.app` exercises the actual
temporary-conversation Pi path with native Mock already selected. It checks reasoning,
Markdown, native snippet tools, separate worker ownership and drain-before-restart
for Stop followed by queued input, committed SQLite history and process reopen.
It requires an idle conversation, claims the selected simulator, uses no Host transport,
and restores ordinary launch afterward. `OX_DURABLE_TEMPORARY_SESSION=<UUID>`
enables temporary-conversation UI attachment in Debug and Release builds on simulators
and physical devices; it does not enable Host access or adopt persisted Profiles.
Diagnostic RPCs remain restricted to DEBUG Simulator builds. Stopped-process SQLite copies include WAL/SHM
and are diagnostic evidence, not Profile exports or power-loss verification.
