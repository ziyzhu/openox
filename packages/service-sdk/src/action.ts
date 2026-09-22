export interface ActionRegistrationApi {
  action: (name: string, def: {
    invoke: (args: any) => unknown | Promise<unknown>;
  }) => void;
}

export interface LegacyActionInstallApi extends ActionRegistrationApi {
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

export type ActionInstallApi = LegacyActionInstallApi;
export type ActionInstaller = (api: LegacyActionInstallApi) => void;
export type WebActionInstaller = (api: ActionRegistrationApi) => void;
export type APIActionInstaller = (api: ActionRegistrationApi & {
  request: (args: {
    path: string;
    method?: string;
    query?: Record<string, string | number | boolean | null | undefined>;
    json?: unknown;
  }) => Promise<unknown>;
}) => void;
