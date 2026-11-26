import { agentLog } from "./agent-log.ts";

export type KeepAwake = { exited: Promise<number>; stop: () => Promise<void> };

export function keepAwake(): KeepAwake | undefined {
  if (process.platform !== "darwin") return undefined;
  const child = Bun.spawn(["/usr/bin/caffeinate", "-i", "-w", String(process.pid)], { stdin: "ignore", stdout: "ignore", stderr: "ignore" });
  agentLog("keep_awake.start", { pid: child.pid });
  return {
    exited: child.exited,
    async stop() {
      if (child.exitCode === null && child.signalCode === null) child.kill();
      await child.exited;
      agentLog("keep_awake.stop", { pid: child.pid });
    },
  };
}
