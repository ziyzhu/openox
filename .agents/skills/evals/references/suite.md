# Ox evals

Evals run real models through the production Pi loop and Ox prompts, with local
stateful `ox.*` stubs. They do not connect to a simulator or live Host. VM and native
bridge behavior is verified independently by integration tests.

```sh
bun run evals --list
bun run evals --validate
bun run evals --provider anthropic --model <model-id>
bun run evals --provider openai --model <model-id> --case proceed-without-asking --repeat 5
```

Providers are `openai`, `anthropic`, and `google`, using their standard API-key
environment variables and installed model catalogs. Each case runs once by default
with its own `timeoutMs` or 120000 ms. `--jobs` sets concurrency (default 4).

Each invocation writes a new directory (temporary by default, `--output` must be
outside the repository) containing `report.json`, `report.txt`, and `runs/*.json`
with each run's system prompt, messages, `ox.*` calls and checks. The summary lists
pass counts per case and flags errored and flaky cases. Any errored run withholds
the headline pass rate and exits 1; failing checks are results and exit 0. One
repetition cannot establish stability.

A case is `cases/<id>.ts` default-exporting an `EvalCase`:

```ts
import { called, mentions } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Which Profile am I using, and where is it stored?",
  stubs: { state: { profile: { name: "EvalQA", storage: "local" } } },
  attached: [],
  timeoutMs: 120_000,
  checks: run => [called(run, "ox.app.profile"), mentions(run, "EvalQA")],
} satisfies EvalCase;
```

`checks` receives the turn status, system prompt, messages, recorded `calls`
(name, args, result or error), the final `answer`, the final stub `state`, and
`read(path)` for resulting file contents. A run passes when it finishes in time and
every check passes. Provider or runner failures are errors, not failures.

Stubs:

```json
{
  "state": {"language": {"selection": "en", "locale": "en"}},
  "files": {"notes.txt": "Existing content"},
  "denied": ["ox.secret.delete"],
  "functions": {
    "ox.app.language": [{"result": {"$state": "language"}}],
    "ox.app.setLanguage": [{
      "args": {"selection": "zh-Hans"},
      "when": {"language": {"selection": "en", "locale": "en"}},
      "result": {"selection": "zh-Hans", "locale": "zh-Hans", "changed": true},
      "set": {"language": {"selection": "zh-Hans", "locale": "zh-Hans"}}
    }]
  }
}
```

Rules match argument subsets and current state. `$arg` and `$state` references
resolve values without executing case code. `set` applies atomically after
validating the result. An `error` contains `code`, `message`, and `recovery` and
never applies mutations. No matching rule fails explicitly. Profile, providers,
repositories and schedules have default readers; the Profile is `EvalQA`. File
operations use the production filesystem logic over in-memory storage seeded from
`files`, and System skill files come from the actual bundled packages. Human choices
are explicit stub results for `ox.user.choose`. Browser, payment, service, and media
results are simulated observations, not evidence of platform rendering or external
success. Each run starts from a fresh runtime and stub copy.

Run `bun run test:vm --device ox-N --host <ws-url>` on a fresh QA build to compare
`vm functions` with the per-namespace `packages/agent/src/functions/*/contracts.json` files and exercise the real VM.
Update that snapshot from the native catalog only for reviewed contract changes.
The runner uses a new QA Profile, exercises temporary and saved conversations,
restores the previous Profile, and retains evidence outside Git. It requires the
normal QA simulator preparation and uses Mock without model inference.
