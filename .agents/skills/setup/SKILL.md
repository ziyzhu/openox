---
name: setup
description: Set up OpenOx for CLI, macOS app, or iOS development. Use for dependencies, simulator provisioning, signing, bundled services, first launch, contribution preparation, or setup troubleshooting.
---

# Setup

Read the repository [AGENTS.md](../../../AGENTS.md) and [README.md](../../../README.md). Install [Bun](https://bun.sh/) 1.3 or newer. Clone the repository if needed and run commands from its root:

```sh
git clone https://github.com/ziyzhu/openox.git
cd openox
bun install
```

Inspect existing tools and configuration first. Preserve the contributor’s devices, bundle ID, signing team, and local data. Keep machine-specific values in ignored files. On Linux, use the CLI and repository tooling; native apps require a Mac.

## Ox CLI

```sh
(cd apps/cli && bun run build && bun link)
ox --help
ox profile discover --help
```

Link from `apps/cli`, not the workspace root. If `ox` is missing or shows stale commands, inspect `command -v ox` and resolve the PATH or existing install without overwriting unrelated executables. A source link follows one checkout; to run the CLI from a different checkout, use `bun apps/cli/src/ox.ts` there. For a standalone install, see `apps/cli/install.sh`.

## macOS app

Use macOS 26+, Xcode, and XcodeGen 2.46+ (`brew install xcodegen`).

```sh
bun run build:services
bun run build:agent
DERIVED_DATA=$(mktemp -d)
bun run build:macos -derivedDataPath "$DERIVED_DATA"
"$DERIVED_DATA/Build/Products/Debug/Ox.app/Contents/MacOS/Ox"
```

Stop an existing Mac app before launching another. Verify its status in the menu bar; Ox has no chat UI. Use `--allow-connections` to enable remote access and `--disable-connections` to turn it off. Normal connections require Tailscale; `OX_PROFILE_ENDPOINT` selects the port, not the interface. For Debug-only local verification, launch with `OX_PROFILE_LOOPBACK=1 OX_PROFILE_ENDPOINT=ws://127.0.0.1:19876`. Do not reuse an iOS container for the Mac app.

## Build and run on an iPhone

Use a Mac with Xcode that supports the phone’s iOS version. The iPhone must run iOS 26 or later. Sign in to your Apple Account under **Xcode → Settings → Accounts**. A direct Xcode install does not require App Store Connect access, membership on the OpenOx team, or Beta App Review.

After `bun install`, run `bun run setup:iphone` for the guided setup. It asks for your signing team ID (or accepts `--team-id <ID>`), suggests IDs from local Apple Development signing identities when available, and generates a unique bundle ID for a new `LocalOnly` config. It preserves existing config files, builds the bundled resources, and opens the Xcode project. Then follow steps 3–4 below. For manual setup or an iCloud build, start at step 1.

1. From the checkout root, prepare the bundled resources:
   ```sh
   bun run build:services
   bun run build:agent
   ```
2. If `apps/ios/Local.xcconfig` doesn’t exist, copy `apps/ios/LocalOnly.xcconfig.example` to that path for a build without iCloud, or use `apps/ios/Local.xcconfig.example` for iCloud. Replace the example `OX_DEVELOPMENT_TEAM` with your signing team’s ID. If you don’t belong to a developer team, sign in with a free Apple Account and use your [Personal Team](https://developer.apple.com/support/compare-memberships/) with `LocalOnly`. Replace `OX_BUNDLE_IDENTIFIER` with a unique reverse-DNS identifier you choose, such as `com.janedoe.openox`. You don’t need to own the domain or register the identifier manually. Keep automatic signing enabled for both the app and the share extension.
   - **Find your Personal Team ID:** If **Xcode → Settings → Accounts** shows only the team name, create a temporary iOS app project outside the OpenOx checkout. In the app target’s **Signing & Capabilities**, leave automatic signing on and select your **Personal Team**. From the temporary project folder, run `grep 'DEVELOPMENT_TEAM =' *.xcodeproj/project.pbxproj` and copy the ID into `OX_DEVELOPMENT_TEAM`. You don’t need to build the temporary app or connect a phone.
3. Open `apps/ios/Ox.xcodeproj` in Xcode. Connect and unlock your iPhone, trust the Mac when prompted, and select the phone as the run destination for the `ios` scheme. If prompted, [enable Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device) on the phone and confirm after it restarts.
4. Press **⌘R** to build, install, and launch Ox. Verify that onboarding or the main screen opens on the phone.

The iCloud build needs a paid team and the iCloud container `iCloud.<OX_BUNDLE_IDENTIFIER>`. `LocalOnly` removes iCloud but retains App Groups for the share extension. [Apple lists iOS App Groups as available to free accounts](https://developer.apple.com/help/account/reference/supported-capabilities-ios/), but OpenOx hasn’t been verified on an iPhone with Personal Team signing. Free provisioning profiles expire after seven days, so rebuild and reinstall when needed. See [signing diagnostics](references/simulator.md#ios-signing-and-local-configuration) if provisioning fails.

## Build and run in the iOS simulator

No Apple Account is needed. Install the required [runtime in Xcode](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components), then run `bun run build:services` and `bun run build:agent`.

1. Use the fixed pool: `ox-1`–`ox-3` run iOS 26 and `ox-4`–`ox-5` run iOS 27. [Reserve one available simulator](references/simulator.md#ios-tools-and-simulator-pool) before booting, installing, or launching. Resolve its UDID and never target an implicit booted device.
2. Keep your existing `apps/ios/Local.xcconfig`; if absent, copy `apps/ios/LocalOnly.xcconfig.example` to that path as-is. Follow the [first simulator run](references/simulator.md#first-simulator-run) for ad-hoc signing, which ignores the example team ID. Verify onboarding or the main screen.
   - **Optional:** For a new simulator-only configuration, replace `com.example.openox` with a bundle ID of your choice.
3. Release your claim when done and shut down the simulator if you booted it for this task. Leave other simulators and their data alone.

For seeded QA, use [device templates](references/device-templates.md). [ChatGPT login transfer](references/chatgpt-login.md) is a separate, opt-in workflow.

## Contributing

For source changes, run `bun run lint`, `bun run build`, and `bun run test`, and build each affected native target. The [build guide](../build/SKILL.md) covers native builds and project generation; regenerate the tracked iOS project when `apps/ios/project.yml` changes. Follow the [release guide](../release/SKILL.md#app-store-releases) only for App Store work. Keep credentials and diagnostics outside Git, and report what you actually verified and any remaining blockers.
