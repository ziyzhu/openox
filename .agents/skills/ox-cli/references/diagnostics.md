# Diagnostics

- To debug behavior from logs, start with `ox profile logs --summary --since <time>`: it counts rows by level, category, and event (the first message token, such as `Conversation.runOne`), errors first, with each group's last time. Then scope with `ox --conversation <full-id> conversation logs`, which keeps rows mentioning that conversation id, and narrow with `--level warning`, `--category`, or `--json`. Times are UTC. Turn-scoped lines carry `conversation=`, `submission=`, and `turn=`; `durable=` is the Pi Durable integer id, not a conversation id. Conversation logs cannot also take `--grep`; filter their `--json` output.
- For agent-loop diagnostics, filter logs by `AgentLatency.summary`, `AgentModel.end`, or `AgentCall.`. Correlate `conversation`, `submission`, and `turn`; `tools` counts model-tool executions, while `functions` counts nested `ox.*` invocations. For browser efficiency, compare `totalMs`, `modelRoundTrips` (excluding compaction), `browserCalls`, and `browserResultBytes` (successful serialized invocation results, not model-visible bytes). Browser call counts include failed and unfinished calls; result bytes do not. `handoffMs` is user time in login, verification, and other handoffs; subtract it from `totalMs` and `toolWallMs` before judging agent speed. These metrics do not verify task completion. Token totals cover reported model usage, including compaction; check `usageComplete`, `missingUsage`, and `unfinishedCalls` before treating a summary as complete. All-zero provider usage is conservatively reported as unknown, not measured zero.

Use the CLI paging flags to inspect a bounded log window:

```sh
ox --profile "$ENDPOINT" profile logs --all --level warning --grep timeout
ox --profile "$ENDPOINT" profile logs --page --limit 100 --json
ox --profile "$ENDPOINT" profile logs --cursor '<nextCursor>' --limit 100 --json
```

## Diagnose live connection failures

1. Confirm Ox is running and Allow Connections is on.
2. Run `ox vm inspect` or `ox service list` as the smallest probe.
3. Check `--profile`, `OX_PROFILE_ENDPOINT`, then the compatibility
   `OX_DEBUG_ENDPOINT`.
4. Run `ox profile logs --level warning` before widening to device logs.

A dispatcher-unavailable error does not establish a broken service implementation.
Inspect `service list` navigation state and `Service.navigation` logs first; a
terminated web process can leave a resident page unavailable. Verify recovery with
a new read-only invocation, never by automatically replaying an interrupted write.
Use `ox.repository.conflicts` to distinguish Local overrides from Built-in sources.

Report the exact command, Profile endpoint selection method, target resource, and
relevant failure text when blocked. Never print credentials or repository URLs
containing credentials.
