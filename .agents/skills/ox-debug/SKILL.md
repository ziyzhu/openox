---
name: ox-debug
description: Replay committed Ox conversation fixtures through the running app's projection reducer and compare golden snapshots. Use only for reducer fixture verification or intentional golden updates. Use the ox-cli skill for Host, chat, log, agent, VM, service, Profile, and repository operations.
---

# Ox Debug

Repository-owned projection reducer verification through the running DEBUG iOS app. Run from the Ox repository root with `bun run debug`; consult command help before guessing flags.

Use the Ox CLI for every general Host-client operation:

- Use `ox chat` for live chat discovery, inspection, and watching.
- Use `ox logs` and `ox agent` for runtime introspection.
- Use `ox vm` for structured `ox.*` calls, VM-visible skills, and VM JavaScript evaluation.
- Use `ox repository verify` for Server IR conformance.
- Use `sim` for every iOS Simulator interaction.
- Use `bun run debug` only for projection reducer fixture replay.

Replay the committed conversation corpus through Ox's projection reducer:

```sh
bun run debug reducer replay [--fixtures ios/fixtures/chatlogs] [--update] [--json] [--timeout 30000]
```

`reducer replay` loads `*.input.json` ChatDocument turns from the host, runs the app's typed projection, and compares `*.golden.json`. Use `--update` only when intentionally accepting a reviewed projection change.

## Live connection workflow

Reducer replay requires a running DEBUG app and its Host WebSocket. On connection failure:

1. Confirm the app is running with `sim`, without touching the human-reserved `ox-qa` device.
2. Run `ox chat list` as the smallest connectivity probe.
3. Check `OX_HOST_ENDPOINT`, then the compatibility `OX_DEBUG_ENDPOINT`.
4. Inspect `ox logs --level warning` before widening to device logs.

Report the fixture directory, exact command, Host endpoint selection method, and relevant failure text when blocked.
