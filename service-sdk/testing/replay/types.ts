export type ReplayMatching = {
  ignoreQueryParameters?: string[];
  ignoreBodyParameters?: string[];
  matchHeaders?: string[];
};

export type ReplayCaseDefinition = {
  action: string;
  name: string;
  args: unknown;
  output?: unknown;
  error?: string;
  replay?: ReplayMatching;
};
