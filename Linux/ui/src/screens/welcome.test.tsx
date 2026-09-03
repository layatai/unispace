import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { Welcome } from "./welcome";
import { ConfirmPairing } from "./confirm-pairing";
import { useReceiverStore } from "@/state/receiver-store";

describe("Welcome", () => {
  it("asks for a controller address before pairing", async () => {
    const user = userEvent.setup();
    render(<Welcome />);
    await user.click(screen.getByRole("button", { name: "Connect" }));
    expect(
      screen.getByText("Enter the controller Mac hostname or address."),
    ).toBeTruthy();
  });
});

describe("ConfirmPairing", () => {
  it("renders pairing code tiles from the offer", () => {
    useReceiverStore.getState().setOffer({ peerName: "taimb2", code: "123456" });
    render(<ConfirmPairing />);
    expect(screen.getByText(/Check that taimb2 is showing this same code/)).toBeTruthy();
    expect(screen.getByText("1")).toBeTruthy();
    expect(screen.getByText("6")).toBeTruthy();
  });
});
