import type { Offer, PairingResult, ReceiverSnapshot } from "./types";

type InvokeFn = <T>(cmd: string, args?: Record<string, unknown>) => Promise<T>;
type ListenFn = (
  event: string,
  handler: (event: { payload: unknown }) => void,
) => Promise<() => void>;

let invokeFn: InvokeFn | undefined;
let listenFn: ListenFn | undefined;
let resolved = false;

async function resolveBridge(): Promise<void> {
  if (resolved) return;
  resolved = true;
  try {
    const core = await import("@tauri-apps/api/core");
    invokeFn = core.invoke as InvokeFn;
  } catch {
    invokeFn = window.__TAURI__?.core.invoke;
  }
  try {
    const events = await import("@tauri-apps/api/event");
    listenFn = events.listen as ListenFn;
  } catch {
    listenFn = window.__TAURI__?.event.listen;
  }
}

export async function invokeCommand<T>(
  cmd: string,
  args?: Record<string, unknown>,
): Promise<T> {
  await resolveBridge();
  if (!invokeFn) {
    throw new Error("Tauri API unavailable in this window.");
  }
  return invokeFn<T>(cmd, args);
}

export async function listenEvent(
  event: string,
  handler: (payload: unknown) => void,
): Promise<() => void> {
  await resolveBridge();
  if (!listenFn) {
    throw new Error("Tauri API unavailable in this window.");
  }
  return listenFn(event, (event) => handler(event.payload));
}

export function isTauriAvailable(): boolean {
  return Boolean(window.__TAURI__?.core.invoke);
}

export const commands = {
  localState: () => invokeCommand<ReceiverSnapshot>("local_state"),
  state: () => invokeCommand<ReceiverSnapshot>("state"),
  beginPairing: (address: string) =>
    invokeCommand<Offer>("begin_pairing", { address }),
  confirmPairing: () => invokeCommand<PairingResult>("confirm_pairing"),
  cancelPairing: () => invokeCommand<void>("cancel_pairing"),
  unpair: () => invokeCommand<void>("unpair"),
  startService: () => invokeCommand<void>("start_service"),
  stopService: () => invokeCommand<void>("stop_service"),
  restartReceiver: () => invokeCommand<void>("restart_receiver"),
  chooseFiles: () => invokeCommand<string[]>("choose_files"),
  sendFiles: (paths: string[]) => invokeCommand<void>("send_files", { paths }),
  openFolder: (path = "") => invokeCommand<void>("open_folder", { path }),
};
