import contracts from "./contracts.json";

export const guidance: Record<string, string> = {
  ...Object.fromEntries(Object.entries(contracts).map(([name, contract]) => [name, contract.description])),
  "namespace.service": "Inspect and invoke services for target domains. For websites, open or reuse a page and invoke actions with its current frameId. Only ox.web.browser.showPage presents the page; open and login stay in the background. Invocation automatically attaches its service to the conversation when needed, under normal attachment policy. Use attach to add context explicitly, listAttached to list attached services, and detach to remove one. Inspection does not attach services. Attachment does not grant action approval or authentication. Existing implementations are reusable conveniences, not limits on domain access; build missing web or API actions through Evolve.",
};
