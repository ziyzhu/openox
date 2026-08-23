const RECONNECT_MS = 1000;
const TARGET_KEY = "dev.wsTarget";

type State = "connecting" | "open" | "closed";
type MessageHandler = (msg: any) => void;
type StateHandler = (state: State) => void;

type Config = { debugWSURL: string; simDaemonURL: string };

let ws: WebSocket | null = null;
let state: State = "closed";
let generation = 0;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
const messageHandlers = new Set<MessageHandler>();
const stateHandlers = new Set<StateHandler>();
const sendQueue: string[] = [];

let configPromise: Promise<Config> | null = null;

export function loadConfig(): Promise<Config> {
  configPromise ??= fetch("/config").then((response) => response.json());
  return configPromise;
}

export function target(): string | null {
  return sessionStorage.getItem(TARGET_KEY);
}

export function setTarget(url: string | null) {
  if (url) sessionStorage.setItem(TARGET_KEY, url);
  else sessionStorage.removeItem(TARGET_KEY);
  sendQueue.length = 0;
  if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
  const old = ws;
  ws = null;
  generation++;
  old?.close();
  void connect();
}

function setState(next: State) {
  if (state === next) return;
  state = next;
  for (const h of stateHandlers) h(state);
}

function retryLater(gen: number) {
  if (gen !== generation) return;
  setState("closed");
  reconnectTimer = setTimeout(() => { void connect(); }, RECONNECT_MS);
}

async function connect() {
  const gen = ++generation;
  setState("connecting");
  let url = target();
  if (!url) {
    try { url = (await loadConfig()).debugWSURL; }
    catch { retryLater(gen); return; }
  }
  if (gen !== generation) return;
  const socket = new WebSocket(url);
  ws = socket;
  socket.addEventListener("open", () => {
    if (gen !== generation) return;
    setState("open");
    while (sendQueue.length && socket.readyState === WebSocket.OPEN) {
      socket.send(sendQueue.shift()!);
    }
  });
  socket.addEventListener("message", (e) => {
    if (gen !== generation) return;
    let msg: any;
    try { msg = JSON.parse(typeof e.data === "string" ? e.data : ""); }
    catch { return; }
    for (const h of messageHandlers) h(msg);
  });
  socket.addEventListener("close", () => retryLater(gen));
  socket.addEventListener("error", () => { /* close handler will reconnect */ });
}

void connect();

export function subscribe(handler: MessageHandler): () => void {
  messageHandlers.add(handler);
  return () => messageHandlers.delete(handler);
}

export function onState(handler: StateHandler): () => void {
  stateHandlers.add(handler);
  handler(state);
  return () => stateHandlers.delete(handler);
}

export function send(envelope: unknown): void {
  const data = JSON.stringify(envelope);
  if (ws?.readyState === WebSocket.OPEN) ws.send(data);
  else sendQueue.push(data);
}

const pending = new Map<string, (msg: any) => void>();
subscribe((msg) => {
  if (typeof msg?.id !== "string") return;
  const cb = pending.get(msg.id);
  if (!cb) return;
  pending.delete(msg.id);
  cb(msg);
});

export function request(kind: string, args: Record<string, unknown> = {}, timeoutMs = 10000): Promise<any> {
  const id = crypto.randomUUID();
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      if (pending.delete(id)) resolve({ ok: false, error: `timeout after ${timeoutMs}ms (is the iOS app running on the sim?)` });
    }, timeoutMs);
    pending.set(id, (msg) => { clearTimeout(timer); resolve(msg); });
    send({ kind, id, ...args });
  });
}
