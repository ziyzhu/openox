# iOS App Store releases in GitHub

Status: proposed; no automation or infrastructure configured.

## Goal

Create a Git tag and stable GitHub Release when an Ox iOS version is released on the App Store. Xcode Cloud build completion, TestFlight distribution, and App Review approval must not publish a stable GitHub Release.

Use `ios-v<version>` tags, such as `ios-v1.0.18`, and release titles such as `Ox iOS 1.0.18 (42)`. Tags must identify the exact commit used by the shipped build, not the current tip of `main`. Keep iOS naming separate from existing CLI and package release tags.

## Trigger and flow

1. Register an App Store Connect webhook for app `6802224502`, subscribing to `APP_STORE_VERSION_APP_VERSION_STATE_UPDATED`.
2. Apple sends an `appStoreVersionAppVersionStateUpdated` event to a public HTTPS receiver when the app version changes state.
3. Verify the `x-apple-signature` HMAC-SHA256 signature against the raw request body using the configured shared secret. Ignore unrelated events and transitions other than `READY_FOR_DISTRIBUTION`.
4. Dispatch a dedicated GitHub Actions workflow using `repository_dispatch`, carrying the event and App Store version identifiers.
5. The workflow reads App Store Connect to confirm the app, iOS platform, released version state, and selected build. Treat webhook input as a notification to verify, not publication authority by itself.
6. Resolve the selected build to its Xcode Cloud build run and exact source SHA. Verify the commit belongs to this repository and is on `main`.
7. Create the version tag and stable GitHub Release with the version, build number, source SHA, Xcode Cloud build link, App Store link, and change notes since the previous iOS release.

`READY_FOR_DISTRIBUTION` records Apple's release-status transition. It does not guarantee immediate propagation to every storefront or completion of a phased rollout. Do not wait for every user to receive an automatic update.

## Ownership and security

- Put the public webhook receiver and its infrastructure in `openox-dev`.
- Put the publication workflow in this repository at `.github/workflows/release-ios.yml`.
- Apple cannot call GitHub Actions directly using its native webhook authentication and payload; the receiver bridges the two APIs.
- Keep webhook secrets, GitHub dispatch credentials, and App Store Connect credentials outside Git. Use narrowly scoped credentials; grant the publishing workflow `contents: write` only where required.
- Retain structured diagnostics for event ID, version ID, build ID, source SHA, workflow run, publication outcome, and sanitized failures. Never log credentials or authorization headers.
- Do not modify App Review submission or App Store release controls. This automation reflects a release that already happened.

## Reliability

- Make duplicate and concurrent deliveries safe. An existing tag and release with matching source/version/build are a no-op; conflicting targets fail without moving tags or overwriting a different release.
- Allow retries to finish a partial publication, such as a tag created before GitHub Release creation failed. Serialize publication for the same iOS version.
- Acknowledge a relevant webhook only after its dispatch is durably accepted. Surface dispatch and workflow failures so they can be retried or reconciled.
- Provide a manual workflow invocation accepting an App Store version ID for recovery. Apply the same live-state, build, and commit checks; do not allow arbitrary tag targets.
- Fail closed when build-to-commit provenance is unavailable. Never infer the commit from version strings, timestamps, or the current branch tip.

## Implementation gates

1. Verify the released App Store build can be resolved through App Store Connect/Xcode Cloud APIs to its source SHA. If unavailable, agree on a minimal durable build-to-commit mapping before implementation; a build-time mapping must not itself publish a release.
2. Confirm live webhook state values, API access roles, signature handling, and delivery/retry behavior against current Apple documentation.
3. Implement and deploy the receiver in `openox-dev`, then add the publication workflow here. Configure secrets outside both repositories and register the webhook only after the receiver is ready.
4. Verify real webhook delivery with Apple's webhook test facility. Exercise signature rejection, unrelated/review states, duplicate events, API/dispatch failures, missing provenance, conflicting tags, and partial-publication recovery through E2E checks without publishing a fake production release.
5. Observe the next authorized App Store release end to end: confirm the stable tag targets the shipped source SHA and the GitHub Release records the correct version/build. Replay the event to verify idempotency.

## References

- [Apple webhook configuration and signature verification](https://developer.apple.com/documentation/appstoreconnectapi/configuring-webhook-notifications)
- [Apple webhook events](https://developer.apple.com/documentation/appstoreconnectapi/webhook-events)
