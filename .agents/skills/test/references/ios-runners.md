# iOS runner coverage and preparation

Use runner `--help` for arguments and [iOS verification](ios.md) for shared requirements.
Executable assertions define the detailed cases; this guide records preparation and cleanup.

## Bundled skills

Checks bundled skill discovery, content, and mutation boundaries. Seed a saved Mock
conversation with `QA bundled skill verification seed. Reply QA only.`, then create
an empty temporary conversation and inspect its prepared ID. Open the saved conversation
first so both remain hydrated. For ordinary delete approval, leave the Profile's Skills
screen open and use `--ui-cleanup` to remove the run-owned copy.

## Settings

Checks preferences, model selection, repository enablement, and persistence across
relaunch. Requires a reachable Host, an idle saved conversation, and the supplied app.
Restores preferences and the prior saved conversation.

## Service icons

Checks native service icon loading. Attach a run-owned MCP fixture at
`http://127.0.0.1:<registryPort>/mcp-favicon-qa` and launch with the matching
`OX_SERVICES_ENDPOINT`. Restores the saved favicon URL; remove the connection through
the UI afterward. `--live` additionally exercises public HTTPS endpoints.

## Model selection

`durable-conversation.ts --models` checks queued-turn model selection and defaults
through native Mock without Host ingress. Requires automatic or Mock defaults and
restores the original default and launch environment. Persisted-conversation model
reload requires the Host-based suite.

## Structured errors

Checks live VM error contracts. Requires an idle QA conversation and a fresh installed
build; does not change files, settings, policies, or conversation selection.

## Browser sites

Checks per-site Browser approval for page scripts, PDF export, injected-script domains,
and captured bodies. Requires a saved idle Mock conversation, public HTTPS, and
`example.com`/`example.org` site policies at Ask. Prompts outside an agent run are
cancelled, so the runner drives Mock `execute` turns and answers only Approve or Deny.
Verify Always allow and its Settings → Permissions → Web & browser row manually.

## Image embed

Checks remote Markdown image display, viewer interaction, retry, and reopen. Requires a saved Mock conversation
seeded with `0` and the assigned loopback Host. Use the prepared saved ID from
`conversation inspect`. Retains fixtures and the conversation for human review;
remove them through the UI afterward.

## Profile files

Checks Profile filesystem behavior and reopen. Seed a saved Mock conversation with
`QA filesystem backend verification seed.` The runner creates/deletes run-owned
fixtures through ordinary approval. `--profile-folder` also exercises external folder
changes, Memory, and user skill resources; original Memory bytes are restored.
This does not establish upgrade compatibility or physical-device power-loss safety.

## Manual file picker

Verify Profile Settings → Files navigation, viewers, and Profile boundary enforcement.
Observe the selected file opening in its viewer; picker dismissal alone is insufficient.
Use explicit `/`-prefixed Profile paths. Folder browsing does not establish Files search indexing.

## Demo previews

Checks native preview presentation and unchanged Profile/repository state.
Use `demo` for capture workflows; preview checks do not exercise live integrations.
