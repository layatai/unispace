import { beforeEach, describe, expect, it } from "vitest";
import { unpairedSnapshot } from "@/lib/types";
import { resetStoreForTests, useReceiverStore } from "./receiver-store";

const paired = {
  ...unpairedSnapshot(),
  paired: true,
  workspaceName: "Studio",
  controllerName: "taimb2",
  hostAddress: "taimb2.tailnet",
  control: "connected" as const,
};

const live = { ...paired, receiving: true, clipboard: true, files: true };

describe("receiver store", () => {
  beforeEach(() => {
    resetStoreForTests();
  });

  it("moves unpaired snapshots to welcome and routes the notice to the pair form", () => {
    useReceiverStore.getState().apply(unpairedSnapshot("offline"));
    const state = useReceiverStore.getState();
    expect(state.phase).toBe("welcome");
    expect(state.pairError).toBe("offline");
    expect(state.snapshot.paired).toBe(false);
  });

  it("moves paired snapshots to shell and routes the notice to Home", () => {
    useReceiverStore.getState().apply({ ...paired, notice: "socket slow" });
    const state = useReceiverStore.getState();
    expect(state.phase).toBe("shell");
    expect(state.homeNotice).toBe("socket slow");
    expect(state.pairError).toBe("");
  });

  it("does not reapply an identical snapshot", () => {
    useReceiverStore.getState().apply(paired);
    useReceiverStore.getState().setHomeNotice("keep me");
    useReceiverStore.getState().apply(paired);
    expect(useReceiverStore.getState().homeNotice).toBe("keep me");
  });

  it("stays on confirm while unpaired if pairing is in progress", () => {
    useReceiverStore.getState().setOffer({ peerName: "Mac", code: "123456" });
    useReceiverStore.getState().apply(unpairedSnapshot());
    expect(useReceiverStore.getState().phase).toBe("confirm");
  });

  it("keeps action errors and transfer identity when only receiving changes", () => {
    const transfers = [
      {
        id: "in-1",
        direction: "incoming" as const,
        displayName: "notes.txt",
        bytesDone: 12,
        bytesTotal: 40,
        state: "transferring" as const,
      },
    ];
    useReceiverStore.getState().apply({ ...paired, transfers });
    useReceiverStore.getState().setHomeError("keep me");
    const first = useReceiverStore.getState().snapshot.transfers;
    useReceiverStore.getState().apply({
      ...paired,
      transfers: [{ ...transfers[0] }],
      receiving: true,
    });
    expect(useReceiverStore.getState().homeError).toBe("keep me");
    expect(useReceiverStore.getState().snapshot.transfers).toBe(first);
    expect(useReceiverStore.getState().snapshot.receiving).toBe(true);
  });

  it("reuses unchanged transfer objects when another job progresses", () => {
    const incoming = {
      id: "in-1",
      direction: "incoming" as const,
      displayName: "notes.txt",
      bytesDone: 12,
      bytesTotal: 40,
      state: "transferring" as const,
    };
    const outgoing = {
      id: "out-1",
      direction: "outgoing" as const,
      displayName: "shot.png",
      bytesDone: 1,
      bytesTotal: 8,
      state: "transferring" as const,
    };
    useReceiverStore.getState().apply({ ...paired, transfers: [incoming, outgoing] });
    const [firstIncoming, firstOutgoing] = useReceiverStore.getState().snapshot.transfers;
    useReceiverStore.getState().apply({
      ...paired,
      transfers: [incoming, { ...outgoing, bytesDone: 4 }],
    });
    const [nextIncoming, nextOutgoing] = useReceiverStore.getState().snapshot.transfers;
    expect(nextIncoming).toBe(firstIncoming);
    expect(nextOutgoing).not.toBe(firstOutgoing);
    expect(nextOutgoing.bytesDone).toBe(4);
  });

  it("ignores the config-only snapshot once the receiver has reported", () => {
    useReceiverStore.getState().apply(live);
    useReceiverStore.getState().apply(paired, "local");
    const state = useReceiverStore.getState();
    expect(state.snapshot.receiving).toBe(true);
    expect(state.snapshot.clipboard).toBe(true);
    expect(state.live).toBe(true);
  });

  it("holds the last live state through a single degraded read", () => {
    useReceiverStore.getState().apply(live);
    useReceiverStore.getState().apply({ ...paired, notice: "status read timed out" });
    const state = useReceiverStore.getState();
    expect(state.snapshot.receiving).toBe(true);
    expect(state.homeNotice).toBe("status read timed out");
  });

  it("accepts a degraded state once it repeats", () => {
    useReceiverStore.getState().apply(live);
    useReceiverStore.getState().apply({ ...paired, notice: "service is not running" });
    useReceiverStore.getState().apply({
      ...paired,
      notice: "service is not running",
      serviceRunning: false,
    });
    const state = useReceiverStore.getState();
    expect(state.snapshot.receiving).toBe(false);
    expect(state.snapshot.serviceRunning).toBe(false);
  });

  it("takes the config-only snapshot before the receiver has reported", () => {
    useReceiverStore.getState().apply(paired, "local");
    expect(useReceiverStore.getState().phase).toBe("shell");
    expect(useReceiverStore.getState().snapshot.workspaceName).toBe("Studio");
    expect(useReceiverStore.getState().live).toBe(false);
  });
});
