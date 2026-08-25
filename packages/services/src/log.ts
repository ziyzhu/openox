type Level = "info" | "warn" | "error";

function emit(level: Level, args: unknown[]) {
  const ts = new Date().toISOString();
  const tag = level.toUpperCase().padEnd(5, " ");
  const write = level === "info" ? console.log : console.error;
  write(`[${ts}] ${tag}`, ...args);
}

export function logInfo(...args: unknown[]) { emit("info", args); }
export function logWarn(...args: unknown[]) { emit("warn", args); }

export function logError(...args: unknown[]) {
  const stacks: string[] = [];
  const flat = args.map((a) => {
    if (a instanceof Error) {
      if (a.stack) stacks.push(a.stack);
      return a.message;
    }
    return a;
  });
  emit("error", flat);
  for (const s of stacks) console.error(s);
}
