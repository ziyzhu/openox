export type LogLevel = "debug" | "info" | "warning" | "error";

/// Structured, user-owned on-device diagnostics. Never log credentials, message text, or website data.
export function log(level: LogLevel, message: string, fields: Record<string, string | number | boolean> = {}): void {
  if (level === "debug" && !process.env.OX_DEBUG) return;
  process.stderr.write(`${JSON.stringify({ time: new Date().toISOString(), level, message, fields })}\n`);
}
