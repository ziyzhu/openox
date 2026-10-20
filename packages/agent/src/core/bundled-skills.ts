import { parseSkill, isSkillResourcePath, type Skill } from "@openox/protocol/skills";
import evolve from "../../skills/evolve/SKILL.md" with { type: "text" };
import apiService from "../../skills/evolve/references/api-service.md" with { type: "text" };
import helpers from "../../skills/evolve/references/helpers.js" with { type: "text" };
import modelSchemas from "../../skills/evolve/references/model-schemas.md" with { type: "text" };
import modelService from "../../skills/evolve/references/model-service.md" with { type: "text" };
import webService from "../../skills/evolve/references/web-service.md" with { type: "text" };
import importMemory from "../../skills/import-memory/SKILL.md" with { type: "text" };
import manageProviders from "../../skills/manage-providers/SKILL.md" with { type: "text" };
import skillGuide from "../../skills/evolve/references/skills.md" with { type: "text" };
import repositorySkill from "../../skills/evolve/references/repository-skill.md" with { type: "text" };
import userSkill from "../../skills/evolve/references/user-skill.md" with { type: "text" };
import visualize from "../../skills/visualize/SKILL.md" with { type: "text" };

export type BundledSkill = Omit<Skill, "services" | "resources"> & {
  readonly services: readonly string[];
  readonly resources: Readonly<Record<string, string>>;
  readonly source: "system";
  readonly files: Readonly<Record<string, string>>;
};
function skill(name: string, text: string, resources: Record<string, string> = {}): BundledSkill {
  if (Object.keys(resources).some(path => !isSkillResourcePath(path))) throw new Error(`Invalid bundled skill resources: ${name}`);
  const parsed = parseSkill(text, name);
  const files = Object.freeze({ "SKILL.md": text, ...resources });
  return Object.freeze({ ...parsed, services: Object.freeze(parsed.services),
    resources: Object.freeze(resources), source: "system", files });
}
export const bundledSkills: readonly BundledSkill[] = Object.freeze([
  skill("evolve", evolve, { "references/api-service.md": apiService, "references/helpers.js": helpers,
    "references/model-schemas.md": modelSchemas, "references/model-service.md": modelService, "references/web-service.md": webService,
    "references/skills.md": skillGuide, "references/user-skill.md": userSkill, "references/repository-skill.md": repositorySkill }),
  skill("import-memory", importMemory), skill("manage-providers", manageProviders),
  skill("visualize", visualize),
]);
