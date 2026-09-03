export function formatBytes(value: number | undefined | null): string {
  if (!value) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  let size = value;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return `${size >= 10 || unit === 0 ? Math.round(size) : size.toFixed(1)} ${units[unit]}`;
}

export function transferPercent(transfer: {
  bytesDone: number;
  bytesTotal: number;
  state: string;
}): number {
  if (transfer.bytesTotal) {
    return Math.min(100, Math.round((transfer.bytesDone / transfer.bytesTotal) * 100));
  }
  return transfer.state === "completed" ? 100 : 0;
}

export function stateLabel(state: string): string {
  if (state === "transferring") return "In progress";
  if (state === "completed") return "Completed";
  if (state === "failed") return "Failed";
  return state;
}

export function errorMessage(error: unknown): string {
  return String(error).replace(/^Error:\s*/, "");
}

export function connectionDetail(
  receiving: boolean,
  control: string,
  controllerName: string,
): string {
  const controller = controllerName || "Mac";
  if (receiving) return `Receiving from ${controller}`;
  if (control === "connected") return `Connected to ${controller}`;
  return `Waiting for ${controller}`;
}
