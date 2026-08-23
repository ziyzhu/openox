---
name: ox-debug
description: Debug the running Ox iOS app through its debug WebSocket. Use when inspecting chats or structured logs; evaluating agent virtual-machine JavaScript; running or replaying LLM agents in isolation; or verifying that a git URL conforms to the Ox Server IR.
---

# Ox Debug

Live introspection of the running DEBUG iOS app over its debug WebSocket, plus Server IR conformance checks. Run from the Ox repository root with `bun run debug`; consult `bun run debug --help` and the relevant subcommand help before guessing flags.

Keep adjacent surfaces on their intended tools:

- Use `ox` for service manifests, actions, skills, and live service invocation.
- Use `sim` for every iOS Simulator interaction.
- Use `bun run debug` for chat, log, agent, virtual-machine, and Server IR operations.

## Inspect the running app

```sh
bun run debug dev list-chats [--json] [--timeout 30000]
bun run debug dev chat [<id>] [--system|--tools|--messages|--blocks] [--full] [--json] [--timeout 30000]
bun run debug dev logs [--level debug|info|warning|error] [--grep <substring>] [--json] [--timeout 30000]
bun run debug dev transcript [--json] [--timeout 30000]
bun run debug dev performance [--json] [--timeout 30000]
bun run debug dev virtual-machine-eval [--chat <id>] --script '<javascript>' [--timeout 60000]
```

Replay the committed conversation corpus through Ox's projection reducer:

```sh
bun run debug reducer replay [--fixtures ios/fixtures/chatlogs] [--update] [--json] [--timeout 30000]
```

Start with the compact human output. Add `--json` for machine processing and `--full` only when complete tool schemas, messages, or blocks are needed. `dev logs` reads Ox's structured in-memory buffer; use `sim logs` only for device-level logs.
Use `dev transcript` for the active scroller's frame, ownership, hold, position, and recent geometry history.

Treat `virtual-machine-eval` as arbitrary code in the chat's agent JavaScript context. Use it only when the task needs the bound `ox` namespace and keep the script minimal.

`reducer replay` loads `*.input.json` ChatDocument turns from the host, runs the app's typed projection, and compares `*.golden.json`. Use `--update` only when intentionally accepting a reviewed projection change.

## Run agents headlessly

```sh
bun run debug agent list [--json] [--timeout 30000]
bun run debug agent run [<chat>] --prompt '<prompt>' [--client <id>] [--model <id>] [--json] [--timeout 120000]
bun run debug agent replay [<chat>] [--client <id>] [--model <id>] [--json] [--timeout 120000]
```

Use `run` for a new prompt. Without a chat it is a fresh turn; with a chat it seeds that chat's system prompt, history, and tools without mutating the session. Use `replay` to reproduce the existing chat exactly without appending a prompt. List agents first when provider or model selection matters.

## Verify a server

```sh
bun run debug spec verify <git-url>
```

Use this for Server IR conformance (WHITE_PAPER §6), not for validating editable service sources alone. It clones the target and checks its `main` ref, generated service layout, manifests, actions, skills, and receive-pack capability.

## Live connection workflow

The `dev` and `agent` commands require a running DEBUG app and its debug WebSocket. On connection failure:

1. Confirm the app is running with `sim`, without touching the human-reserved `ox-qa` device.
2. Run `bun run debug dev list-chats` as the smallest connectivity probe.
3. Check `OX_DEBUG_ENDPOINT` when the app uses a non-default endpoint.
4. Inspect `bun run debug dev logs --level warning` before widening to device logs.

Prefer command output over assumptions. Report the exact command, target chat, and relevant failure text when blocked.
