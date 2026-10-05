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

Service authoring APIs are published separately as `@openox/service-sdk`.

For package verification and publication, use the
[release skill](../../.agents/skills/release/SKILL.md).
