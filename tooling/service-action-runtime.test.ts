import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { ROOT } from "./lib.ts";

type RuntimeWindow = {
  location: { href: string };
  fetch: typeof fetch;
  ox?: {
    install: (version: number, installer: (api: any) => void) => void;
    callServiceAction: (name: string, args?: unknown) => Promise<unknown>;
  };
  __openOxCreateServiceRuntime?: (domain: string) => RuntimeWindow["ox"];
};

const source = await Bun.file(join(ROOT, "apps/ios/Ox/Host/Services/Web/ServiceActionRuntime.js")).text();

function runtime(): NonNullable<RuntimeWindow["ox"]> {
  const target: RuntimeWindow = {
    location: { href: "https://example.com/" },
    fetch,
  };
  new Function("window", source)(target);
  return target.__openOxCreateServiceRuntime!("example.com")!;
}

describe("service action runtime", () => {
  test("installs and invokes ABI version 1 actions with the shared library", async () => {
    const ox = runtime();
    ox.install(1, ({ action, lib }) => {
      action("normalize", {
        invoke: ({ value }: { value: unknown }) => ({ value: lib.cleanText(value) }),
      });
    });

    expect(await ox.callServiceAction("normalize", { value: "  hello   world " })).toEqual({
      value: "hello world",
    });
  });

  test("rejects unsupported ABIs and duplicate installation", () => {
    expect(() => runtime().install(2, () => {})).toThrow("unsupported service action ABI");
    const ox = runtime();
    ox.install(1, () => {});
    expect(() => ox.install(1, () => {})).toThrow("service installer may run only once");
  });
});
