#!/usr/bin/env bun
import { reducer, SUBS as reducerSubs } from "./reducer.ts";
import { PROG, runCli, type CommandGroup } from "./lib.ts";

const groups: Record<string, CommandGroup> = {
  reducer: { fn: reducer, subs: reducerSubs },
};

await runCli(PROG, "Ox repository debugging tools", groups, process.argv.slice(2));
