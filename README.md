## OpenOx

Ox is a self-evolving agent that lives on your phone.

It is built around three principles:

1. Acts everywhere. Ox turns websites into reusable actions. You can use one that already exists or ask Ox to build a new one for you.
2. Yours, by design. Ox runs on your device, keeps your data there, and works with any model, including free or self-hosted ones.
3. Peace of mind. Ox asks before sensitive actions, keeps account credentials isolated on the web page, and lets you pull the plug at any time.

[Blog](https://ziyzhu/introducing-openox) | [Discord](https://discord.gg/7baSAHZTA)

## Installation

The initial release supports iOS. Install Xcode 26 or later and Bun on a Mac, then clone the repository:

```sh
git clone https://github.com/ziyzhu/openox.git
cd openox
bun install
```

Generate a local signing configuration using an Apple Developer Team ID and a reverse-DNS bundle identifier owned by that team:

```sh
bun run setup:ios -- --team ABCDE12345 --bundle com.example.openox
```

The command creates the ignored `ios/Local.xcconfig` with matching app, Share Extension, App Group, iCloud container, and Keychain identifiers. Register the generated App Group and iCloud container with your Apple development team if Xcode does not create them automatically.

Open `ios/ios.xcodeproj`, select a physical device, and run the `ios` scheme. The checked-in service bundle contains every built-in web, native iOS, and MCP service.

Built-in service sources live under `services/builtin/`. Regenerate the committed iOS bundle after changing them:

```sh
bun run build:services
```

To use a different service repository while developing, serve it explicitly:

```sh
ox repository serve /path/to/service-repository --port 8101
```

[`examples/service-repository`](examples/service-repository) is a standalone repository users can copy when creating their own remote services.

## Acknowledgements

[Pi](https://github.com/earendil-works/pi): Ox's main Swift agent loop referenced Pi.

[OpenCLI](https://github.com/jackwener/opencli): Ox's web service integration referenced some crawling techniques from OpenCLI.

[Defuddle](https://github.com/kepano/defuddle): Ox's HTML to Markdown parser uses Defuddle.
