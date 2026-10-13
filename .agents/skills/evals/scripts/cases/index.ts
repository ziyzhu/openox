import { functionCases } from "./functions.ts";
import { workflowCases } from "./workflows.ts";
import { safetyCases } from "./safety.ts";

export const cases = [...functionCases, ...workflowCases, ...safetyCases];
