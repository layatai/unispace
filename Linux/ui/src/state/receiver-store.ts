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
    const phase = next.paired
      ? "shell"
      : get().phase === "confirm"
        ? "confirm"
        : "welcome";
    set({
      snapshot: next,
      phase,
      pairError: next.paired || phase === "confirm" ? "" : (next.notice ?? ""),
      homeError: next.paired ? (next.notice ?? "") : "",
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
