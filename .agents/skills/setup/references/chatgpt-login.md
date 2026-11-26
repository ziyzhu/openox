# Reuse a simulator ChatGPT login

An explicitly authorized transfer of just the ChatGPT OAuth Keychain entry can
reuse a login without separate sign-in or whole-simulator cloning. Verified between
iOS 26 simulators with Xcode 26.2, including a different destination bundle ID. This
does not establish physical-device or cross-runtime portability.

- Reserve both numbered simulators and preserve their boot state. Use explicit
  `--profile <ws-url>` selectors for all Ox commands. Before copying, read
  `ox vm help ox.provider.list`, then call `ox.provider.list` with a short purpose
  through `ox vm call`. Confirm the source ChatGPT status is `authenticated`;
  provider/model listings alone do not prove login.
- Resolve each installed app's `OXKeychainService` from its Info.plist and its actual
  simulator Keychain access group from build/embedded simulated entitlements. Do not
  hardcode a developer team, bundle ID, or service. Confirm the account key against
  `ChatGPTSubscriptionAccount` and `ManagedOAuthAccount`; currently it is
  `oauth:model-provider:chatgpt:siwc`.
- Use a temporary native helper with Foundation and Security, built for the selected
  simulator architecture and SDK. Query only that service/account with
  `SecItemCopyMatching`. For simulator helpers, embed the matching access-group
  entitlements at link time with `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker
  __entitlements -Xlinker <entitlements.plist>`, then ad-hoc sign normally. Signing
  a standalone helper with device-style entitlements alone failed; the same helper
  with linker-embedded simulated entitlements worked. Do not disable security checks.
- Run separate source/destination helpers with `xcrun simctl spawn <udid> <helper>`.
  Capture the source credential in a local coordinator's process memory and feed it
  directly to the destination's stdin. Never return credential bytes to the agent,
  terminal output, logs, environment variables, command arguments, or plaintext files.
  Keep helpers outside the repository; do not copy or modify Keychain databases.
- Require an absent destination entry, or accept an identical entry without writing.
  Stop on a differing credential; replacement requires separate confirmation. Import
  with `SecItemAdd`, preserve the app's accessibility setting, and read back to verify
  equality without printing values. Do not modify the source entry.
- Restart the destination app with its intended launch environment to clear
  cached signed-out state. Confirm ChatGPT reports `authenticated`; with authorization
  for a real model call, run a bounded `ox conversation send` smoke check. Remove the
  helpers and release reservations afterward. `sim:bootstrap` and template
  `--allow-keychain` do not export a ChatGPT session.

These are copies of one OAuth session, not independent logins. Avoid concurrent use;
refresh-token rotation or revocation may invalidate the other copy. Signing out of
either copy can revoke the shared session. A copied credential is not proof of
working inference, and transfer does not repair unrelated startup/migration failures.
