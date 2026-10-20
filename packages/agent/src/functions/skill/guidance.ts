export const guidance: Record<string, string> = {
  "ox.skill.create": "Create one Profile-owned skill: `await ox.skill.create({ purpose, name, description, instructions, services? })`. Read evolve for skill authoring and verification. Create when requested or when observed work establishes a useful reusable workflow; improve a relevant existing skill before creating an overlapping one. No separate proposal confirmation is needed within the task's scope. The name is normalized to lowercase kebab-case and creation fails rather than replacing an existing skill.",
  "ox.skill.copy": "Copy one resolved skill, including references and helpers into a new Profile-owned skill: `await ox.skill.copy({ purpose, source, name })`. The destination name is normalized to lowercase kebab-case and must not already exist. Service dependencies are retained.",
  "ox.skill.share": "Copy the complete resolved skill into the Local repository for review and versioned storage. Fails if Local already contains the name.",
  "ox.skill.run": "Run a packaged JavaScript helper in this Ox VM. The script is an async function body with ox and args parameters. It uses normal Action permissions. Read the skill instructions first.",
  "ox.skill.delete": "Delete one writable skill: `await ox.skill.delete({ purpose, name })`. Read-only compatibility snapshots and installed repository skills cannot be deleted.",
  "namespace.skill": "Create, customize, share, delete, and run skill helpers.",
};
