import { useEffect } from "react";
import { commands, listenEvent } from "@/lib/tauri";
import { errorMessage } from "@/lib/format";
import { isReceiverSnapshot } from "@/lib/types";
import { installApplyBridge, useReceiverStore } from "@/state/receiver-store";

export function useReceiverRuntime(): void {
  useEffect(() => {
    installApplyBridge();
    const apply = useReceiverStore.getState().apply;
    let unlisten: (() => void) | undefined;
    let timer: number | undefined;
    let cancelled = false;

    void (async () => {
      try {
        unlisten = await listenEvent("receiver-status", (payload) => {
          if (isReceiverSnapshot(payload)) apply(payload);
        });
      } catch (error) {
        if (!useReceiverStore.getState().snapshot.paired) {
          useReceiverStore.getState().setPairError(errorMessage(error));
        }
      }
      const refresh = async () => {
        try {
          apply(await commands.localState());
          apply(await commands.state());
        } catch (error) {
          const message = errorMessage(error);
          const { snapshot } = useReceiverStore.getState();
          if (snapshot.paired) {
            useReceiverStore.getState().setHomeError(message);
          } else {
            useReceiverStore.getState().setPairError(message);
          }
        }
      };
      await refresh();
      if (cancelled) return;
      timer = window.setInterval(() => {
        void refresh();
      }, 2000);
    })();

    return () => {
      cancelled = true;
      unlisten?.();
      if (timer) window.clearInterval(timer);
    };
  }, []);
}
