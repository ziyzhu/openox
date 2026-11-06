#!/usr/bin/env bun
import { group, runCli, type CommandGroup } from "./lib.ts";
import { PROFILE_COMMANDS } from "./profiles.ts";
import { REPOSITORY_COMMANDS } from "./repositories.ts";
import { REPOSITORY_SERVICE_COMMANDS } from "./repository-services.ts";
import { HOST_COMMANDS } from "./host.ts";
import { FILE_COMMANDS, HOST_REPOSITORY_COMMANDS } from "./host-admin.ts";
import { SERVICE_COMMANDS } from "./services.ts";
import { SUBS as conversationCommands } from "./conversation.ts";
import { SUBS as vmCommands } from "./vm.ts";
import packageMetadata from "../package.json";

const groups: Record<string, CommandGroup> = {
  profile: group("profile", "Manage Host Profiles (--host), or read a Profile from disk (--profile <path>).", PROFILE_COMMANDS),
  repository: group("repository", "Inspect a repository (--repository <path-or-url>) or manage Host connections (--host <ws-url>).", {
    ...REPOSITORY_COMMANDS,
    ...REPOSITORY_SERVICE_COMMANDS,
    ...HOST_REPOSITORY_COMMANDS,
  }),
  files: group("files", "Authorize folder access on the Host device (--host <ws-url>, --profile <id>).", FILE_COMMANDS),
  service: group("service", "Exercise live services through the selected Host (--host <ws-url>).", SERVICE_COMMANDS),
  host: group("host", "Inspect and operate an Ox Host (--host <ws-url>).", HOST_COMMANDS),
  conversation: group("conversation", "Drive and inspect conversations on the Host (--conversation <conversation-id>).", conversationCommands),
  vm: group("vm", "Use a conversation-bound VM on the Host (--conversation <conversation-id>).", vmCommands),
};

await runCli("ox", packageMetadata.version, "Use Ox Profiles, repositories, files, services, Hosts, conversations, and VMs", groups, process.argv.slice(2));
