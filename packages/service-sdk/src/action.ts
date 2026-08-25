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
  lib: {
    cookie: (name: string) => string | null;
    cleanText: (value: unknown) => string;
    pageCursor: (value: string | undefined, firstPage: number) => number;
  };
}

export type ActionInstaller = (api: ActionInstallApi) => void;
