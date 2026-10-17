import { run } from "../../../lib.ts";

const inside = await run(["git", "rev-parse", "--is-inside-work-tree"], { capture: true, allowFailure: true });
if (inside.code === 0) {
  await run(["git", "config", "merge.xcstrings.name", "OpenOx string catalog merge"]);
  await run(["git", "config", "merge.xcstrings.driver", "bun \"$(git rev-parse --show-toplevel)/.agents/skills/build/scripts/xcstrings-merge.ts\" %O %A %B %P"]);
}
