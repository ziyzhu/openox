import { afterEach, beforeEach, expect, test } from "bun:test";
import { parseGlobalOptions } from "../apps/cli/src/lib.ts";

const repository = process.env.OX_REPOSITORY;

beforeEach(() => {
  delete process.env.OX_REPOSITORY;
});

afterEach(() => {
  if (repository === undefined) delete process.env.OX_REPOSITORY;
  else process.env.OX_REPOSITORY = repository;
});

const options = [
  ["host", "ws://localhost:9876/?a=b", "a WebSocket URL"],
  ["profile", "/tmp/ox profile", "a path"],
  ["chat", "chat-id", "a chat id"],
  ["repository", "/tmp/ox=repository", "a path or URL"],
] as const;

for (const [key, value, requirement] of options) {
  const flag = `--${key}`;

  test(`${flag} accepts separate and assigned values among command arguments`, () => {
    for (const input of [[flag, value], [`${flag}=${value}`]]) {
      expect(parseGlobalOptions(["command", ...input, "--json", "argument"]))
        .toEqual({ context: { [key]: value }, rest: ["command", "--json", "argument"] });
    }
  });

  test(`${flag} rejects missing values without consuming another option`, () => {
    for (const input of [[flag], [flag, ""], [`${flag}=`], [flag, "--help"], [flag, "-h"], [flag, "--chat=other"]]) {
      expect(() => parseGlobalOptions(input)).toThrow(`${flag} requires ${requirement}`);
    }
  });

  test(`${flag} rejects duplicates in either syntax`, () => {
    for (const first of [[flag, value], [`${flag}=${value}`]]) {
      for (const second of [[flag, value], [`${flag}=${value}`]]) {
        expect(() => parseGlobalOptions([...first, ...second])).toThrow(`${flag} may only be specified once`);
      }
    }
  });

  test(`${flag} accepts an explicit value starting with a dash`, () => {
    expect(parseGlobalOptions([`${flag}=-value`])).toEqual({ context: { [key]: "-value" }, rest: [] });
  });
}

test("repository environment default can be overridden once", () => {
  process.env.OX_REPOSITORY = "/tmp/default";
  expect(parseGlobalOptions([])).toEqual({ context: { repository: "/tmp/default" }, rest: [] });
  expect(parseGlobalOptions(["--repository=/tmp/explicit"]))
    .toEqual({ context: { repository: "/tmp/explicit" }, rest: [] });
  expect(() => parseGlobalOptions(["--repository=/tmp/first", "--repository=/tmp/second"]))
    .toThrow("--repository may only be specified once");
});

test("all global options can be combined and unknown arguments remain intact", () => {
  const arguments_ = ["vm", "call", "--hostile=value", "--toString", "--constructor=value", "--args", '{"x":"a=b"}'];
  expect(parseGlobalOptions([...options.flatMap(([key, value]) => [`--${key}`, value]), ...arguments_]))
    .toEqual({ context: Object.fromEntries(options.map(([key, value]) => [key, value])), rest: arguments_ });
});

test("removed global options retain their migration guidance", () => {
  for (const [flag, message] of [
    ["--runtime", "--runtime was removed; the selected Host owns service page implementation"],
    ["--session", "--session was removed; use --chat for ox vm or --herdr-session for ox herdr"],
    ["--vm-session", "--vm-session was renamed to --chat"],
    ["--root", "--root was renamed to --profile"],
  ]) {
    expect(() => parseGlobalOptions([flag!])).toThrow(message!);
    expect(() => parseGlobalOptions([`${flag}=value`])).toThrow(message!);
  }
});
