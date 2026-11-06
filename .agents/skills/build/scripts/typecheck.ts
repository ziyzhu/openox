import { run } from "../../../lib.ts";

const projects = [
  "apps/cli/tsconfig.json",
  "packages/protocol/tsconfig.json",
  "packages/agent/tsconfig.json",
  "packages/services/tsconfig.json",
  ".agents/tsconfig.json",
];

const results = await Promise.all(projects.map(async (project) => {
  const { code } = await run(["bunx", "tsc", "-p", project], { allowFailure: true });
  return { project, code };
}));

const failed = results.filter((result) => result.code !== 0);
if (failed.length > 0) {
  for (const result of failed) console.error(`FAIL typecheck ${result.project} exited ${result.code}`);
  process.exitCode = 1;
} else {
  console.log(`PASS typecheck ${projects.length} projects`);
}
