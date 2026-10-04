#!/usr/bin/env bun
import { group, runCli, type CommandGroup } from "./lib.ts";
import { PROFILE_COMMANDS } from "./ox-content.ts";
import { REPOSITORY_COMMANDS } from "./repositories.ts";
import { REPOSITORY_SERVICE_COMMANDS } from "./repository-services.ts";
import { HOST_COMMANDS } from "./host.ts";
import { SUBS as chatCommands } from "./chat.ts";
import { SUBS as vmCommands } from "./vm.ts";
import packageMetadata from "../package.json";

const groups: Record<string, CommandGroup> = {
  profile: group("profile", "Read a Profile directly from disk (--profile <path>).", PROFILE_COMMANDS),
  repository: group("repository", "Inspect, validate, serve, and test a repository (--repository <path-or-url>).", {
    ...REPOSITORY_COMMANDS,
    ...REPOSITORY_SERVICE_COMMANDS,
  }),
  host: group("host", "Inspect and operate an Ox Host (--host <ws-url>).", HOST_COMMANDS),
  chat: group("chat", "Drive and inspect chats on the Host (--chat <chat-id>).", chatCommands),
  vm: group("vm", "Use a chat-bound VM on the Host (--chat <chat-id>).", vmCommands),
};

await runCli("ox", packageMetadata.version, "Use Ox Profiles, repositories, Hosts, chats, and VMs", groups, process.argv.slice(2));
