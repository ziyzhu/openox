<div align="center">

<img alt="Ox app icon" src="/apps/ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="160" height="160">

<h1>OpenOx</h1>

OpenOx is an open-source project for building and running your own self-evolving agent, Ox.

Ox runs on your phone and turns any website into reusable tools. Yes, any website.

<h3>

[Website](https://openox.ai) · [Demo](https://openox.ai/#demo) · [App Store](https://apps.apple.com/us/app/ox-self-evolving-agent/id6802224502) · [Discord](https://discord.gg/Sre9DaKAAg)

</h3>

[![GitHub Repo stars](https://img.shields.io/github/stars/ziyzhu/openox)](https://github.com/ziyzhu/openox/stargazers)
[![CI](https://github.com/ziyzhu/openox/actions/workflows/ci.yml/badge.svg)](https://github.com/ziyzhu/openox/actions/workflows/ci.yml)

</div>

## The experience

- The ease and polish of ChatGPT.
- Runs on your device.
- Works with your choice of model.

## Demo

Watch Ox use LinkedIn to find jobs, build an integration with Workday on the fly, and draft a submission using the local file system.

<a href="https://openox.ai/#demo">
  <img src="https://openox.ai/assets/media/demos/78dbbd00cd76/github-thumbnail-65s.jpg" alt="Watch Ox create a reusable service and prepare a job application" width="240">
</a>

[Watch the full demo →](https://openox.ai/#demo)

## How it works

- **Ox** is malleable. Change settings by chatting with it.
- **Ox Client** and **Ox Host** work across devices. Use an iOS Client to connect to a macOS Host for long-running tasks.
- **Ox VM** provides a persistent execution environment with a common interface across supported devices.
- **Ox Agent** builds on [Pi Durable](https://earendil.com/posts/pi-durable/) and writes code to interact with the VM.
- **Ox Profile** keeps your memory and conversations in a plain folder that you can move between devices.
- **Ox Repository** packages services and skills in Git, so you can share capabilities with other Ox users.

## Download

Run Ox on your iPhone with **Ox for iOS**, available on the [App Store](https://apps.apple.com/us/app/ox-self-evolving-agent/id6802224502).

To build and run your own Ox from this repository, follow the [setup guide](.agents/skills/setup/SKILL.md).

## A random sketch

<img src="https://openox.ai/assets/media/slides/openox/img-5332-94c0c8e1b754.jpg" alt="Whiteboard sketch comparing access to the internet through websites and apps with access through Ox or another personal assistant" width="720">

## Contributing

OpenOx is developed by [@ziyzhu](https://x.com/ziyzhu) and users like you. We welcome both pull requests and issues on GitHub.

- Join the [community Discord](https://discord.gg/Sre9DaKAAg).
- Check the [development setup and contribution guide](.agents/skills/setup/SKILL.md) for CLI, macOS, and iOS workflows.

## Troubleshooting

| Issue | Fix |
| --- | --- |
| ChatGPT sign-in fails with “HTTP URL with HTTPS-Only enabled” in Safari. | Temporarily turn off **Not Secure Connection Warning** in **Settings → Apps → Safari**, retry sign-in, then turn the setting back on. Verified on iOS 27. |

