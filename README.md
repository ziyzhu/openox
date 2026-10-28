<div align="center">

<img alt="Ox app icon" src="/apps/ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="160" height="160">

<h1>OpenOx</h1>

OpenOx is an open-source project for building and running Ox.

An Ox is a self-evolving agent that runs on your phone 📱 and turns any website into tools.

[![App Store](https://img.shields.io/badge/Download_on_the_App_Store-000000?style=for-the-badge&logo=apple&logoColor=white)](https://apps.apple.com/us/app/ox-self-evolving-agent/id6802224502)
[![Discord](https://img.shields.io/badge/Join_Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/Sre9DaKAAg)

</div>

## The experience

1. The ease and polish of ChatGPT.
1. Runs on your device.
1. Works with your choice of model.

## Demo

Watch Ox use LinkedIn to find jobs, build an integration with Workday on the fly, and draft a submission using the local file system.

<a href="https://openox.ai/#demo">
  <img src="https://openox.ai/assets/media/demos/78dbbd00cd76/github-thumbnail-65s.jpg" alt="Watch Ox create a reusable service and prepare a job application" width="240">
</a>

[Full demo →](https://openox.ai/#demo)

## How it works

- **Ox** is malleable. Change settings by chatting with it.
- **Ox Client** is where you chat with Ox. Connect to a Host on the same device or another device.
- **Ox Host** runs your agent and tools. Use a macOS Host from your iOS Client for long-running tasks.
- **Ox VM** provides a persistent execution environment with a common interface across supported devices.
- **Ox Agent** builds on [Pi Durable](https://earendil.com/posts/pi-durable/) and uses Code Mode to interact with the Ox VM.
- **Ox Profile** keeps your memory and conversations in a plain folder that you can move between devices.
- **Ox Repository** packages services and skills in Git, so you can share capabilities with other Ox users.

## Download

Run Ox on your iPhone with **Ox for iOS**, available on the [App Store](https://apps.apple.com/us/app/ox-self-evolving-agent/id6802224502).

To build and run your own Ox from this repository, follow the [setup guide](.agents/skills/setup/SKILL.md).

## A random sketch

<img src="https://openox.ai/assets/media/slides/openox/img-5332-94c0c8e1b754.jpg" alt="Whiteboard sketch comparing access to the internet through websites and apps with access through Ox or another personal assistant" width="720">

The internet started small and open. Google became the organizing layer. Then came walled platforms built to feed on our attention. Many user interfaces were never designed for the people using them, but for the businesses behind them. The internet should be open, but for most of us, using it has meant working through whatever websites and apps we were given. That’s starting to change. We can now use agents to move beyond those interfaces and interact with the internet more freely and much faster.

## Contributing

OpenOx is developed by [@ziyzhu](https://x.com/ziyzhu) and users like you. We welcome both pull requests and issues on GitHub.

- Join the [community Discord](https://discord.gg/Sre9DaKAAg).
- Check the [development setup and contribution guide](.agents/skills/setup/SKILL.md) for CLI, macOS, and iOS workflows.

## Troubleshooting

| Issue | Fix |
| --- | --- |
| ChatGPT sign-in fails with “HTTP URL with HTTPS-Only enabled” in Safari. | Temporarily turn off **Not Secure Connection Warning** in **Settings → Apps → Safari**, retry sign-in, then turn the setting back on. Verified on iOS 27. |

