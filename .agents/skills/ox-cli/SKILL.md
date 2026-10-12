---
name: ox-cli
description: Use the terminal as an Ox Client. Connect to an Ox Host; discover, drive, inspect, or watch conversations; list model providers; read structured logs; inspect or call a VM; administer Profiles; inspect or verify service repositories; and invoke live services.
---

# Ox CLI

`ox` is an Ox Client for the terminal. Consult `ox --help` and the relevant
command help before guessing flags.

Commands are grouped by the resource they act on, and each group has one
selector flag:

- `ox profile` with `--host <ws-url>`: Profiles owned by that Host; `--profile <id>` scopes inspection or updates. Without `--host`, `--profile <path>` selects a directory for read-only disk inspection.
- `ox repository` with `--repository <path-or-url>`: a service repository.
- `ox host` with `--host <ws-url>`: an Ox Host.
- `ox conversation` and `ox vm` with `--host` and `--conversation <conversation-id>`: a conversation on that
  Host and its VM.

Do not select or infer a web-page runtime. The Host owns service adapters and
decides how live service pages are implemented and managed. Do not use service
or tab session IDs; a live service is addressed by its domain.

## Choose the correct surface

- Use `ox host list` to find reachable simulator Hosts and online iOS Tailscale peers; use `--all` to include unavailable candidates.
- Use `ox host logs`, `ox host providers`, and `ox host describe` for Host introspection.
- For agent-loop diagnostics, filter logs by `AgentLatency.summary`, `AgentModel.end`, or `AgentCall.`. Correlate `conversation`, `submission`, and `turn`; `tools` counts model-tool executions, while `functions` counts nested `ox.*` invocations. Token totals cover reported model usage, including compaction; check `usageComplete`, `missingUsage`, and `unfinishedCalls` before treating a summary as complete. All-zero provider usage is conservatively reported as unknown, not measured zero.
- Use `ox conversation` to create, open, drive, respond to, stop, inspect, and watch conversations; `ox conversation send`
  runs the real conversation turn, including tools, services, and compaction.
- Use `ox vm` for VM functions, VM-visible skills, and execution through the
  agent's actual capability boundary.
- Use `ox profile` for direct Profile file reads.
- Use `ox repository` for offline repository, service manifest, action, and
  skill inspection.
