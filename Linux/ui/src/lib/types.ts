export type ControlState = "connected" | "disconnected";
export type TransferDirection = "incoming" | "outgoing";
export type TransferState = "transferring" | "completed" | "failed";
export type Panel = "home" | "transfers" | "clipboard";
export type Phase = "welcome" | "confirm" | "shell";

export interface TransferSnapshot {
  id: string;
  direction: TransferDirection;
  displayName: string;
  bytesDone: number;
  bytesTotal: number;
  state: TransferState;
  directory?: string;
}

export interface ReceiverSnapshot {
  paired: boolean;
  notice?: string;
  workspaceName: string;
  controllerName: string;
  hostAddress: string;
  control: ControlState;
  receiving: boolean;
  clipboard: boolean;
  files: boolean;
  uinputReady: boolean;
  serviceRunning: boolean;
  transfers: TransferSnapshot[];
}

export interface Offer {
  peerName: string;
  code: string;
}

export interface PairingResult {
  state: ReceiverSnapshot;
  warning?: string;
}

export function unpairedSnapshot(notice?: string): ReceiverSnapshot {
  return {
    paired: false,
    notice,
    workspaceName: "",
    controllerName: "",
    hostAddress: "",
    control: "disconnected",
    receiving: false,
    clipboard: false,
    files: false,
    uinputReady: false,
    serviceRunning: false,
    transfers: [],
  };
}

export function isReceiverSnapshot(value: unknown): value is ReceiverSnapshot {
  return !!value && typeof value === "object" && "paired" in value;
}
