import { useEffect } from "react";
import { commands, listenEvent } from "@/lib/tauri";
import { errorMessage } from "@/lib/format";
import { isReceiverSnapshot } from "@/lib/types";
import { installApplyBridge, useReceiverStore } from "@/state/receiver-store";

/** How often to ask for status when nothing is being pushed to us. */
const POLL_INTERVAL_MS = 3000;
/** Skip a poll if the receiver pushed status more recently than this. */
const PUSH_GRACE_MS = 5000;

export function useReceiverRuntime(): void {
  useEffect(() => {
    installApplyBridge();
    const store = useReceiverStore;
    let unlisten: (() => void) | undefined;
    let timer: number | undefined;
    let cancelled = false;
    let lastPushAt = 0;

    void (async () => {
      // Paint from the on-disk configuration once, so a paired machine shows
      // its workspace immediately. Never again: this snapshot cannot see the
      // live connection, and re-applying it is what made the window jump.
      try {
        store.getState().apply(await commands.localState(), "local");
      } catch {
        // The poll below reports anything that is actually wrong.
      }

      try {
        unlisten = await listenEvent("receiver-status", (payload) => {
          if (!isReceiverSnapshot(payload)) return;
          lastPushAt = Date.now();
          store.getState().apply(payload);
        });
      } catch (error) {
        if (!store.getState().snapshot.paired) {
          store.getState().setPairError(errorMessage(error));
        }
      }

      const refresh = async () => {
        // The receiver pushes `receiver-status` whenever it changes; polling is
        // only a safety net for when that stream is not delivering.
        if (Date.now() - lastPushAt < PUSH_GRACE_MS) return;
        try {
          store.getState().apply(await commands.state());
        } catch (error) {
          const message = errorMessage(error);
          if (store.getState().snapshot.paired) {
            store.getState().setHomeNotice(message);
          } else {
            store.getState().setPairError(message);
          }
        }
      };
      await refresh();
      if (cancelled) return;
      timer = window.setInterval(() => {
        void refresh();
      }, POLL_INTERVAL_MS);
    })();

    return () => {
      cancelled = true;
      unlisten?.();
      if (timer) window.clearInterval(timer);
    };
  }, []);
}
