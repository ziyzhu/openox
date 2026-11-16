import { expect, test } from "bun:test";
import { execute } from "../evals/execute";
import { catalog } from "../evals/stubs";

test("execute exposes namespace and function help without process, network, or dynamic-code access", async () => {
  const calls: string[] = [];
  const result = await execute("console.log(typeof process, typeof fetch, typeof Bun); console.log(ox.web.browser.help()); console.log(ox.fs.read.help()); try {console.log(ox.fs.read.constructor('return process')())} catch(e) {console.log(e.name)}", async name => { calls.push(name); return null; });
  expect(result).toContain("undefined undefined undefined");
  expect(result).toContain("ox.web.browser.goto");
  expect(result).toContain("inputSchema");
  expect(result).toContain("EvalError");
  expect(calls).toEqual([]);
  expect(Object.keys(catalog).some(name => name.startsWith("ox.app."))).toBe(false);
});

test("cancellation terminates runaway execute code without a Host or simulator", async () => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 100);
  try { await expect(execute("while(true) {}", async () => null, controller.signal)).rejects.toThrow(); }
  finally { clearTimeout(timer); }
}, 3000);
