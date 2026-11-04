import contracts from "./contracts.json";

export const guidance: Record<string, string> = {
  ...Object.fromEntries(Object.entries(contracts).map(([name, contract]) => [name, contract.description])),
  "namespace.service": "Attach, inspect, and invoke services for target domains, and show their live pages for user review or interaction. Existing implementations are reusable conveniences, not limits on domain access; build missing web or API actions through Evolve.",
};
