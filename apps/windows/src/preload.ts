import { contextBridge, ipcRenderer } from "electron";
import type { TransportState } from "./host/transport.ts";

contextBridge.exposeInMainWorld("ox", {
  rpc: (text: string): Promise<unknown> => ipcRenderer.invoke("ox:rpc", text),
  transport: (): Promise<TransportState> => ipcRenderer.invoke("ox:transport"),
  onTransport: (listener: (state: TransportState) => void) => {
    ipcRenderer.on("ox:transport", (_event, state: TransportState) => listener(state));
  },
});
