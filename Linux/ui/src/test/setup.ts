import { cleanup } from "@testing-library/react";
import { afterEach, beforeEach, vi } from "vitest";
import { resetStoreForTests } from "@/state/receiver-store";

vi.mock("@tauri-apps/api/core", () => ({
  invoke: vi.fn(async () => undefined),
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async () => () => {}),
  emit: vi.fn(async () => {}),
}));

beforeEach(() => {
  resetStoreForTests();
});

afterEach(() => {
  cleanup();
});
