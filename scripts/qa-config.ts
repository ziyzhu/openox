type QaConfig = {
  device: string;
  serviceProxyPort: number;
  registryPort: number;
  debugPort: number;
};

export const targetedQaDevice = "ox-qa-1";

function qaIndex(device: string): number {
  const match = /^ox-qa(?:-([1-5]))?$/.exec(device);
  if (!match) throw new Error(`QA device must be ox-qa or ox-qa-N for N from 1 to 5, got ${device}`);
  return match[1] === undefined ? 0 : Number(match[1]);
}

function qaDevice(args: string[], environmentDevice: string | undefined): string {
  const index = args.indexOf("--device");
  const device = index >= 0 ? args[index + 1] : environmentDevice;
  if (device === undefined) throw new Error("Pass --device ox-qa-N or set OX_QA_DEVICE");
  qaIndex(device);
  return device;
}

export function qaNumberedDevice(args: string[], environmentDevice: string | undefined): string {
  const device = qaDevice(args, environmentDevice);
  if (device === "ox-qa") throw new Error("Use a numbered ox-qa-N device; ox-qa is reserved for the human operator");
  return device;
}

export function qaConfig(device: string): QaConfig {
  const index = qaIndex(device);
  return {
    device,
    serviceProxyPort: 7100 + index,
    registryPort: 8100 + index,
    debugPort: 9100 + index,
  };
}
