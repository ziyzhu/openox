## OpenOx

```txt
XOOX
XXXX
OXXO
OXXO
```

Ox is a personal animal that lives on your phone.

[Blog](https://ziyzhu/introducing-openox), [Discord Server](https://discord.gg/7baSAHZTA).

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

Open `ios/ios.xcodeproj`, select a physical device, and run the `ios` scheme. The checked-in public service bundle contains the native iOS services and does not require access to a private service repository.

To use a different service repository while developing, serve it explicitly:

```sh
ox repository serve /path/to/service-repository --port 8101
```

## Development

Install dependencies and run the repository checks:

```sh
bun install --frozen-lockfile
bun run typecheck
```

The repository contains the iOS app, Share Extension, Ox CLI, debugger, tests, documentation, and website source. Production infrastructure, official signing, release automation, and private service implementations are intentionally not dependencies of this repository.

## Acknowledgements

[Pi](https://github.com/earendil-works/pi): Ox's main Swift agent loop referenced Pi.

[OpenCLI](https://github.com/jackwener/opencli): Ox's web service integration referenced some crawling techniques from OpenCLI.

[Defuddle](https://github.com/kepano/defuddle): Ox's HTML to Markdown parser uses Defuddle.
