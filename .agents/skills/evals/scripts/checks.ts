import type { Check, Run } from "./types.ts";

export const succeeded = (run: Run, name: string) => run.calls.filter(call => call.name === name && !call.error);

export const called = (run: Run, name: string): Check => ({ detail: `${name} succeeded`, passed: succeeded(run, name).length > 0 });

export const only = (run: Run, names: string[]): Check => {
  const other = [...new Set(run.calls.map(call => call.name).filter(name => !names.includes(name)))];
  return { detail: `Only called ${names.join(", ")}${other.length ? `; also called ${other.join(", ")}` : ""}`, passed: other.length === 0 };
};

export const readResource = (run: Run, path: string, expected = true): Check => ({
  detail: `${expected ? "Read" : "Did not read"} ${path}`,
  passed: succeeded(run, "ox.fs.read").some(call => String(call.args.path).replace(/^\/+/, "") === path) === expected,
});

export const mentions = (run: Run, ...texts: string[]): Check => ({
  detail: `Answer mentions ${texts.map(text => JSON.stringify(text)).join(", ")}`,
  passed: texts.every(text => run.answer.toLowerCase().includes(text.toLowerCase())),
});
