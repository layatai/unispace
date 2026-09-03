import { act } from "react";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { unpairedSnapshot } from "@/lib/types";
import { useReceiverStore } from "@/state/receiver-store";
import { Shell } from "./shell";

const paired = {
  ...unpairedSnapshot(),
  paired: true,
  workspaceName: "Studio",
  controllerName: "taimb2",
  hostAddress: "taimb2.tailnet",
  control: "connected" as const,
};

describe("Shell", () => {
  it("keeps Home local state when receiving updates", async () => {
    const user = userEvent.setup();
    useReceiverStore.getState().apply(paired);
    render(<Shell />);
    await user.click(screen.getByRole("button", { name: "Unpair…" }));
    expect(screen.getByRole("alertdialog")).toBeTruthy();
    act(() => {
      useReceiverStore.getState().apply({ ...paired, receiving: true });
    });
    expect(screen.getByRole("alertdialog")).toBeTruthy();
    expect(screen.getByText("Receiving")).toBeTruthy();
  });
});
