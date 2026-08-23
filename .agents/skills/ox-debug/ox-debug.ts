#!/usr/bin/env bun
import { agent, SUBS as agentSubs } from "./agent.ts";
import { dev, SUBS as devSubs } from "./dev.ts";
import { reducer, SUBS as reducerSubs } from "./reducer.ts";
import { spec, SUBS as specSubs } from "./spec.ts";
import { PROG, runCli, type CommandGroup } from "./lib.ts";

const groups: Record<string, CommandGroup> = {
  dev: { fn: dev, subs: devSubs },
  agent: { fn: agent, subs: agentSubs },
  reducer: { fn: reducer, subs: reducerSubs },
  spec: { fn: spec, subs: specSubs },
};

await runCli(PROG, "Ox debug CLI — live introspection of the running iOS app", groups, process.argv.slice(2));
