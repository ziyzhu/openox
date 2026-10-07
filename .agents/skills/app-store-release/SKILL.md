---
name: app-store-release
description: Prepare Ox iOS App Store releases with asc, including What's New in This Version, approved staging, and manual App Review handoff. App Store Connect is the source of truth for listing metadata and media. Not for TestFlight-only distribution or npm releases.
---

# App Store Release

Run from the selected OpenOx checkout on `main` and follow its `AGENTS.md`. Use the installed `asc-cli` skill for App Store Connect operations and [demo](../demo/SKILL.md) for screenshots or video capture when requested. The app ID is `6802224502`.

## Promotional text

Current English promotional text, supplied by the operator:

> Connect anything, local, yours.

Preserve it unless a change is explicitly requested. This documents the intended copy, not a live App Store Connect verification. Do not automatically translate it or reuse it as release notes.

## Source of truth

[App Store Connect](https://appstoreconnect.apple.com/) owns the current listing metadata, screenshots, and previews. Read its current state during a release; do not keep local metadata copies, media libraries, or inventory manifests in either repository. Keep drafts, captures, downloads, validation output, and any CLI input files in a private temporary workspace outside the repositories. Credentials, signing material, review contacts, and demo access also stay outside Git.

## Release flow

Follow [references/release-flow.md](references/release-flow.md), including **What's New in This Version** for each release. Preserve other metadata and media unless their changes are requested and approved. Remote writes need explicit approval; App Review submission is always manual.
