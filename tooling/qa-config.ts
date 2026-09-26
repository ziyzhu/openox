import { parseArgs, type ParseArgsOptionsConfig } from "node:util";

export const targetedQaDevice = "ox-qa-1";

export function qaConfig(device: string) {
  const index = Number(/^ox-qa-([1-5])$/.exec(device)?.[1]);
  if (!index) throw new Error(`QA device must be ox-qa-N for N from 1 to 5, got ${device}; ox-qa is reserved for the human operator`);
  return {
    device,
    serviceProxyPort: 7100 + index,
    registryPort: 8100 + index,
    debugPort: 9100 + index,
    debugEndpoint: `ws://127.0.0.1:${9100 + index}`,
  };
}

type QaCommand<T extends ParseArgsOptionsConfig> = {
  usage: string;
  options?: T;
  positionals?: number;
  defaultDevice?: string;
};

export function qaCommand<T extends ParseArgsOptionsConfig>(command: QaCommand<T>) {
  const { values, positionals } = parseArgs({
    args: Bun.argv.slice(2),
    options: { ...command.options, device: { type: "string" }, help: { type: "boolean", short: "h" } } as T & {
      device: { type: "string" };
      help: { type: "boolean"; short: "h" };
    },
    allowPositionals: true,
    strict: true,
  });
  const { device = Bun.env.OX_QA_DEVICE ?? command.defaultDevice, help } = values as { device?: string; help?: boolean };
  if (help) {
    console.log(command.usage);
    process.exit(0);
  }
  if (positionals.length > (command.positionals ?? 0)) throw new Error(`Unexpected argument ${positionals.at(-1)}\n${command.usage}`);
  if (!device) throw new Error("Pass --device ox-qa-N or set OX_QA_DEVICE");
  return { ...qaConfig(device), values, positionals };
}
