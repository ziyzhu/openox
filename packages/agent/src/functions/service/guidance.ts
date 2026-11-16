import contracts from "./contracts.json";

export const guidance: Record<string, string> = {
  ...Object.fromEntries(Object.entries(contracts).map(([name, contract]) => [name, contract.description])),
  "namespace.service": "Inspect and invoke services for target domains. For websites, open or reuse a page and invoke actions with its current frameId. Only ox.web.browser.showPage presents the page; open and login stay in the background. The Host loads services on demand; use attach to add a conversation chip, listAttached to list attached services, and detach to remove one. Inspecting or invoking never adds chips. Attachments are context, not permissions. Existing implementations are reusable conveniences, not limits on domain access; build missing web or API actions through Evolve.",
};
