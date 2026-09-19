import { defaultApiState, apiBrowserPath, parseApiTail, type ApiState } from "./api-path";

export type AppState = { api: ApiState };

export function defaultAppState(): AppState {
  return { api: { ...defaultApiState } };
}

export function appPathForState(state: AppState): string {
  return apiBrowserPath(state.api);
}

export function parseAppPath(pathname: string): AppState {
  const [, prefix = "", ...rest] = pathname.split("/");

  if (prefix !== "edit") return defaultAppState();

  const [candidate, ...tail] = rest;
  const protection =
    candidate === "signed" || candidate === "signed-concealed" ? candidate : "unsigned";
  const requestTail = protection === "unsigned" ? rest : tail;
  const api = parseApiTail(requestTail.join("/"));

  return {
    api: api === null ? { ...defaultApiState } : { ...api, protection },
  };
}
