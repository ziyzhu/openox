---
name: build
description: Build bundled OpenOx services, regenerate protocol/provider schemas, refresh selected provider models, and run repository static checks and TypeScript validation. Use for generated-artifact maintenance or build/check failures; verification belongs to test and publication to release.
---

# Build

Run from the repository root after `bun install`. Executable maintenance helpers
live in `scripts/`; shared subprocess and generated-file helpers live in
`../../lib.ts`. They resolve repository paths independently of the caller's directory.

## Commands

| Command | Purpose |
| --- | --- |
| `bun run typecheck` | Static checks and five TypeScript projects, including all desktop skill code. |
| `bun run build:host-schema` | Regenerate Host RPC JSON/Swift artifacts. |
| `bun run build:repository-schema` | Regenerate repository JSON/Swift artifacts. |
| `bun run build:provider-schema` | Regenerate provider definitions schema. |
| `bun run build:services` | Rebuild bundled services, Local Git seed, and model-action resources. |
| `bun run update:llms` | Refresh already-selected models from models.dev; requires network access. |

`typecheck` validates public/private-content boundaries, iOS Client-Host layering,
protocol schema consistency, bundled system skills, translations, provider models,
and provider definitions before checking TypeScript. `.agents/tsconfig.json`
includes test, eval, Gym, demo, setup, build, and release code.

## Maintain generated sources

Change the owning source, regenerate with its public command, and review the
focused output diff. Do not change contract schemas merely to make checks pass;
service manifest changes require maintainer approval. Provider selection changes
follow the `providers` skill rather than a second catalog-management workflow.

`apps/ios/Ox/Resources/OxServices.bundle/` is the single built-in repository source.
`build:services` validates it, refreshes its content hash without rewriting service
files, and creates a deterministic Local Git seed and model-action resources.
Package builds copy this source; hosted icon artwork lives in `assets/services/`.
It is a build operation, not live service verification.
Do not overwrite unrelated repository or generated changes.

Run `bun run ci` through the `test` skill after maintenance. Simulator provisioning
belongs to `onboarding`; real-model behavior belongs to `evals`; publication belongs
to `release`. Individual check implementations may be invoked directly for debugging.
Keep screenshots, traces, credentials, and diagnostics outside the repository.
