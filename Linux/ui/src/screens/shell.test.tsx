import { act, type ReactElement } from "react";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { TooltipProvider } from "@/components/ui/tooltip";
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
  serviceRunning: true,
  uinputReady: true,
};

const transfer = {
  id: "in-1",
  direction: "incoming" as const,
  displayName: "notes.txt",
  bytesDone: 12,
  bytesTotal: 40,
  state: "transferring" as const,
};

function renderShell(): ReturnType<typeof render> {
  const tree: ReactElement = (
    <TooltipProvider>
      <Shell />
    </TooltipProvider>
  );
  return render(tree);
}

/** The class names that decide a node's size, ignoring colour and state. */
function shape(node: Element): string {
  return Array.from(node.classList)
    .filter((name) => /^(w-|h-|min-w|min-h|max-w|size-|grid-cols)/.test(name))
    .sort()
    .join(" ");
}

function shapes(container: HTMLElement, selector: string): string[] {
  return Array.from(container.querySelectorAll(selector)).map(shape);
}

describe("Shell", () => {
  it("keeps Home local state when receiving updates", async () => {
    const user = userEvent.setup();
    useReceiverStore.getState().apply(paired);
    renderShell();
    await user.click(screen.getByRole("button", { name: "Unpair…" }));
    expect(screen.getByRole("alertdialog")).toBeTruthy();
    act(() => {
      useReceiverStore.getState().apply({ ...paired, receiving: true });
    });
    expect(screen.getByRole("alertdialog")).toBeTruthy();
    expect(screen.getAllByText("Receiving").length).toBeGreaterThan(0);
  });

  it("does not resize any status slot when the connection changes", () => {
    useReceiverStore.getState().apply(paired);
    const { container } = renderShell();
    const before = {
      pills: shapes(container, "[data-slot=status-pill]"),
      values: shapes(container, "[data-slot=row-status]"),
      rows: shapes(container, "[data-slot=status-row]"),
      actions: shapes(container, "[data-slot=row-action]"),
      header: shape(container.querySelector("header") as Element),
    };

    act(() => {
      useReceiverStore.getState().apply({
        ...paired,
        receiving: true,
        clipboard: true,
        files: true,
        transfers: [transfer],
      });
    });

    expect(shapes(container, "[data-slot=status-pill]")).toEqual(before.pills);
    expect(shapes(container, "[data-slot=row-status]")).toEqual(before.values);
    expect(shapes(container, "[data-slot=status-row]")).toEqual(before.rows);
    expect(shapes(container, "[data-slot=row-action]")).toEqual(before.actions);
    expect(shape(container.querySelector("header") as Element)).toBe(before.header);
  });

  it("keeps the row action slot reserved when a button disappears", () => {
    useReceiverStore.getState().apply({ ...paired, serviceRunning: false, uinputReady: false });
    const { container } = renderShell();
    expect(container.querySelectorAll("[data-slot=row-action]").length).toBe(3);
    expect(screen.getByRole("button", { name: "Restart" })).toBeTruthy();

    act(() => {
      useReceiverStore.getState().apply(paired);
    });
    expect(container.querySelectorAll("[data-slot=row-action]").length).toBe(3);
    expect(screen.queryByRole("button", { name: "Restart" })).toBeNull();
  });

  it("keeps a message slot in Home whether or not there is a message", () => {
    useReceiverStore.getState().apply(paired);
    const { container } = renderShell();
    const slot = container.querySelector("[data-slot=status-message]") as HTMLElement;
    expect(slot).toBeTruthy();
    expect(slot.textContent).toBe("");

    act(() => {
      useReceiverStore.getState().apply({ ...paired, notice: "service is not running" });
    });
    expect(
      (container.querySelector("[data-slot=status-message]") as HTMLElement).textContent,
    ).toBe("service is not running");
  });

  it("does not blank live status when a config-only snapshot arrives", () => {
    useReceiverStore.getState().apply({
      ...paired,
      receiving: true,
      files: true,
      transfers: [transfer],
    });
    renderShell();
    expect(screen.getAllByText("notes.txt").length).toBe(1);

    act(() => {
      useReceiverStore.getState().apply(paired, "local");
    });
    expect(screen.getAllByText("notes.txt").length).toBe(1);
    expect(screen.getAllByText("Receiving").length).toBeGreaterThan(0);
  });
});
