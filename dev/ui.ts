export function el<T extends HTMLElement = HTMLElement>(
  tag: string,
  props: Record<string, string | ((event: Event) => void)> = {},
  ...children: (Node | string)[]
): T {
  const element = document.createElement(tag) as T;
  for (const [key, value] of Object.entries(props)) {
    if (typeof value === "function") element.addEventListener(key, value);
    else if (key === "class") element.className = value;
    else if (key === "html") element.innerHTML = value;
    else element.setAttribute(key, value);
  }
  for (const child of children) {
    element.append(typeof child === "string" ? document.createTextNode(child) : child);
  }
  return element;
}

type Tab = "chat" | "services" | "agent" | "diagnostics" | "logs" | "registry";

const tabs = [...document.querySelectorAll<HTMLButtonElement>(".tab")];
const views = new Map<Tab, HTMLElement>(tabs.flatMap((tab) => {
  const name = tab.dataset.tab as Tab;
  const view = document.getElementById(`view-${name}`);
  return view ? [[name, view]] : [];
}));
const handlers = new Map<Tab, Set<() => void>>();
const TAB_KEY = "dev.tab";
const saved = sessionStorage.getItem(TAB_KEY) as Tab | null;
let active: Tab = saved && views.has(saved) ? saved : "chat";

function activate(next: Tab) {
  active = next;
  sessionStorage.setItem(TAB_KEY, next);
  for (const tab of tabs) tab.setAttribute("aria-current", String(tab.dataset.tab === next));
  for (const [name, view] of views) view.hidden = name !== next;
  for (const handler of handlers.get(next) ?? []) handler();
}

for (const tab of tabs) {
  tab.addEventListener("click", () => activate(tab.dataset.tab as Tab));
}
activate(active);

export function onTab(tab: Tab, handler: () => void) {
  const set = handlers.get(tab) ?? new Set();
  set.add(handler);
  handlers.set(tab, set);
  if (active === tab) handler();
  return () => set.delete(handler);
}
