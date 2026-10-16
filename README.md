<div align="center">

<img alt="Ox app icon" src="/apps/ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="160" height="160">

<h1>OpenOx</h1>

A self-evolving agent that runs on your phone.

<h3>

[Website](https://openox.ai) · [App Store](https://apps.apple.com/us/app/ox-self-evolving-agent/id6802224502) · [Discord](https://discord.gg/55eS3kEEX)

</h3>

[![GitHub Repo stars](https://img.shields.io/github/stars/ziyzhu/openox)](https://github.com/ziyzhu/openox/stargazers)
[![CI](https://github.com/ziyzhu/openox/actions/workflows/ci.yml/badge.svg)](https://github.com/ziyzhu/openox/actions/workflows/ci.yml)

</div>

---

## Features

1. **Connect anything** — Ox works across AI assistants, apps, and websites to get things done for you.
2. **Local first** — Ox runs on your device, keeping your conversations, credentials, and memory stored locally.
3. **Yours** — Open source and malleable, Ox evolves with you and uses the models you choose.

## Usage

- **Clients:** [iOS app](apps/ios) and [CLI](apps/cli) for macOS and Linux.
- **Hosts:** built-in iOS Host and standalone [macOS Host](apps/macos) (WIP).

The iOS app uses its built-in Host. The CLI can connect to either Host.

```mermaid
flowchart LR
    iOS["iOS app"] --> iOSHost["iOS Host · on your phone"]
    CLI["CLI · macOS / Linux"] --> iOSHost
    CLI --> MacHost["macOS Host · WIP"]
```

**Use Ox on iPhone**

1. Install [Ox from the App Store](https://apps.apple.com/us/app/ox-self-evolving-agent/id6802224502).
2. Follow onboarding to choose your model.

**Install the CLI — macOS or Linux**

```sh
curl -fsSL https://raw.githubusercontent.com/ziyzhu/openox/main/apps/cli/install.sh | sh
ox --help
```

**Run a Host on Mac — WIP**

The macOS Host runs in the menu bar. It has no conversation UI; use the CLI to
interact with it.

Requires macOS 26+, Xcode, [Bun](https://bun.sh/) 1.3+, and XcodeGen
(`brew install xcodegen`). Run from a source checkout:

```sh
bun install
bun run build:services
bun run build:agent
bun run build:macos -derivedDataPath /tmp/ox-macos-build
open /tmp/ox-macos-build/Build/Products/Debug/OxHost.app --args --allow-connections
```

**Connect the CLI to a Host**

1. Connect your terminal device and Host to the same [Tailscale](https://tailscale.com/) tailnet.
2. Allow connections on the Host:
   - **iPhone:** Turn on Settings → Host and keep Ox open.
   - **Mac:** Keep the Host running; the launch command above enables connections.
3. Discover available Hosts and check your connection:

```sh
ox host list
ox --host ws://<host-tailnet-address>:9876 host describe
```

## Architecture

An Ox separates the interface, runtime, model, persistent state, and capabilities into seven components.

```mermaid
---
config:
  flowchart:
    wrappingWidth: 400
---
flowchart TB
  client["<b>Ox Client</b><br>Mobile · Desktop · Web · CLI"]
  model["<b>Ox Model Provider</b><br>Any model · Any provider"]
  remote_repositories["<b>Remote Repositories</b><br>Public Git + repository.json"]

  subgraph host["Ox Host"]
    host_api["<b>Ox Host API</b><br>Conversations · Services · Lifecycle"]
    agent["<b>Ox Agent</b><br>Reasoning · Tool use"]
    model_adapter["<b>Model adapter</b><br>Provider-neutral agent loop"]
    profile["<b>Ox Profile</b><br>Identity · Memory · Skills<br>Files · Conversations"]
    vm["<b>Ox VM</b><br>Sandboxed JavaScript · ox.*<br>Skills · Virtual filesystem"]
    local_repository["<b>Local Repository</b><br>Services · Skills<br>Editable Git + repository.json"]
    catalog["<b>Catalog</b><br>Services · Skills<br>Resolved sources"]
  end

  subgraph interfaces["Service interfaces"]
    device["<b>Device-native interface</b><br>Device Service"]
    web["<b>Web page</b><br>Web Service"]
    mcp["<b>MCP server</b><br>MCP Service"]
  end

  client <-- "in-process or remote" --> host_api
  host_api <--> agent
  agent <-- "provider-neutral" --> model_adapter
  model_adapter <-- "provider API" --> model
  agent -- "writes and executes code" --> vm
  profile <-- "reads and writes files" --> vm
  vm -- "creates or revises<br>via ox.fs" --> local_repository
  vm <-- "invokes actions<br>reads skills" --> catalog
  local_repository -- "validates and reloads" --> catalog
  remote_repositories -- "installs" --> catalog
  catalog --> device
  catalog --> web
  catalog --> mcp
```

*The Client and model remain replaceable around a Host that owns the Agent, Profile, VM, and service lifecycle.*

The network Client–Host protocol is JSON-RPC 2.0 over WebSocket inside Tailscale.
The [shared protocol package](packages/protocol) owns Client–Host RPC
schemas and Host–Repository content contracts. It supplies portable JSON Schema,
generated iOS RPC request models, and the supported repository version.
The [services package](packages/services) supplies the official repository
and filesystem skill readers.
iOS RPC handlers live under `Host/RPC`, UI automation under `Client/Automation`,
and production logging under `Diagnostics`. Simulator launch helpers and demo
previews live under `Development`; these do not define a separate Host privilege tier.

- **Ox Client** — An interface that connects to an Ox Host. A Client may be a mobile app, desktop app, web app, or command-line tool. The Host binds VM execution to the selected conversation, its permissions, attached services, and virtual filesystem view.
- **Ox Host** — A process or device that opens an Ox Profile, runs the Ox VM, and supplies platform and service adapters. A Client can use an embedded Host or target a compatible Host elsewhere.
- **Ox Agent** — The reasoning and tool-using process that pursues the user’s goals using the selected model, the state in an Ox Profile, and the capabilities exposed through the Ox VM.
- **Ox Model Provider** — The language model selected by the user. OpenOx does not prescribe a model or provider; the Host adapts provider-specific APIs to the provider-neutral agent loop. API-backed subscription and OAuth accounts are supported. AI websites remain callable services, not browser-backed model providers.
- **Ox Profile** — A portable folder containing the Agent’s persistent state: its identity, memory, skills, files, and conversation history. This keeps the Ox’s state independent of a particular Client or model.
- **Ox VM** — The execution environment supplied by an Ox Host. The Agent writes and runs code inside the VM without direct access to the network, Host filesystem, or device. Instead, it uses explicit `ox.*` capabilities to interact with the Profile, services, websites, users, and device capabilities. The `ox.fs` virtual filesystem presents Profile content, skills, services, conversations, and user-granted files while preserving each source’s permissions.
- **Ox Repository** — A versioned collection of services and reusable skills described by a `repository.json` manifest. Each Ox Host manages an editable Local repository and can install compatible remote repositories. Services expose typed Actions; repository-root skill packages teach workflows that can combine several services. System, repository, and Profile skills share one catalog with explicit source selection for conflicting names.

  - **Device services** are supplied by the Host’s platform adapters and expose capabilities such as Browser.
  - **Web services** expose actions backed by websites and the user’s browser session.
  - **MCP services** expose actions provided by an MCP server.

  Anyone can publish compatible web and MCP services in a public Git repository containing a `repository.json` manifest. Any compatible Host can install that repository. Device services remain part of the Host implementation.

## Distributed Evolution

Each Ox can self-evolve locally and, optionally, co-evolve with others. An Ox self-evolves through the VM, which lets it invoke an existing service while creating another one.

With an attached Browser capability, an Ox can navigate and inspect a website, perform approved interactions, and capture the evidence needed to create a reusable web service. That service becomes a set of actions the Ox can use again, combine with other services, or share through a repository.

1. The Agent invokes Browser or another attached service from the VM to gather evidence for the required capability.
2. The Agent uses `ox.fs` to write or revise the service manifest, actions, and repository-root skills in its Local Repository.
3. The Host validates each source mutation, and the Agent uses `ox.service.attach` to load or reload the service for the conversation.
4. The Agent can invoke new actions later in the same turn or in subsequent turns. New skills guide subsequent agent work.
5. Local Git can record the changes for inspection, reversal, and publication.

An Ox can therefore gain and apply a capability independently, without rebuilding or updating the Host or Client. Co-evolution is optional: an Ox can publish capabilities to shared repositories and install capabilities created by other Ox.