- Use `ox host services` and `ox host service` for live service operations.
- Skills come from three sources: `ox profile skills` (a Profile's files),
  `ox repository skills` (a repository's files), and `ox vm skills` (what the
  agent in a conversation actually sees).
- Use `idb` with the `ios-simulator` skill to verify conversation projection changes; the repository has no dedicated conversation projection fixture command.
- Use the agent-independent `ios-simulator` skill and native tools for iOS Simulator interaction.

## Connect to a Host and VM

Target the default DEBUG iOS Simulator Host with `ox vm`. Pass
`--host <ws-url>` or set `OX_HOST_ENDPOINT` for another Host.

```sh
ox conversation list
ox conversation inspect
ox host logs --level warning
ox host logs --all --level warning --grep timeout
ox host logs --page --limit 100 --json
ox host logs --cursor '<nextCursor>' --limit 100 --json
ox vm inspect
ox vm functions
ox vm help ox.fs.read
ox vm skills
ox vm skills <name>
```

Use `--conversation <conversation-id>` when the active conversation is not the intended VM:

```sh
ox --conversation <conversation-id> conversation inspect
ox --conversation <conversation-id> vm inspect
ox --conversation <conversation-id> vm call ox.fs.read --args '<json>'
```

A saved conversation may be listed before it is hydrated. Current Hosts load full-UUID conversation reads, sends, stops, and responses without changing the selected chat. Prefixes resolve only hydrated conversations and can be ambiguous; use full IDs for Client routing. VM commands still require a hydrated conversation. For those commands or older Hosts, run `ox --conversation <full-id> conversation open`; this selects it and discards an outgoing temporary conversation. For a pending choice or authorized approval, inspect with `ox --conversation <id> conversation inspect --pending --json`, then use `ox --conversation <id> conversation respond <answer> --prompt <prompt-id>`. Use a returned option label or an allowed custom answer; never infer approval. Stale IDs are rejected. Credential entry and app-only interactions remain in Ox. Older Hosts without `conversations.open` or `conversations.respond` require the app sidebar and prompt UI; in the idb accessibility tree, `conversation.confirm.Approve` is active while `conversation.confirm.receipt.Approve` records an approval already completed.

First-time `ox.service.attach` from an idle conversation can return a stopped outcome because interactive prompts require an active agent run. Inspect the app and logs before retrying; do not treat this as proof the user declined. For an authorized development task, attach through the app's Services picker, then use `ox.service.attach` to reload validated Local edits. Preserve genuine declined or blocked decisions.

Prefer `ox vm call <ox.function> --args <json>` for normal operations. It
preserves the Host's schemas, permissions, approvals, and service attachments.
Use `--args-file -` for sensitive or large arguments. Use `ox vm eval` only
when arbitrary development JavaScript is necessary.

Read a function contract before calling an unfamiliar function:

```sh
ox vm functions --json
ox vm help <ox.function>
```

## Delegate service authoring to Ox

Use the `develop-services` skill for the service evolution and developer-feedback loop.
Drive an Ox conversation on the user-selected simulator through the built-in
`skills/evolve/SKILL.md` System skill for service exploration, authoring, repair, and live
verification. While observing the run, use conversation history and structured logs to
identify friction, repeated failures, and missing capabilities. Fix the underlying
harness issues and improve tools, instructions, diagnostics, or verification
where the evidence supports a reusable improvement. Exercise the affected flow
through Ox again so future authoring is faster and more reliable. Keep service
behavior authored inside Ox.

## Administer a Profile

Manage Profiles through their owning Host:

```sh
ox --host <ws-url> profile list --json
ox --host <ws-url> profile create --name <name> --json
ox --host <ws-url> profile select <id>
ox --host <ws-url> profile inspect <id> --json
ox --host <ws-url> profile rename <id> --name <name>
ox --host <ws-url> --profile <id> profile update --memory-file <path> --soul-file <path>
```

Create does not select the new Profile. Selection and updates reject running conversations; stop them explicitly first. Name, memory, and soul updates use existing Host persistence, not replacement of `profile.json`. Inspect after a failed update before retrying, because earlier writes may have succeeded.

For offline inspection, discover iCloud Profiles on macOS and select one by directory:

```sh
ox profile list [--json]
ox --profile <path> profile memory
ox --profile <path> profile soul
ox --profile <path> profile skills [name] [--json]
ox --profile <path> profile artifacts [filename] [--json]
ox --profile <path> profile conversations [id] [--json]
```

Profile inspection is read-only. Reading iCloud Drive may require Files & Folders
permission for the terminal or agent host.

## Inspect service repositories

```sh
ox --repository <path-or-url> repository inspect
ox --repository <path-or-url> repository validate
ox --repository <git-url> repository verify
ox --repository <path-or-url> repository serve [--port 8100]
ox --repository <path-or-url> repository services [domain] [--json]
ox --repository <path-or-url> repository actions <domain> [--json]
ox --repository <path-or-url> repository skills [name] [--json]
```

Inspect an action's input schema, authentication requirement, and approval
requirement before invoking it.

## Connect a repository through Files

```sh
ox --host <ws-url> host files mount --timeout 120000
ox --host <ws-url> host files list --json
ox --host <ws-url> host repository connect files/<grant-id>[/subfolder]
ox --host <ws-url> host repository list --json
ox --host <ws-url> host service sync
ox --host <ws-url> host repository disconnect <repository-id>
ox --host <ws-url> host files unmount <grant-id>
```

The Host's native picker grants access; a CLI-local path cannot authorize remote access. Connection is explicit and persistent, separate from managed Local. Source must use the current repository version; it is read in place without migration or Git seeding. Edit through the granted Files mount or your editor, not the read-only mounted services view. Revocation makes connected services unavailable; disconnect does not delete their files. Grant IDs are stable for one grant and never reused for a new authorization. Mounts belong to the selected Profile; `--profile <id>` scopes `host files` commands without switching. Existing grants appear as unassigned until `host files assign <id>` or explicit assignment in Profile → Files. No Files service attachment is required. Mounted services follow the grant's Profile. Older builds do not enforce ownership and can discard ownership fields on writes; downgrade requires review.

## Exercise live services through a Host

```sh
ox [--host <ws-url>] host services [--json] [--timeout 30000]
ox [--host <ws-url>] host service invoke <domain>:<action> --args '<json>' [--approve] [--timeout 30000]
ox [--host <ws-url>] host service eval <domain> --script '<javascript>' [--timeout 30000]
ox [--host <ws-url>] host service reload <domain> [--timeout 30000]
ox [--host <ws-url>] host service refresh-auth <domain> [--timeout 30000]
ox [--host <ws-url>] host service sync [--timeout 60000]
```

Treat `invoke` as a real action that may read authenticated data or mutate
external state. Supply `--approve` only when the user's request authorizes the
effect. Treat `host service eval` as arbitrary code on a Host-managed service page
and keep it narrowly scoped.

Native iOS actions also require their service to be attached to the selected
conversation. A catalog search result alone is insufficient. Attach through the app's
Services picker or the authorized conversation workflow before invoking
`ios:<service>:<action>`; an unattached native service may report an unknown
action even when it appears in the catalog.

Sign-in, human verification, page creation, and page lifecycle happen through
the Host's interface. Do not attempt to choose a page engine, tab, or another
implementation from the Client.

## Diagnose live connection failures

1. Confirm the Host is running.
2. Run `ox vm inspect` or `ox host services` as the smallest probe.
3. Check `--host`, `OX_HOST_ENDPOINT`, then the compatibility
   `OX_DEBUG_ENDPOINT`.
4. Run `ox host logs --level warning` before widening to device logs.

Report the exact command, Host endpoint selection method, target resource, and
relevant failure text when blocked. Never print credentials or repository URLs
containing credentials.
