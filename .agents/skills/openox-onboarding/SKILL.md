---
name: openox-onboarding
description: Set up a new OpenOx checkout for local development, including dependencies, CLI access, iOS simulator signing, bundled services, and first launch. Use when a contributor asks to get OpenOx running or diagnose an initial setup failure.
---

# OpenOx onboarding

Help the contributor reach a verified working environment. First determine whether they need the CLI, the iOS app, or both. Inspect existing tools and configuration before changing anything; preserve their chosen simulator, bundle identifier, Apple team, and local data.

## Source checkout and tools

- Read the repository `AGENTS.md` and relevant package documentation. Keep machine-specific values in ignored local files.
- Check `bun --version`, `ox --help`, and, for iOS, `sim --help`, `xcode-select -p`, and `sim devices`. Use `bun install` for workspace dependencies. Use `bun run typecheck` as the first source check.
- For CLI installation or source builds, follow [apps/cli/README.md](../../../apps/cli/README.md). For iOS interaction, use the `sim-cli` skill and `sim`; never build directly with `xcodebuild`.
- On macOS, confirm Xcode and an iOS 26 Simulator runtime are installed. Apple documents installing older runtimes in [Xcode Components settings](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components). On Linux, limit setup to the CLI and repository tooling.

## iOS signing and local configuration

- Copy `apps/ios/Local.xcconfig.example` to the ignored `apps/ios/Local.xcconfig` if it does not exist. Set `OX_BUNDLE_IDENTIFIER` to the contributor's intended identifier and `OX_DEVELOPMENT_TEAM` to their Apple Developer team. Enable `CODE_SIGNING_ALLOWED = YES` for a build that needs Keychain. Do not put a team ID, certificate, profile, or credential in tracked files.
- Check for a usable local signing identity with `security find-identity -v -p codesigning`. An App Store Connect API key or a certificate listed by `asccli` does not supply the certificate's private key to this Mac. If the identity is absent, guide the contributor through Xcode's Apple Account and automatic signing setup, or use an existing private key they control. Do not create, revoke, or replace a certificate as a routine onboarding step.
- After building, inspect the actual `.app` with `codesign -dv --verbose=4 <app>` and `codesign -d --entitlements :- <app>`. For a Keychain `errSecMissingEntitlement` startup failure, check the app identifier, access groups, and embedded entitlements before changing simulator data. Apple's [Keychain entitlement diagnosis](https://developer.apple.com/documentation/security/errsecmissingentitlement) explains the failure. A successful build alone does not establish that Keychain works.

## First simulator run

- Use an available iOS 26 `ox-qa-1` through `ox-qa-5` simulator. Check its runtime with `sim devices` before testing. Read `tooling/qa-config.ts` for its debug port and optional repository port. Keep QA names within the fixed pool; if replacing a device from another runtime, retain it under a backup name and verify the replacement before removing the backup. Rebuild and reinstall after switching worktrees.
- Build, install, and launch bundled services with `sim --device <simulator> run <bundle-id> --project apps/ios/Ox.xcodeproj --scheme ios --env OX_DEBUG_ENDPOINT=ws://127.0.0.1:<debug-port> --force`.
- To test loading a local repository separately, start `ox repository serve examples/repository --port <registry-port>`, verify `curl -fsS http://127.0.0.1:<registry-port>/health`, and relaunch with `--env OX_SERVICES_ENDPOINT=http://localhost:<registry-port>/repository.git`.
- Confirm the normal UI with `sim describe` or a screenshot, then use `ox discover` or the selected Host endpoint to check that the Host is available. If UI automation cannot start `idb_companion`, distinguish that from an app startup failure using the screenshot and logs. Keep diagnostics outside the repository.
- Enter provider credentials through Ox's secure UI when needed. The ignored `secrets/API_KEYS.json` is only for local test bootstrap; never request a key in chat or pass it on a command line.

Finish by reporting what worked, the exact remaining blocker if any, and the smallest next action. Do not claim setup is complete based only on dependency installation or a green build.
