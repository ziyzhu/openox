# iOS CI upload and announcement

## Prepare and upload

- On the first CI attempt for a push to `main` that changes iOS inputs, [CI](../../../../.github/workflows/ci.yml) calls [iOS Prepare](../../../../.github/workflows/ios-prepare.yml) alongside validation. CI owns the path filter; bundled agent skills count as shipped content.
- After checks, both native builds, and preparation pass, CI calls [iOS Upload](../../../../.github/workflows/ios-release.yml) with the build number and immutable artifact ID. Only the IPA crosses jobs. Upload verifies its build number, bundle ID, and signature.
- Main CI and manual dispatch share the `ios-upload` concurrency group to serialize build-number selection through upload. Reusable upload calls use a run-specific group to avoid blocking their caller. Manual `dry-run` and `upload` prepare their own IPA. Use `dry-run` for workflow verification; do not upload just to test the workflow.

## TestFlight

CI assigns the uploaded build to `gamma` and does not submit Beta App Review. If App Store Connect marks an external build **Ready to Submit**, submit it manually from **TestFlight → gamma**. A build waiting for review is already submitted. Internal testers do not need Beta App Review.

## Signing and credentials

For archiving, import the existing Apple Development identity from `IOS_SIGNING_P12_BASE64` and `IOS_SIGNING_P12_PASSWORD` in the `appstore` environment into a temporary keychain. Apply cloud-managed distribution signing during export. Reuse the identity; unsigned archives lose capability entitlements during export. Delete the temporary keychain and certificate file on the prepare runner.

The `appstore` environment secret `BUILD_SOURCE_TOKEN` needs Contents and Workflows write permissions. Prefer a token restricted to this repository; reusing a broader CLI token requires explicit operator approval. Only the build-source tagging step uses it. The built-in token can reject tags for older commits whose workflow files differ from current `main`; upload mode checks for the credential before uploading.

The `appstore-announce` environment secret `RELEASE_TAG_TOKEN` needs the same Contents and Workflows write permissions to create `ios-v<version>` tags. Announce mode creates the tag before posting to Discord and deletes it if the post fails, so a failed run never repeats an announcement.
