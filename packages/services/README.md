# OpenOx Services

`@openox/services` contains the sanitized official services built into Ox. It contains manifests, plain-JavaScript action installers, skills, and icons without TypeScript service sources or raw HAR captures.

The authored source lives in `repositories/builtin/`. Its `repository.json`
inventories services whose individual metadata is stored in `service.json`.

```sh
bun add @openox/services
```

Resolve the installed repository root:

```js
import { repositoryRoot } from "@openox/services";
```

Use `repositoryRoot` anywhere Ox accepts a local repository path.

`@openox/services/skills` exports `readSkill(directory, name)` and
`readSkills(repositoryDir, declared?)` for loading skill packages from any local
repository or Profile. This filesystem module requires Bun 1.3 or newer and does
not load the built-in repository.

Shared service contracts and validators live in
[`@openox/protocol`](../protocol/README.md). Ox authors plain-JavaScript installers;
the Host supplies `window.ox.install` at runtime.

For package verification and publication, use the
[release skill](../../.agents/skills/release/SKILL.md).
