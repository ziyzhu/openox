import { resolve } from "node:path";

export const ROOT = resolve(import.meta.dir, "..");

export const fail = (m: string): never => {
  console.error(`error: ${m}`);
  process.exit(1);
};
