import { describe, expect, test } from "bun:test";
import { qaConfig, qaNumberedDevice } from "./qa-config.ts";

describe("QA simulator pool", () => {
  test("accepts numbered devices from one through five", () => {
    expect(qaNumberedDevice(["--device", "ox-qa-1"], undefined)).toBe("ox-qa-1");
    expect(qaNumberedDevice(["--device", "ox-qa-5"], undefined)).toBe("ox-qa-5");
    expect(qaConfig("ox-qa-5")).toEqual({
      device: "ox-qa-5",
      serviceProxyPort: 7105,
      registryPort: 8105,
      debugPort: 9105,
    });
  });

  test("rejects numbered devices outside the pool", () => {
    expect(() => qaNumberedDevice(["--device", "ox-qa-6"], undefined)).toThrow("N from 1 to 5");
    expect(() => qaNumberedDevice(["--device", "ox-qa-99"], undefined)).toThrow("N from 1 to 5");
  });

  test("reserves the unnumbered device for the human operator", () => {
    expect(() => qaNumberedDevice(["--device", "ox-qa"], undefined)).toThrow("reserved for the human operator");
  });
});
