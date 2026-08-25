import { connectHost, requireHost } from "./host-request.ts";
import { fail, type CliContext } from "./lib.ts";

type LogRow = {
  seq: number;
  time: string;
  level: string;
  category: string;
  thread?: string;
  location: string;
  message: string;
};

const LEVELS = ["debug", "info", "warning", "error"];

export async function logs(args: string[], context: CliContext): Promise<void> {
  const options = parseOptions(args);
  if (!options.follow) {
    const result = await requireHost("get-logs", context, options.timeoutMs);
    const rows = limitedRows(filteredRows(result.logs, options.level, options.grep), options.tail);
    printRows(rows, options.json, false);
    return;
  }
  await followLogs(context, options);
}

async function followLogs(
  context: CliContext,
  options: ReturnType<typeof parseOptions>,
): Promise<void> {
  let maximumSequence = -1;
  let stopping = false;
  const host = connectHost(context);
  const stop = () => {
    stopping = true;
    host.close();
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  try {
    while (!stopping) {
      const result = await host.request("get-logs", options.timeoutMs);
      if (stopping) break;
      if (!result.ok) {
        process.stderr.write(`logs: ${result.error}; retrying\n`);
      } else {
        const allRows = Array.isArray(result.logs) ? result.logs as LogRow[] : [];
        const unseen = maximumSequence < 0 ? allRows : allRows.filter(row => row.seq > maximumSequence);
        const filtered = filteredRows(unseen, options.level, options.grep);
        const rows = maximumSequence < 0 ? limitedRows(filtered, options.tail) : filtered;
        maximumSequence = Math.max(maximumSequence, ...allRows.map(row => row.seq));
        printRows(rows, options.json, true);
      }
      if (!stopping) await Bun.sleep(options.intervalMs);
    }
  } finally {
    host.close();
    process.off("SIGINT", stop);
    process.off("SIGTERM", stop);
  }
}

function parseOptions(args: string[]): {
  timeoutMs: number;
  intervalMs: number;
  json: boolean;
  follow: boolean;
  level: string;
  grep: string;
  tail: number;
} {
  let timeoutMs = 30000;
  let intervalMs = 1000;
  let json = false;
  let follow = false;
  let level = "";
  let grep = "";
  let tail = Number.POSITIVE_INFINITY;
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--json") json = true;
    else if (argument === "--follow" || argument === "-f") follow = true;
    else if (argument === "--level") level = requiredValue(args[++index], "--level").toLowerCase();
    else if (argument.startsWith("--level=")) level = argument.slice(8).toLowerCase();
    else if (argument === "--grep") grep = requiredValue(args[++index], "--grep");
    else if (argument.startsWith("--grep=")) grep = argument.slice(7);
    else if (argument === "--tail") tail = nonnegativeInteger(args[++index], "--tail");
    else if (argument.startsWith("--tail=")) tail = nonnegativeInteger(argument.slice(7), "--tail");
    else if (argument === "--timeout") timeoutMs = positiveNumber(args[++index], "--timeout");
    else if (argument.startsWith("--timeout=")) timeoutMs = positiveNumber(argument.slice(10), "--timeout");
    else if (argument === "--interval") intervalMs = positiveNumber(args[++index], "--interval");
    else if (argument.startsWith("--interval=")) intervalMs = positiveNumber(argument.slice(11), "--interval");
    else if (argument === "-h" || argument === "--help") {
      console.log(`Usage: ox [--host <url>] logs [--level ${LEVELS.join("|")}] [--grep <substring>] [--tail <count>] [--follow] [--json] [--timeout 30000] [--interval 1000]`);
      process.exit(0);
    } else fail(`unknown option: ${argument}`);
  }
  if (level && !LEVELS.includes(level)) fail(`--level must be one of ${LEVELS.join(", ")}`);
  if (follow && !Number.isFinite(tail)) tail = 20;
  return { timeoutMs, intervalMs, json, follow, level, grep, tail };
}

function filteredRows(value: unknown, level: string, grep: string): LogRow[] {
  let rows = Array.isArray(value) ? value as LogRow[] : [];
  const minimum = LEVELS.indexOf(level);
  if (minimum >= 0) rows = rows.filter(row => LEVELS.indexOf(row.level) >= minimum);
  if (grep) {
    const needle = grep.toLowerCase();
    rows = rows.filter(row => row.message.toLowerCase().includes(needle) || row.category.toLowerCase().includes(needle));
  }
  return rows;
}

function limitedRows(rows: LogRow[], count: number): LogRow[] {
  if (count === 0) return [];
  return Number.isFinite(count) ? rows.slice(-count) : rows;
}

function printRows(rows: LogRow[], json: boolean, streaming: boolean): void {
  if (json) {
    if (streaming) rows.forEach(row => console.log(JSON.stringify(row)));
    else console.log(JSON.stringify(rows, null, 2));
    return;
  }
  if (!rows.length && !streaming) {
    console.log("(no logs)");
    return;
  }
  for (const row of rows) {
    const time = row.time.slice(11, 23).padEnd(12);
    const level = row.level.toUpperCase().padEnd(7);
    const thread = row.thread ? `(${row.thread}) ` : "";
    console.log(`${time} ${level} ${row.category} ${thread}${row.location} ${row.message}`);
  }
}

function requiredValue(value: string | undefined, flag: string): string {
  return value || fail(`${flag} requires a value`);
}

function positiveNumber(value: string | undefined, flag: string): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) fail(`${flag} requires a positive number`);
  return parsed;
}

function nonnegativeInteger(value: string | undefined, flag: string): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) fail(`${flag} requires a nonnegative integer`);
  return parsed;
}
