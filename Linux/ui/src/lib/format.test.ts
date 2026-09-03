import { describe, expect, it } from "vitest";
import { formatBytes, transferPercent } from "./format";

describe("formatBytes", () => {
  it("formats empty values as 0 B", () => {
    expect(formatBytes(0)).toBe("0 B");
    expect(formatBytes(undefined)).toBe("0 B");
  });

  it("uses whole numbers for values of 10 or more", () => {
    expect(formatBytes(12 * 1024)).toBe("12 KB");
  });

  it("keeps one decimal below 10 of a unit", () => {
    expect(formatBytes(1536)).toBe("1.5 KB");
  });
});

describe("transferPercent", () => {
  it("uses bytes when a total is known", () => {
    expect(
      transferPercent({ bytesDone: 50, bytesTotal: 200, state: "transferring" }),
    ).toBe(25);
  });

  it("is 100 when completed without a total", () => {
    expect(transferPercent({ bytesDone: 0, bytesTotal: 0, state: "completed" })).toBe(100);
  });
});
