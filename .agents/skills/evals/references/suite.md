# Ox evals

Evals run real models through the production Pi loop and Ox prompts, with local
stateful `ox.*` stubs. They do not connect to a simulator or live Host. VM and native
bridge behavior is verified independently by integration tests.

```sh
bun run evals --list --suite all
bun run evals --validate --suite all
bun run evals --template --qa-profile EvalQA --output /tmp/ox-fixture.json
bun run evals --fixture /tmp/ox-fixture.json --qa-profile EvalQA --provider openai --model <model-id> --output /tmp/ox-report.json
bun run evals --coverage /tmp/ox-report.json
bun run evals --review /tmp/ox-report.json --case app-profile-success --decision pass --note "Checked the answer against independent fixture state." --output /tmp/ox-reviewed.json
bun run evals compare /tmp/ox-baseline.json /tmp/ox-reviewed.json
```

Providers are `openai`, `anthropic`, and `google`, using their standard API-key
environment variables and installed model catalogs. No credentials are stored in
fixtures. The four smoke cases run once with a 30000 ms limit. Exhaustive suites
are `functions`, `workflows`, and `safety`; select them explicitly. Reports retain
real tool calls, receipts, model usage, independent observations and manual review.
Exit codes are 0 for reviewed passes, 1 for failures/errors, and 2 for unverified,
blocked or incomplete coverage.

A version 1 fixture has `qaProfile` and `cases` keyed by scenario ID. Each binding
contains `context`, read-only `observations`, phased `assertions`, expected `actions`,
`allowedActions`, and any `cleanup` or independent `probeContext`. Assertions use
`equals`, `includes`, `unchanged`, or `absent` over observed JSON paths. Outcome and
preservation evidence must come from observers, not model claims. Function receipts
must match expected arguments and success/failure counts. Fresh probes see only
variable inputs, never the expected answer. Generated IDs use existing `$receipt`
references. The template prepares smoke cases; other scenarios require meaningful
fixture preparation and never pass merely because they appear in the catalog.

Bindings optionally contain `stubs`:

```json
{
  "state": {"theme": {"selection": "light", "appearance": "light"}},
  "files": {"notes.txt": "Existing content"},
  "denied": ["ox.secret.delete"],
  "functions": {
    "ox.app.theme": [{"result": {"$state": "theme"}}],
    "ox.app.setTheme": [{
      "args": {"selection": "dark"},
      "when": {"theme": {"selection": "light", "appearance": "light"}},
      "result": {"selection": "dark", "appearance": "dark", "changed": true},
      "set": {"theme": {"selection": "dark", "appearance": "dark"}}
    }]
  }
}
```

Rules match argument subsets and current state. `$arg` and `$state` references
resolve values without executing fixture code. `set` applies atomically after
validating the result. An `error` contains `code`, `message`, and `recovery` and
never applies mutations. No matching rule fails explicitly. All built-in functions use
real input/output contracts; synchronous `ox.provider.schema()` returns the native
provider-document schema and records an inspection receipt. Fixtures must prepare behavior beyond the default
Profile/provider/repository/schedule readers and in-memory filesystem. Human choices
are explicit fixture results for `ox.user.choose`, not real approvals. Browser,
payment, service, and media results are simulated observations, not evidence of
platform rendering or external success.

Independent observers read the same state without creating task receipts. Each
case/repetition starts from a fresh copy; task, probe and cleanup share that copy.
The real filesystem handles text reads, edits, search and errors; the in-memory
backend provides working-file state. System skill files come from the actual bundled
packages. Missing fixture coverage remains an explicit limit.

Run `bun run test:vm --device ox-N --host <ws-url>` on a fresh QA build to compare
`vm functions` with `packages/agent/evals/contracts.json` and exercise the real VM.
Update that snapshot from the native catalog only for reviewed contract changes.
The runner uses a new QA Profile, exercises temporary and saved conversations,
restores the previous Profile, and retains evidence outside Git. It requires the
normal QA simulator preparation and uses Mock without model inference.
