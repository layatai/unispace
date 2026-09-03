import { create } from "zustand";
import {
  isReceiverSnapshot,
  unpairedSnapshot,
  type Offer,
  type Panel,
  type Phase,
  type ReceiverSnapshot,
} from "@/lib/types";

/**
 * Where a snapshot came from.
 *
 * `local` is the config-only fallback (`local_state`, and the boot snapshot the
 * window evaluates before React mounts). It knows the workspace, the service
 * unit and uinput access, but it always reports `control: "disconnected"`, no
 * clipboard, no files and no transfers, because it never talks to the running
 * receiver. `live` is the receiver's own status line.
 *
 * Applying a `local` snapshot on top of a `live` one repaints the whole shell
 * as "Waiting", empties Transfers and re-adds the Restart button — which is
 * what made the window jump every couple of seconds.
 */
export type SnapshotSource = "live" | "local";

/**
 * A degraded snapshot (config-only, or a live read that timed out) has to be
 * seen this many times in a row before it replaces a good one. A single slow
 * status read is a blip, not a state change, and acting on it makes the UI
 * flicker.
 */
const DEGRADED_STRIKES = 2;

export interface ReceiverStore {
  snapshot: ReceiverSnapshot;
  phase: Phase;
  panel: Panel;
  offer: Offer | null;
  /** True once the receiver itself has reported status at least once. */
  live: boolean;
  pairError: string;
  confirmError: string;
  /** Errors raised by something the user just did (Start, Stop, Unpair…). */
  homeError: string;
  /** System notices carried on snapshots (service down, status read failed). */
  homeNotice: string;
  transferError: string;
  apply: (next: unknown, source?: SnapshotSource) => void;
  setPanel: (panel: Panel) => void;
  setOffer: (offer: Offer) => void;
  setPhase: (phase: Phase) => void;
  setPairError: (message: string) => void;
  setConfirmError: (message: string) => void;
  setHomeError: (message: string) => void;
  setHomeNotice: (message: string) => void;
  setTransferError: (message: string) => void;
  resetUnpaired: () => void;
}

let lastKey = "";
let degradedStreak = 0;

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
  live: false,
  pairError: "",
  confirmError: "",
  homeError: "",
  homeNotice: "",
  transferError: "",
  apply: (next, source = "live") => {
    if (!isReceiverSnapshot(next)) return;
    const prev = get();
    const notice = next.notice ?? "";
    // A snapshot carrying a notice is the receiver saying "this is my best
    // guess", whichever command produced it.
    const degraded = source === "local" || notice !== "";

    if (!degraded) {
      degradedStreak = 0;
    } else if (prev.live) {
      degradedStreak += 1;
      if (degradedStreak < DEGRADED_STRIKES) {
        // Hold the last good picture; only surface why it may be stale.
        if (prev.homeNotice !== notice) set({ homeNotice: notice });
        return;
      }
    }

    const key = JSON.stringify(next);
    if (key === lastKey) return;
    lastKey = key;
    const phase = next.paired
      ? "shell"
      : prev.phase === "confirm"
        ? "confirm"
        : "welcome";
    set({
      snapshot: shareSnapshot(prev.snapshot, next),
      phase,
      live: prev.live || !degraded,
      pairError: next.paired || phase === "confirm" ? "" : notice,
      homeNotice: next.paired ? notice : "",
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
  setHomeNotice: (homeNotice) => set({ homeNotice }),
  setTransferError: (transferError) => set({ transferError }),
  resetUnpaired: () => {
    lastKey = "";
    degradedStreak = 0;
    set({
      snapshot: unpairedSnapshot(),
      phase: "welcome",
      offer: null,
      live: false,
      pairError: "",
      confirmError: "",
      homeError: "",
      homeNotice: "",
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
    // The boot snapshot is read from the configuration file, not the receiver.
    useReceiverStore.getState().apply(window.__unispaceBoot, "local");
  }
}

export function resetStoreForTests(): void {
  lastKey = "";
  degradedStreak = 0;
  useReceiverStore.setState({
    snapshot: unpairedSnapshot(),
    phase: "welcome",
    panel: "home",
    offer: null,
    live: false,
    pairError: "",
    confirmError: "",
    homeError: "",
    homeNotice: "",
    transferError: "",
  });
}
