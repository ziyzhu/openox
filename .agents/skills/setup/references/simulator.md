# Simulator provisioning and QA

## iOS tools and simulator pool

Use macOS with Xcode supporting the assigned iOS 26 and iOS 27 runtimes. Install components in **Xcode > Settings > Components**, following [Apple's component installation guide](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components). An older Xcode may need upgrading before it can use a newer runtime. Keep existing Xcode installations and devices until replacements work; never erase simulator data to resolve a missing runtime.

Use `xcodebuild` to build and `xcrun simctl` to discover devices, install, launch, and capture screenshots or video. UI automation needs both the `idb` client and companion; check `idb ui --help` for supported commands. Resolve the chosen name to a unique UDID and pass it explicitly; never rely on a default booted target.

- Use the fixed five-simulator pool: `ox-1` through `ox-3` run iOS 26; `ox-4` and `ox-5` run iOS 27. Verify with `xcrun simctl list devices available --json` before testing. Keep replaced devices as backups until replacements are verified. Each concurrent agent uses its own simulator and matching ports from [scripts/qa-config.ts](../scripts/qa-config.ts). Always pass `--device` explicitly to QA runners. The QA harness accepts only those five names.
- Default to one reserved simulator and reuse it throughout the task. The pool is available capacity, not a boot list. Boot additional devices only for explicitly requested parallel testing or necessary cross-iOS coverage; run cross-iOS checks sequentially unless parallel execution is requested. Do not boot the pool for setup, builds, or baseline synchronization.
- Reserve before booting, installing, or launching, including manual work. [scripts/simulator.ts](../scripts/simulator.ts) `claimSimulator` holds `<os.tmpdir()>/ox-qa-tests/<device>.lock` with a live owner PID and rejects devices claimed by another live process; a booted device or running app is not a claim. For manual work, keep an owner running in the background and kill it to release: `bun -e 'import { claimSimulator } from "./.agents/skills/setup/scripts/simulator.ts"; claimSimulator("ox-4"); setInterval(() => {}, 1 << 30)' &`.
- Record the reserved device's initial boot state. On completion, failure, or interruption, shut down devices this task booted after confirming no ownership handoff occurred. Leave previously booted devices running, release task-owned claims, and report any cleanup that could not be completed. Never use `simctl shutdown all`.
- Missing iOS 27 support blocks `ox-4` and `ox-5`; do not substitute iOS 26 or change the pool policy. Partial setup can proceed on the first three reserved targets.
- Before touching a device, check other agents' sessions and repository QA claims, then coordinate ownership. Choose another device if it is in use; never interrupt or change another agent's simulator. Those claims cover repository runners only; no activity signal proves exclusive ownership. Clone only free, shutdown simulators; preserve originals as backups and verify replacements with `xcrun simctl list devices available --json`.
- Create or clone simulators only to provision missing members of the fixed pool with their assigned runtimes. If compatible pool devices are busy, coordinate or wait; do not create task-named devices to bypass contention. Creating devices outside the pool requires explicit user approval. Provision missing members in Xcode's **Devices and Simulators** window or clone a free, shutdown baseline. After reserving a suitable iOS 26 baseline, for example:

```sh
xcrun simctl clone "$BASELINE_UDID" ox-1
xcrun simctl clone "$OX1_UDID" ox-2
xcrun simctl clone "$OX1_UDID" ox-3
```

Prepare the required website/provider state only on simulators selected for the task, using `ox-1` as the baseline when needed. Do not initialize or boot unused pool devices. Copy only when both source and target are free. Cloning does not establish that credentials or website logins still work. Verify configuration, default model, provider credentials, and website logins after building and installing. For explicit state transfers between running, reserved targets, consult `bun run sim:bootstrap --help` and the [website-state limitations](../../test/references/storage.md#website-state). Bootstrap copies cookies/local storage and installs provider API keys; other website data and provider settings need separate setup.

Resolve `BASELINE_UDID` and, after cloning, `OX1_UDID` from the inventory before running those commands. `scripts/simulator.ts` shares native device/runtime checks and PID claims with the test runners. `scripts/ios.ts` composes native commands for the QA harness without an external wrapper CLI. Claims coordinate repository runners only; they do not replace agent ownership checks. `scripts/bootstrap.ts` owns the explicit credential/artifact/website-state setup behind `bun run sim:bootstrap`.

## iOS signing and local configuration

- Reuse `OX_BUNDLE_IDENTIFIER` from the existing `apps/ios/Local.xcconfig` for builds, installs, and probes. Resolve the built app's actual identifier before installing; stop on an unexpected identity. Do not add task suffixes or substitute example identifiers for routine QA. Isolate tasks with simulator reservations and task-specific DerivedData, not extra installed apps. Additional identities require explicit user approval; record which installs the task created, remove only those installs before releasing the target (also on failure or interruption), and verify the normal app remains. Never uninstall pre-existing apps without confirmation.
- Simulator builds can use ad-hoc signing without an Apple account: pass `OX_DEVELOPMENT_TEAM= DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES` to `xcodebuild`, retaining the configured bundle identifier. Verified on Xcode 26.2 / iOS 26: build, install, onboarding, main screen, and a checked Keychain write/read/delete through `DeviceTemplate`. Launch with `--disable-icloud` for local-only verification. This does not establish free Personal Team device provisioning; unsigned device compilation is not installation evidence.
- For device build configuration, see [Build and run on an iPhone](../SKILL.md#build-and-run-on-an-iphone). Enable `CODE_SIGNING_ALLOWED = YES` for a build that needs Keychain. Do not put a team ID, certificate, profile, or credential in tracked files.
- Check for a usable local signing identity with `security find-identity -v -p codesigning`. An App Store Connect API key or a certificate listed by `asc` does not supply the certificate's private key to this Mac. If the identity is absent, guide the contributor through Xcode's Apple Account and automatic signing setup, or use an existing private key they control. Do not create, revoke, or replace a certificate as a routine setup step.
- After building, inspect the actual `.app` with `codesign -dv --verbose=4 <app>` and `codesign -d --entitlements :- <app>`. For a Keychain `errSecMissingEntitlement` startup failure, check the app identifier, access groups, and embedded entitlements before changing simulator data. Apple's [Keychain entitlement diagnosis](https://developer.apple.com/documentation/security/errsecmissingentitlement) explains the failure. A successful build alone does not establish that Keychain works.

## First simulator run

Set `UDID` to the reserved simulator’s UDID and `BUNDLE_ID` to `OX_BUNDLE_IDENTIFIER` from `apps/ios/Local.xcconfig`. If the simulator is shut down, boot it with `xcrun simctl boot "$UDID"`, then wait for `xcrun simctl bootstatus "$UDID" -b`. After preparing the bundles, build with ad-hoc signing:

```sh
DERIVED_DATA=$(mktemp -d)
xcodebuild -project apps/ios/Ox.xcodeproj -scheme ios -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED_DATA" \
  OX_DEVELOPMENT_TEAM= DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

After a successful build, check the bundle ID before installing:

```sh
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Ox.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")" = "$BUNDLE_ID" &&
  xcrun simctl install "$UDID" "$APP_PATH" &&
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" --disable-icloud
```

- For QA, use the reserved simulator’s matching ports and initialize website/provider state only if the scenario needs it. Rebuild and reinstall after switching worktrees. Keep screenshots and recordings outside the repository.
- Use standard text size for ordinary QA. Record settings before changing them and restore them afterward, including after failures.
- Re-resolve the app data container after every install; Simulator may change its container UUID while preserving data. Do not retain absolute container paths across installs.
- Use bundled services normally. Only when testing repository installation or sync, start `ox --repository examples/repository repository serve --port <registry-port>`, verify `curl -fsS http://127.0.0.1:<registry-port>/health`, and relaunch with `SIMCTL_CHILD_OX_SERVICES_ENDPOINT=http://localhost:<registry-port>/repository.git` in the launch environment.
- Inspect and drive UI with `idb`; use `idb ui describe-all --udid "$UDID"` to locate controls and verify the expected screen instead of treating launch success as verification. Launch by the configured bundle identifier. If duplicate Ox icons are found, inventory their identifiers and request cleanup approval rather than selecting an arbitrary icon or deleting existing app data.
- For CLI access, turn on **Allow Connections** on the active Profile (**Settings > Profiles > <Profile>**) and keep Ox foreground. Physical-device and Release builds require Tailscale on both devices. A Debug Simulator launch can explicitly opt into localhost by prefixing the `simctl launch` command with `SIMCTL_CHILD_OX_PROFILE_LOOPBACK=1 SIMCTL_CHILD_OX_DEBUG_ENDPOINT="ws://127.0.0.1:$DEBUG_PORT"` using the assigned port. It binds only `127.0.0.1` and uses the ordinary Profile API. This flag is compiled out on physical devices and Release builds; a normal relaunch restores Tailscale-only access. `OX_DEBUG_ENDPOINT` selects the port, not the ingress mode. Verify `ox --profile ws://127.0.0.1:<debug-port> profile describe` for loopback, or use `ox profile discover`/the tailnet address for Tailscale. A `starting` log is not readiness. Preserve failure logs, never add unrestricted listeners or bypass approvals, and restore temporary settings afterward.
- Use Mock for a no-cost smoke test; real provider calls require authorization. Enter provider credentials through Ox's secure UI when needed. The ignored `secrets/API_KEYS.json` is only for local test bootstrap; never request a key in conversation or pass it on a command line.
