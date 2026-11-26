export function agentLog(event: string, fields: Record<string, unknown> = {}): void {
  process.stderr.write(`${JSON.stringify({ time: new Date().toISOString(), subsystem: "agent-serve", event, ...fields })}\n`);
}
