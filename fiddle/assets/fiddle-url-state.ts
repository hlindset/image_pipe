import {
  defaultNativeState,
  nativeBrowserPath,
  parseNativeTail,
  type NativeState,
} from "./native-path";

export type AppState = { native: NativeState };

export function defaultAppState(): AppState {
  return { native: { ...defaultNativeState } };
}

export function appPathForState(state: AppState): string {
  return nativeBrowserPath(state.native);
}

export function parseAppPath(pathname: string): AppState {
  const [, prefix = "", ...rest] = pathname.split("/");

  if (prefix !== "native") return defaultAppState();

  const [candidate, ...tail] = rest;
  const protection =
    candidate === "signed" || candidate === "signed-concealed" ? candidate : "unsigned";
  const requestTail = protection === "unsigned" ? rest : tail;
  const native = parseNativeTail(requestTail.join("/"));

  return {
    native: native === null ? { ...defaultNativeState } : { ...native, protection },
  };
}
