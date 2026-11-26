# Conversation and VM operations

For filesystem staging, use `ox.fs.ls` without a path to discover the conversation's working directory, or read the metadata's `workingDirectory`. Do not construct a writable path from the public conversation UUID: the working-directory identifier can differ. `/tmp` is read-only execution output, not a staging destination. Relative ordinary file paths resolve in the current working directory.

Current Ox builds expose app configuration through `ox.fs.read` under `app/`: `settings.json`, `providers.json`, and `services.json` contain editable configuration; `status.json` is generated app and connection state; `policy.json` and `actions/<encodeURIComponent(action)>.json` expose approval policies. Read `app/logs.jsonl` explicitly for approval-gated, redacted diagnostics; directory searches exclude its contents. Prefer `ox profile logs` for scoped CLI diagnostics. App files are unavailable if the Profile already owns an `app` path.

Change app configuration only for an explicit user request. Read the current file first and prefer `ox.fs.edit`; validation, stale-revision checks, filesystem policies, and semantic Action approvals still apply. Provider definitions and `defaultModel` require separate writes; model selection requires an existing exact picker model ID and authentication. Provider removal may clear credentials. Only `settings.json`, `providers.json`, and `services.json` are writable; app files cannot be created, deleted, moved, copied, or attached. Temporary conversations cannot change app configuration. Older Ox builds may not expose this mount; inspect the live function contracts and filesystem before using it.

A saved conversation may be listed before it is hydrated. Current Ox builds load full-UUID conversation reads, sends, stops, and responses without changing the selected conversation. Prefixes resolve only hydrated conversations and can be ambiguous; use full IDs for Client routing. VM commands still require a hydrated conversation. For those commands or older Ox builds, run `ox --conversation <full-id> conversation open`; this selects it and discards an outgoing temporary conversation. For a pending choice or authorized approval, inspect with `ox --conversation <id> conversation inspect --pending --json`, then use `ox --conversation <id> conversation respond <answer> --prompt <prompt-id>`. Use a returned option label or an allowed custom answer; never infer approval. Stale IDs are rejected. Credential entry and app-only interactions remain in Ox. Human interaction through browser.showPage asynchronously waits for Done/Cancel and returns only `status: "completed"` or `status: "cancelled"` in the original execution and turn. Completed is acknowledgment, not verified login or task success. A login interaction can also offer to remember credentials before returning; inspect the live page and pending prompt separately. Older Ox builds without `conversations.open` or `conversations.respond` require the app sidebar and prompt UI; in the idb accessibility tree, `conversation.confirm.Approve` is active while `conversation.confirm.receipt.Approve` records an approval already completed.

Prefer `ox vm call <ox.function> --args <json>` for normal operations. It
preserves Ox's schemas, permissions, approvals, and service attachments.
Use `--args-file -` for sensitive or large arguments. Use `ox vm eval` only
when arbitrary development JavaScript is necessary.

Read a function contract before calling an unfamiliar function:

```sh
ox vm functions --json
ox vm help <ox.function>
```
