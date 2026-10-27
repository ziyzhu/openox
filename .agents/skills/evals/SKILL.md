---
name: evals
description: Run the real-provider eval suite with production Ox prompts and agent loop, private API keys, explicit provider/model selections and basic prompting checks. Report native-provider adapter gaps explicitly.
---

# Ox evals

Evals are one of the three maintained suites, alongside protocol validation and
storage backward compatibility. Read [the runner guide](references/suite.md) before
running or changing cases. Build owns offline case/catalog validation.

Use real models with production prompts and the production Pi agent loop. Stub
`ox.*` observations and effects, never model replies. The default baseline covers
basic instruction following, a Profile tool call, and a file read grounded in a tool
result. Existing specialized cases are opt-in, not additional required suites.

Use the existing ignored `secrets/API_KEYS.json`, not a second key file. Preserve
its nested provider/region format, for example `ark.china`; never overwrite existing
keys. [API_KEYS.example.json](API_KEYS.example.json) contains empty examples only.
The current direct runner maps `openai`, `anthropic`, and `gemini` to standard API-key
environment variables; existing environment values win. Other entries are preserved
but cannot establish provider coverage without the matching runtime adapter. Keep
file permissions private (`chmod 600 secrets/API_KEYS.json`). Never commit, print,
copy into cases, or include keys in reports or command arguments.

Run `bun run evals --providers` to inventory every bundled provider and adapter gaps.
The portable runtime currently supports only `openai`, `anthropic`, and `google`
(the last corresponds to Ox's `gemini`). It does not exercise the native provider
authentication, OAuth, discovery or transport adapters. Never claim every Ox
provider works from these three direct-provider results. Missing adapters, credentials
or model selections are blocked coverage, not passes or silent exclusions.

Real inference requires explicit user authorization and `--authorize-spend`. Select
provider/model identities explicitly, either individually or via `--matrix <json>`.
Default concurrency is one; bound repetitions and timeouts. Do not run a full-provider
matrix without approval for its scope and cost. OAuth uses OpenOx-registered apps;
API keys do not prove subscription/OAuth support.

Check actual receipts, resulting stub state and answers, not the model's claims.
Keep stubs contract-valid and unconfigured calls explicit. Model JavaScript executes
in a bounded realm without provider keys, filesystem or network access. No personal
Profile, simulator or live Host is used. A low score is a behavioral failure; provider
and harness errors are distinct. Both produce nonzero exit status for required runs.
Reports remain outside Git and redact loaded API-key values.

After edits run `bun run evals --validate`, `bun run build:check`, and
`bun run test:protocol`. When prompts change, target the changed behavior and compare
with `--baseline <ref>` using identical models, cases, limits and enough repetitions
to expose flakiness. Do not claim statistical improvement from one run.
