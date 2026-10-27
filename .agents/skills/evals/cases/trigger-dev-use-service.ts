import { readResource } from "../scripts/checks.ts";
import type { EvalCase } from "../scripts/types.ts";

export default {
  task: "Look up my next appointment using the attached clinic service.",
  attached: [{ domain: "clinic.example", description: "Clinic appointments", signIn: "signedIn" }],
  stubs: { functions: {
    "ox.service.inspect": [{ result: { service: { domain: "clinic.example", kind: "web", name: "Clinic", attached: true }, actions: { getNextAppointment: { name: "web:clinic.example:getNextAppointment", inputSchema: { type: "object", properties: {}, additionalProperties: false }, outputSchema: { type: "object", properties: { date: { type: "string" } }, required: ["date"] } } } } }],
    "ox.service.invoke": [{ args: { name: "web:clinic.example:getNextAppointment" }, result: { date: "2026-11-02T10:00:00Z" } }],
  } },
  checks: run => [readResource(run, "skills/evolve/SKILL.md", false)],
} satisfies EvalCase;
