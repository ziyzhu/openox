#!/usr/bin/env bun
import { group, runCli, type CommandGroup } from "./lib.ts";
import { PROFILE_COMMANDS } from "./profiles.ts";
import { REPOSITORY_COMMANDS } from "./repositories.ts";
import { REPOSITORY_SERVICE_COMMANDS } from "./repository-services.ts";
import { LEGACY_HOST_COMMANDS } from "./profile-live.ts";
import { FILE_COMMANDS, PROFILE_REPOSITORY_COMMANDS } from "./profile-admin.ts";
import { SERVICE_COMMANDS } from "./services.ts";
import { SUBS as conversationCommands } from "./conversation.ts";
import { SUBS as vmCommands } from "./vm.ts";
import { AGENT_COMMANDS } from "./agent.ts";
import packageMetadata from "../package.json";

const groups: Record<string, CommandGroup> = {
  profile: group("profile", "Use a Profile open in Ox (--profile <ws-url>), or read a Profile folder from disk (--profile <path>).", PROFILE_COMMANDS),
  repository: group("repository", "Inspect a repository (--repository <path-or-url>) or manage the Profile's repositories (--profile <ws-url>).", {
    ...REPOSITORY_COMMANDS,
    ...REPOSITORY_SERVICE_COMMANDS,
    ...PROFILE_REPOSITORY_COMMANDS,
  }),
  files: group("files", "Manage the Profile's folder access or download conversation files (--profile <ws-url>).", FILE_COMMANDS),
  service: group("service", "Exercise live services in the Profile (--profile <ws-url>).", SERVICE_COMMANDS),
  conversation: group("conversation", "Drive and inspect the Profile's conversations (--conversation <conversation-id>).", conversationCommands),
  vm: group("vm", "Use a conversation-bound VM in the Profile (--conversation <conversation-id>).", vmCommands),
  agent: group("agent", "Serve pi on this machine to Ox, or inspect an agent endpoint.", AGENT_COMMANDS),
  host: { ...group("host", "Renamed to ox profile.", LEGACY_HOST_COMMANDS), hidden: true },
};

await runCli("ox", packageMetadata.version, "Use Ox Profiles, repositories, files, services, conversations, and VMs", groups, process.argv.slice(2));
