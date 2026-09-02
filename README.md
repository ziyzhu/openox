<div align="center">

<img alt="Ox app icon" src="/apps/ios/Ox/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="160" height="160">

<h1>OpenOx</h1>

OpenOx: a protocol for an open ecosystem of self-evolving agents.

<h3>

[Website](https://openox.ai) · [TestFlight](https://testflight.apple.com/join/Y3x7nxj9) · [Discord](https://discord.gg/7baSAHZTA)

</h3>

[![GitHub Repo stars](https://img.shields.io/github/stars/ziyzhu/openox)](https://github.com/ziyzhu/openox/stargazers)
[![CI](https://github.com/ziyzhu/openox/actions/workflows/ci.yml/badge.svg)](https://github.com/ziyzhu/openox/actions/workflows/ci.yml)

</div>

---

Each self-evolving agent is called an Ox. Every Ox follows three principles.

1. **Acts Everywhere** — Ox turns websites into reusable actions. Use one that already exists or ask Ox to build a new one for you.
2. **Yours** — Ox runs on your device, keeps your data there, and works with any model, including free or self-hosted ones.
3. **Peace of Mind** — Ox asks before sensitive actions, keeps account credentials isolated on the web page, and lets you pull the plug at any time.

The first implementation of Ox is an iOS app whose source code is included in the OpenOx repository. You can [download it through TestFlight](https://testflight.apple.com/join/Y3x7nxj9).

## Components

An Ox separates the interface, runtime, model, persistent state, and capabilities into seven components.

![OpenOx components](docs/openox-components.svg)

*The Client and model remain replaceable around a Host that owns the Agent, Profile, VM, and service lifecycle.*

- **Ox Client** — An interface that connects to an Ox Host. A Client may be a mobile app, desktop app, web app, or command-line tool. The Host binds VM execution to the selected conversation, its permissions, attached services, and virtual filesystem view.
- **Ox Host** — A process or device that opens an Ox Profile, runs the Ox VM, and supplies platform and service adapters. A Client can use an embedded Host or target a compatible Host elsewhere.
- **Ox Agent** — The reasoning and tool-using process that pursues the user’s goals using the selected model, the state in an Ox Profile, and the capabilities exposed through the Ox VM.
- **Ox Model Provider** — The language model selected by the user. OpenOx does not prescribe a model or provider; the Host adapts provider-specific APIs to the provider-neutral agent loop.
- **Ox Profile** — A portable folder containing the Agent’s persistent state: its identity, memory, skills, artifacts, and conversation history. This keeps the Ox’s state independent of a particular Client or model.
- **Ox VM** — The execution environment supplied by an Ox Host. The Agent writes and runs code inside the VM without direct access to the network, Host filesystem, or device. Instead, it uses explicit `ox.*` capabilities to interact with the Profile, services, websites, users, and device capabilities. The `ox.fs` virtual filesystem presents Profile content, skills, services, chats, and user-granted files while preserving each source’s permissions.
- **Ox Service Repository** — A versioned collection of services described by a `repository.json` manifest. Each Ox Host manages an editable Local repository and can install compatible remote repositories. Each service exposes typed actions the Agent can invoke and may include reusable skills that teach the Agent when and how to use them.

  - **Device services** are supplied by the Host’s platform adapters and expose capabilities such as Browser.
  - **Web services** expose actions backed by websites and the user’s browser session.
  - **MCP services** expose actions provided by an MCP server.

  Anyone can publish compatible web and MCP services in a public Git repository containing a `repository.json` manifest. Any compatible Host can install that repository. Device services remain part of the Host implementation.

## Distributed evolution

Each Ox can self-evolve locally and, optionally, co-evolve with others. An Ox self-evolves through the VM, which lets it invoke an existing service while creating another one.

With an attached Browser capability, an Ox can navigate and inspect a website, perform approved interactions, and capture the evidence needed to create a reusable web service. That service becomes a set of actions the Ox can use again, combine with other services, or share through a repository.

1. The Agent invokes Browser or another attached service from the VM to gather evidence for the required capability.
2. The Agent uses `ox.fs` to write or revise the service manifest, actions, and optional skills in its Local Service Repository.
3. The Host validates each source mutation, and the Agent uses `ox.service.attach` to load or reload the service for the chat.
4. The Agent can invoke new actions later in the same turn or in subsequent turns. New skills guide subsequent agent work.
5. Local Git can record the changes for inspection, reversal, and publication.

An Ox can therefore gain and apply a capability independently, without rebuilding or updating the Host or Client. Co-evolution is optional: an Ox can publish capabilities to shared repositories and install capabilities created by other Ox.
