#!/usr/bin/env bun
import { service, SUBS as serviceSubs } from "./services.ts";
import { sessions } from "./sessions.ts";
import { runCli, type CommandGroup } from "./lib.ts";
import { artifacts, chats, memory, profiles, skills, soul } from "./ox-content.ts";
import { skill, SUBS as skillSubs } from "./user-skills.ts";
import { herdr } from "./herdr.ts";
import { repository, SUBS as repositorySubs } from "./repositories.ts";
import packageMetadata from "./package.json";

const groups: Record<string, CommandGroup> = {
  profiles: { fn: profiles, desc: "List Profiles in iCloud Drive (--json)" },
  memory: { fn: memory, desc: "Print MEMORY.md from a Profile" },
  soul: { fn: soul, desc: "Print SOUL.md from a Profile" },
  skills: { fn: skills, desc: "List skills, or print one skill" },
  artifacts: { fn: artifacts, desc: "List artifacts, or print one artifact" },
  chats: { fn: chats, desc: "List chats, or print one transcript" },
  sessions: { fn: sessions, desc: "List targetable services or tabs in the selected runtime" },
  herdr: { fn: herdr, desc: "Expose local Herdr agents through a loopback MCP server" },
  repository: { fn: repository, desc: "Inspect, validate, or serve service repositories", subs: repositorySubs },
  skill: { fn: skill, desc: "Create and manage user skills", subs: skillSubs },
  service: { fn: service, desc: "Inspect and exercise services", subs: serviceSubs },
};

await runCli("ox", packageMetadata.version, "Inspect a Profile, create skills, and exercise services", groups, process.argv.slice(2));
