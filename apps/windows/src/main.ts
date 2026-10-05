import { app, BrowserWindow, ipcMain, shell } from "electron";
import { fileURLToPath } from "node:url";
import { WindowsHost } from "./host/host.ts";
import { log } from "./host/log.ts";
import { handleRPC } from "./host/rpc.ts";
import type { TransportState } from "./host/transport.ts";

// The desktop Client talks to its embedded Host through the same JSON-RPC handlers that remote Clients use.
let transport: TransportState = { status: "waiting" };
let window: BrowserWindow | undefined;
const host = new WindowsHost(undefined, state => {
  transport = state;
  window?.webContents.send("ox:transport", state);
});
const asset = (path: string) => fileURLToPath(new URL(path, import.meta.url));

if (!app.requestSingleInstanceLock()) app.quit();
app.on("second-instance", () => { window?.restore(); window?.focus(); });
app.on("window-all-closed", () => app.quit());
app.on("will-quit", () => host.stop());

app.whenReady().then(() => {
  ipcMain.handle("ox:rpc", (_event, text: string) => handleRPC(text, host.handlers));
  ipcMain.handle("ox:transport", () => transport);
  host.start();
  window = new BrowserWindow({
    width: 1100, height: 720, minWidth: 720, minHeight: 480, title: "Ox", backgroundColor: "#FFF6E6",
    webPreferences: { preload: asset("./preload.cjs"), contextIsolation: true, sandbox: true, nodeIntegration: false },
  });
  // The Client UI is local; links open in the user's browser, never inside the app window.
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith("https://")) void shell.openExternal(url);
    return { action: "deny" };
  });
  window.webContents.on("will-navigate", event => event.preventDefault());
  void window.loadFile(asset("../renderer/index.html"));
  log("info", "WindowsHost app ready", { version: app.getVersion() });
});
