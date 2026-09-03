import { describe, expect, it } from "vitest";
import { unpairedSnapshot } from "@/lib/types";
import { useReceiverStore } from "./receiver-store";

const paired = {
  ...unpairedSnapshot(),
  paired: true,
  workspaceName: "Studio",
  controllerName: "taimb2",
  hostAddress: "taimb2.tailnet",
  control: "connected" as const,
  notice: "socket slow",
};

describe("receiver store", () => {
  it("moves unpaired snapshots to welcome and routes the notice to the pair form", () => {
    useReceiverStore.getState().apply(unpairedSnapshot("offline"));
    const state = useReceiverStore.getState();
    expect(state.phase).toBe("welcome");
    expect(state.pairError).toBe("offline");
    expect(state.snapshot.paired).toBe(false);
  });

  it("moves paired snapshots to shell and routes the notice to Home", () => {
    useReceiverStore.getState().apply(paired);
    const state = useReceiverStore.getState();
    expect(state.phase).toBe("shell");
    expect(state.homeError).toBe("socket slow");
    expect(state.pairError).toBe("");
  });

  it("does not reapply an identical snapshot", () => {
    useReceiverStore.getState().apply(paired);
    useReceiverStore.getState().setHomeError("keep me");
    useReceiverStore.getState().apply(paired);
    expect(useReceiverStore.getState().homeError).toBe("keep me");
  });

  it("stays on confirm while unpaired if pairing is in progress", () => {
    useReceiverStore.getState().setOffer({ peerName: "Mac", code: "123456" });
    useReceiverStore.getState().apply(unpairedSnapshot());
    expect(useReceiverStore.getState().phase).toBe("confirm");
  });
});
