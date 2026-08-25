import { ROOT } from "../../../../tooling/lib.ts";

type Options = {
  targets: string[];
  chat?: string;
};

function usage(): string {
  return `Usage:
  bun run test:llm [--device ox-qa-N] [matrix options]
  bun run test:llm --target <provider=client:model> --target <provider=client:model> [--chat id]

Without targets, runs every keyed model-region pair through the live smoke matrix.
With targets, runs the behavioral evals followed by the latency benchmark.`;
}

function valueAfter(args: string[], index: number, flag: string): string {
  const value = args[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`${flag} needs a value`);
  return value;
}

function parseOptions(args: string[]): Options | undefined {
  if (args.includes("-h") || args.includes("--help")) {
    console.log(usage());
    return undefined;
  }
  const options: Options = { targets: [] };
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index]!;
    if (argument === "--target") options.targets.push(valueAfter(args, index++, argument));
    else if (argument === "--chat") options.chat = valueAfter(args, index++, argument);
    else throw new Error(`Unknown option ${argument}`);
  }
  if (options.targets.length < 2) throw new Error("Pass at least two --target provider=client:model values");
  return options;
}

function sharedArguments(options: Options): string[] {
  return [
    ...options.targets.flatMap((target) => ["--target", target]),
    ...(options.chat ? ["--chat", options.chat] : []),
  ];
}

async function run(script: string, args: string[]): Promise<number> {
  const child = Bun.spawn([process.execPath, script, ...args], {
    cwd: ROOT,
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });
  return await child.exited;
}

if (import.meta.main) {
  try {
    const args = Bun.argv.slice(2);
    if (!args.includes("--target")) {
      process.exitCode = await run("apps/ios/tests/llm/matrix.ts", args);
      process.exit();
    }
    const options = parseOptions(args);
    if (options) {
      const args = sharedArguments(options);
      const evalExit = await run("apps/ios/tests/llm/eval/run.ts", args);
      process.exitCode = evalExit === 0
        ? await run("apps/ios/tests/llm/benchmark/run.ts", args)
        : evalExit;
    }
  } catch (error) {
    console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
