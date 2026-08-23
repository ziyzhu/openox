export const MAX_CI_SIMULATORS = 3;

export function ciSimulatorCount(args: string[], environmentValue: string | undefined): number {
  const index = args.indexOf("--simulators");
  const value = index >= 0 ? args[index + 1] : environmentValue;
  if (value === undefined && index < 0) return MAX_CI_SIMULATORS;
  if (value === undefined || !/^[1-9]\d*$/.test(value)) {
    throw new Error(`CI simulator count must be an integer from 1 to ${MAX_CI_SIMULATORS}, got ${value ?? "no value"}`);
  }
  const count = Number(value);
  if (count > MAX_CI_SIMULATORS) {
    throw new Error(`CI simulator count must be an integer from 1 to ${MAX_CI_SIMULATORS}, got ${value}`);
  }
  return count;
}
