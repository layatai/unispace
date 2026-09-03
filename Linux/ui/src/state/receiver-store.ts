import { create } from "zustand";
import {
  isReceiverSnapshot,
  unpairedSnapshot,
  type Offer,
  type Panel,
  type Phase,
  type ReceiverSnapshot,
} from "@/lib/types";

export interface ReceiverStore {
  snapshot: ReceiverSnapshot;
  phase: Phase;
  panel: Panel;
  offer: Offer | null;
  pairError: string;
  confirmError: string;
  homeError: string;
  transferError: string;
  apply: (next: unknown) => void;
  setPanel: (panel: Panel) => void;
  setOffer: (offer: Offer) => void;
  setPhase: (phase: Phase) => void;
  setPairError: (message: string) => void;
  setConfirmError: (message: string) => void;
  setHomeError: (message: string) => void;
  setTransferError: (message: string) => void;
  resetUnpaired: () => void;
}

let lastKey = "";

function sameTransfer(left: ReceiverSnapshot["transfers"][number], right: ReceiverSnapshot["transfers"][number]): boolean {
  return (
    left.id === right.id &&
    left.direction === right.direction &&
    left.displayName === right.displayName &&
    left.bytesDone === right.bytesDone &&
    left.bytesTotal === right.bytesTotal &&
    left.state === right.state &&
    (left.directory ?? "") === (right.directory ?? "")
  );
}

function shareTransfers(
  prev: ReceiverSnapshot["transfers"] | undefined,
  next: ReceiverSnapshot["transfers"] | undefined,
): ReceiverSnapshot["transfers"] {
  const before = prev ?? [];
  const after = next ?? [];
  if (before.length === after.length && before.every((item, index) => sameTransfer(item, after[index]))) {
    return before;
  }
  return after.map((item) => {
    const old = before.find((transfer) => transfer.id === item.id);
    return old && sameTransfer(old, item) ? old : item;
  });
}

function shareSnapshot(prev: ReceiverSnapshot, next: ReceiverSnapshot): ReceiverSnapshot {
  return {
    ...next,
    transfers: shareTransfers(prev.transfers, next.transfers),
  };
}

export const useReceiverStore = create<ReceiverStore>((set, get) => ({
  snapshot: unpairedSnapshot(),
  phase: "welcome",
  panel: "home",
  offer: null,
  pairError: "",
  confirmError: "",
  homeError: "",
  transferError: "",
  apply: (next) => {
    if (!isReceiverSnapshot(next)) return;
    const key = JSON.stringify(next);
    if (key === lastKey) return;
    lastKey = key;
    const prev = get();
    const phase = next.paired
      ? "shell"
      : prev.phase === "confirm"
        ? "confirm"
        : "welcome";
    const notice = next.notice ?? "";
    const noticeChanged = (prev.snapshot.notice ?? "") !== (next.notice ?? "");
    set({
      snapshot: shareSnapshot(prev.snapshot, next),
      phase,
      pairError: next.paired || phase === "confirm" ? "" : notice,
      homeError: next.paired ? (noticeChanged ? notice : prev.homeError) : "",
    });
  },
  setPanel: (panel) => {
    if (panel === "home" || panel === "transfers" || panel === "clipboard") {
      set({ panel });
    }
  },
  setOffer: (offer) => set({ offer, phase: "confirm", confirmError: "", pairError: "" }),
  setPhase: (phase) => set({ phase }),
  setPairError: (pairError) => set({ pairError }),
  setConfirmError: (confirmError) => set({ confirmError }),
  setHomeError: (homeError) => set({ homeError }),
  setTransferError: (transferError) => set({ transferError }),
  resetUnpaired: () => {
    lastKey = "";
    set({
      snapshot: unpairedSnapshot(),
      phase: "welcome",
      offer: null,
      pairError: "",
      confirmError: "",
      homeError: "",
      transferError: "",
    });
  },
}));

export function installApplyBridge(): void {
  window.__unispaceApply = (snapshot) => {
    useReceiverStore.getState().apply(snapshot);
  };
  window.__unispaceSetPanel = (name) => {
    useReceiverStore.getState().setPanel(name as Panel);
  };
  if (window.__unispaceBoot) {
    useReceiverStore.getState().apply(window.__unispaceBoot);
  }
}

export function resetStoreForTests(): void {
  lastKey = "";
  useReceiverStore.setState({
    snapshot: unpairedSnapshot(),
    phase: "welcome",
    panel: "home",
    offer: null,
    pairError: "",
    confirmError: "",
    homeError: "",
    transferError: "",
  });
}
