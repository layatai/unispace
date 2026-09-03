/// <reference types="vite/client" />

export {};

declare global {
  interface Window {
    __TAURI__?: {
      core: {
        invoke: <T>(cmd: string, args?: Record<string, unknown>) => Promise<T>;
      };
      event: {
        listen: (
          event: string,
          handler: (event: { payload: unknown }) => void,
        ) => Promise<() => void>;
      };
    };
    __unispaceBoot?: unknown;
    __unispaceApply?: (snapshot: unknown) => void;
    __unispaceSetPanel?: (name: string) => void;
  }
}
