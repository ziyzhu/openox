import { ROOT, sh } from "./lib.ts";

await sh(["bun", "run", "dev", ...process.argv.slice(2)], { cwd: `${ROOT}/dev` });
