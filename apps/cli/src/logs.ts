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
    const pages: LogRow[][] = [];
    const cursors = new Set<string>(options.cursor ? [options.cursor] : []);
    let cursor = options.cursor;
    let nextCursor: string | undefined;
    let hasMore = false;
    let count = 0;
    do {
      const result = await requireHost("logs.list", context, options.timeoutMs, logParams(options, cursor));
      if ((options.page || options.all || options.tail > options.limit && Number.isFinite(options.tail))
          && typeof result.hasMore !== "boolean") fail("Host does not support log pagination; update Ox on the Host device");
      nextCursor = typeof result.nextCursor === "string" ? result.nextCursor : undefined;
      hasMore = result.hasMore === true;
      if (hasMore && (!nextCursor || cursors.has(nextCursor))) fail("Host returned an invalid log pagination cursor");
      const rows = typeof result.hasMore === "boolean" ? result.logs as LogRow[]
        : filteredRows(result.logs, options.level, options.grep, options.category, options.since);
      pages.push(rows);
      count += rows.length;
      cursor = nextCursor;
      if (cursor) cursors.add(cursor);
    } while (!options.page && hasMore && (options.all || count < options.tail && Number.isFinite(options.tail)));
    const rows = limitedRows(pages.reverse().flat(), options.tail);
    if (options.page && options.json) console.log(JSON.stringify({ logs: rows, nextCursor: nextCursor ?? null, hasMore }, null, 2));
    else {
      printRows(rows, options.json, false);
      if (options.page && nextCursor) process.stderr.write(`Next cursor: ${nextCursor}\n`);
    }
    return;
  }
  await followLogs(context, options);
}

function logParams(options: ReturnType<typeof parseOptions>, cursor?: string): Record<string, unknown> {
  return {
    ...(options.limit !== 2000 ? { limit: options.limit } : {}),
    ...(cursor ? { cursor } : {}),
    ...(options.level ? { level: options.level } : {}),
    ...(options.grep ? { query: options.grep } : {}),
    ...(options.category ? { category: options.category } : {}),
    ...(options.since ? { since: options.since } : {}),
  };
}

async function followLogs(
  context: CliContext,
  options: ReturnType<typeof parseOptions>,
): Promise<void> {
  let previous: Map<string, number> | undefined;
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
      try {
        const result = await host.request("logs.list", options.timeoutMs, logParams(options));
        if (stopping) break;
        const allRows = Array.isArray(result.logs) ? result.logs as LogRow[] : [];
        // Sequence numbers are snapshot-relative in a compacting file. Match
        // record content instead, counting identical records to preserve repeats.
        const current = new Map<string, number>();
        const unseen = allRows.filter(row => {
          const key = JSON.stringify([row.time, row.level, row.category, row.thread, row.location, row.message]);
          const count = (current.get(key) ?? 0) + 1;
          current.set(key, count);
          return count > (previous?.get(key) ?? 0);
        });
        const filtered = typeof result.hasMore === "boolean" ? unseen
          : filteredRows(unseen, options.level, options.grep, options.category, options.since);
        const rows = previous ? filtered : limitedRows(filtered, options.tail);
        previous = current;
        printRows(rows, options.json, true);
      } catch (error) {
        if (!stopping) process.stderr.write(`logs: ${(error as Error).message}; retrying\n`);
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
  limit: number;
  cursor?: string;
  page: boolean;
  all: boolean;
  category: string;
  since: string;
} {
  let timeoutMs = 30000;
  let intervalMs = 1000;
  let json = false;
  let follow = false;
  let level = "";
  let grep = "";
  let tail = Number.POSITIVE_INFINITY;
  let limit = 2000;
  let cursor: string | undefined;
  let page = false;
  let all = false;
  let category = "";
  let since = "";
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--json") json = true;
    else if (argument === "--follow" || argument === "-f") follow = true;
    else if (argument === "--page") page = true;
    else if (argument === "--all") all = true;
    else if (argument === "--limit") limit = pageLimit(args[++index]);
    else if (argument.startsWith("--limit=")) limit = pageLimit(argument.slice(8));
    else if (argument === "--cursor") cursor = requiredValue(args[++index], "--cursor");
    else if (argument.startsWith("--cursor=")) cursor = requiredValue(argument.slice(9), "--cursor");
    else if (argument === "--category") category = requiredValue(args[++index], "--category");
    else if (argument.startsWith("--category=")) category = requiredValue(argument.slice(11), "--category");
    else if (argument === "--since") since = requiredValue(args[++index], "--since");
    else if (argument.startsWith("--since=")) since = requiredValue(argument.slice(8), "--since");
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
      console.log(`Usage: ox [--host <url>] host logs [--level ${LEVELS.join("|")}] [--grep <substring>] [--category <name>] [--since <ISO-8601>] [--tail <count>] [--limit 1..2000] [--page | --cursor <token> | --all | --follow] [--json] [--timeout 30000] [--interval 1000]`);
      process.exit(0);
    } else fail(`unknown option: ${argument}`);
  }
  if (level && !LEVELS.includes(level)) fail(`--level must be one of ${LEVELS.join(", ")}`);
  if (cursor) page = true;
  if (page && (all || follow || Number.isFinite(tail))) fail("--page/--cursor cannot be combined with --all, --follow, or --tail");
  if (all && (follow || Number.isFinite(tail))) fail("--all cannot be combined with --follow or --tail");
  if (follow && !Number.isFinite(tail)) tail = 20;
  return { timeoutMs, intervalMs, json, follow, level, grep, tail, limit, cursor, page, all, category, since };
}

function filteredRows(value: unknown, level: string, grep: string, category: string, since: string): LogRow[] {
  let rows = Array.isArray(value) ? value as LogRow[] : [];
  const minimum = LEVELS.indexOf(level);
  if (minimum >= 0) rows = rows.filter(row => LEVELS.indexOf(row.level) >= minimum);
  if (category) rows = rows.filter(row => row.category === category);
  if (since) rows = rows.filter(row => Date.parse(row.time) >= Date.parse(since));
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

function pageLimit(value: string | undefined): number {
  const parsed = nonnegativeInteger(value, "--limit");
  if (parsed < 1 || parsed > 2000) fail("--limit must be an integer from 1 to 2000");
  return parsed;
}

function nonnegativeInteger(value: string | undefined, flag: string): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) fail(`${flag} requires a nonnegative integer`);
  return parsed;
}
