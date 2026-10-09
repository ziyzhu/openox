import { parseSkill, isSkillResourcePath, type Skill } from "@openox/protocol/skills";
import evolve from "../../skills/evolve/SKILL.md" with { type: "text" };
import apiService from "../../skills/evolve/references/api-service.md" with { type: "text" };
import helpers from "../../skills/evolve/references/helpers.js" with { type: "text" };
import modelSchemas from "../../skills/evolve/references/model-schemas.md" with { type: "text" };
import modelService from "../../skills/evolve/references/model-service.md" with { type: "text" };
import webService from "../../skills/evolve/references/web-service.md" with { type: "text" };
import importMemory from "../../skills/import-memory/SKILL.md" with { type: "text" };
import manageProviders from "../../skills/manage-providers/SKILL.md" with { type: "text" };
import manageSkills from "../../skills/manage-skills/SKILL.md" with { type: "text" };
import repositorySkill from "../../skills/manage-skills/references/repository-skill.md" with { type: "text" };
import userSkill from "../../skills/manage-skills/references/user-skill.md" with { type: "text" };
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
    "references/model-schemas.md": modelSchemas, "references/model-service.md": modelService, "references/web-service.md": webService }),
  skill("import-memory", importMemory), skill("manage-providers", manageProviders),
  skill("manage-skills", manageSkills, { "references/repository-skill.md": repositorySkill, "references/user-skill.md": userSkill }),
  skill("visualize", visualize),
]);

export interface SkillActivationRequirement { action: string; skill: string; pathPrefix?: string }
export const skillActivationRequirements: readonly SkillActivationRequirement[] = Object.freeze([
  ...["save", "delete", "authenticate", "connect", "deauthenticate"].map(action => ({ action: `ox.provider.${action}`, skill: "manage-providers" })),
  ...["create", "copy", "delete", "share"].map(action => ({ action: `ox.skill.${action}`, skill: "manage-skills" })),
  ...["create", "update", "copy", "delete"].map(action => ({ action: `ox.service.${action}`, skill: "evolve" })),
  ...["write", "edit", "delete"].flatMap(action => [
    { action: `ox.fs.${action}`, skill: "manage-skills", pathPrefix: "skills/" },
    { action: `ox.fs.${action}`, skill: "evolve", pathPrefix: "services/" },
  ]),
].map(requirement => Object.freeze(requirement)));
