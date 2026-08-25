export interface ActionInstallApi {
  action: (name: string, def: {
    invoke: (args: any) => unknown | Promise<unknown>;
  }) => void;
  retryFetch: (
    input: RequestInfo | string,
    init?: RequestInit,
    opts?: { retries?: number; delay?: number; factor?: number },
  ) => Promise<Response>;
  log: (msg: string) => void;
}

export type ActionInstaller = (api: ActionInstallApi) => void;
