# Repository helpers

Use [`scripts/ci.sh`](../scripts/ci.sh) for portable local/GitHub verification and
[`scripts/ios-ci.sh`](../scripts/ios-ci.sh) for explicit local iOS checks. The
verification contract and CI/local division live in [`tests/README.md`](../tests/README.md).

```text
tools/
├── checks/     Repository/static checks and typecheck orchestration
├── build/      Schema generators, provider catalog maintenance, service bundle
├── qa/         Local simulator setup, iOS smoke, conversation and demo helpers
├── release/    npm publication (release-only, not verification)
├── lib.ts      Subprocess and generated-file helpers
└── tsconfig.json
```

## Maintenance

Run from the repository root after `bun install`:

| Command | Purpose |
| --- | --- |
| `bun run typecheck` | Static checks and typecheck seven projects, including tests. |
| `bun run build:host-schema` | Regenerate Host RPC JSON/Swift artifacts. |
| `bun run build:repository-schema` | Regenerate repository JSON/Swift artifacts. |
| `bun run build:provider-schema` | Regenerate model-provider schema. |
| `bun run build:services` | Rebuild bundled services, Local Git seed, and model-action resources. |
| `bun run update:llms` | Refresh already-selected models from models.dev; requires network access. |
| `bun run sim:bootstrap --help` | Explicit local credential/artifact/website-state setup. |

Individual validation aliases were removed; the checks run through `typecheck`
and `ci.sh`. Invoke an individual implementation directly only when debugging.
Generated-file helpers resolve paths against the repository root.

`qa/simulator.ts` shares device/runtime validation and PID claims between local
runners. Claims do not replace coordination with other agents. Follow simulator
ownership and baseline rules in [`AGENTS.md`](../AGENTS.md).

`release/npm-publish.ts` validates and publishes a supplied tarball. Its `--dry-run`
still queries npm. It is invoked by the authorized release workflow, never by CI
verification. Keep screenshots, traces, credentials, and diagnostics outside the
repository.
