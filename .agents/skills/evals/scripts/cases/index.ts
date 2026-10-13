import { functionCases } from "./functions.ts";
import { workflowCases } from "./workflows.ts";
import { safetyCases } from "./safety.ts";

export const cases = [...functionCases, ...workflowCases, ...safetyCases];

export const smokeIds = new Set(["app-profile-success", "provider-list-success", "repository-list-success", "schedule-list-success"]);
