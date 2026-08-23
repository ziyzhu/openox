import { el } from "./ui.ts";
import { loadConfig, setTarget, target } from "./ws.ts";

const POLL_MS = 5000;
const select = document.getElementById("sim-select") as HTMLSelectElement;

type Listener = { port: number; pid: number; process: string };
type Device = { name: string; udid: string; state: string; listeners: Listener[] };

function wsURL(port: number): string {
  return `ws://127.0.0.1:${port}`;
}

async function refresh() {
  const config = await loadConfig();
  const current = target() ?? config.debugWSURL;

  let devices: Device[] = [];
  let daemonUp = true;
  try {
    const res = await fetch(`${config.simDaemonURL}/devices`, { signal: AbortSignal.timeout(3000) });
    devices = ((await res.json()).devices ?? []) as Device[];
  } catch {
    daemonUp = false;
  }

  const options: HTMLOptionElement[] = [];
  const known = new Set<string>();
  for (const device of devices.filter((d) => d.state === "Booted")) {
    for (const listener of device.listeners) {
      const url = wsURL(listener.port);
      known.add(url);
      options.push(el("option", { value: url }, `${device.name} :${listener.port}`));
    }
  }
  if (!known.has(current)) {
    const label = current.replace("ws://", "") + (daemonUp ? " (not detected)" : "");
    options.unshift(el("option", { value: current }, label));
  }
  if (!daemonUp) {
    options.push(el("option", { value: "", disabled: "" }, "daemon offline: sim daemon"));
  }

  select.replaceChildren(...options);
  select.value = current;
}

select.addEventListener("change", () => {
  if (select.value) setTarget(select.value);
  void refresh();
});

void refresh();
setInterval(() => { void refresh(); }, POLL_MS);
