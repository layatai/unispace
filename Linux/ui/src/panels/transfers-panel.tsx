import { memo, useState } from "react";
import { ArrowDownToLine, ArrowUpFromLine, Folder } from "lucide-react";
import { PreferencesGroup } from "@/components/preferences-group";
import { StatusMessage } from "@/components/status-message";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Progress } from "@/components/ui/progress";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { commands } from "@/lib/tauri";
import { errorMessage, formatBytes, stateLabel, transferPercent } from "@/lib/format";
import type { TransferSnapshot } from "@/lib/types";
import { useReceiverStore } from "@/state/receiver-store";

export function TransfersPanel() {
  const transfers = useReceiverStore((state) => state.snapshot.transfers) ?? [];
  const files = useReceiverStore((state) => state.snapshot.files);
  const transferError = useReceiverStore((state) => state.transferError);
  const setTransferError = useReceiverStore((state) => state.setTransferError);
  const [busy, setBusy] = useState(false);

  async function sendFiles() {
    setTransferError("");
    setBusy(true);
    try {
      const paths = await commands.chooseFiles();
      if (!paths.length) return;
      await commands.sendFiles(paths);
    } catch (error) {
      setTransferError(errorMessage(error));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="min-h-0 flex-1 overflow-auto">
      <div className="mx-auto flex min-h-full w-full max-w-[640px] flex-col gap-5 px-6 py-6">
        <PreferencesGroup
          title="Transfers"
          description={
            files ? "File transfer is ready." : "Waiting for the file-transfer channel."
          }
          action={
            <div className="flex shrink-0 items-center gap-2">
              <Tooltip>
                <TooltipTrigger asChild>
                  {/* span keeps the tooltip reachable while the button is disabled */}
                  <span className="inline-flex">
                    <Button disabled={!files || busy} onClick={() => void sendFiles()}>
                      Send Files…
                    </Button>
                  </span>
                </TooltipTrigger>
                <TooltipContent>
                  {files
                    ? "Choose files to send to the paired Mac."
                    : "Available once the file-transfer channel connects."}
                </TooltipContent>
              </Tooltip>
              <Button variant="outline" onClick={() => void commands.openFolder()}>
                Open folder
              </Button>
            </div>
          }
        >
          {transfers.length === 0 ? (
            <Card className="flex flex-col items-center justify-center py-12 text-center">
              <div className="text-muted-foreground" aria-hidden="true">
                <Folder className="size-8" />
              </div>
              <strong className="mt-3 text-[15px] font-bold">No file transfers yet</strong>
              <p className="mt-1 max-w-xs text-[13px] text-muted-foreground">
                Copy files on the Mac while this PC is active, or choose Send Files.
              </p>
            </Card>
          ) : (
            <div className="flex flex-col gap-3">
              {transfers.map((transfer) => (
                <TransferCard key={transfer.id} transfer={transfer} />
              ))}
            </div>
          )}
        </PreferencesGroup>
        {/* Reserved slot, so an error appearing does not shove the list upward. */}
        <div className="mt-auto flex min-h-5 items-center justify-end">
          <StatusMessage text={transferError} tone="error" />
        </div>
      </div>
    </div>
  );
}

const TransferCard = memo(function TransferCard({ transfer }: { transfer: TransferSnapshot }) {
  const percent = transferPercent(transfer);
  const incoming = transfer.direction === "incoming";
  const Icon = incoming ? ArrowDownToLine : ArrowUpFromLine;
  return (
    <Card>
      <CardContent className="flex flex-col gap-2.5">
        <div className="flex items-center gap-3.5">
          <span className="shrink-0 text-muted-foreground" aria-hidden="true">
            <Icon className="size-4" />
          </span>
          <div className="min-w-0 flex-1">
            <strong className="block truncate text-sm font-bold" title={transfer.displayName}>
              {transfer.displayName}
            </strong>
            <span className="text-xs text-muted-foreground">
              {incoming ? "From Mac" : "To Mac"} · {stateLabel(transfer.state)}
            </span>
          </div>
          {/* Right-aligned and tabular: the percentage changes every tick and
              must not resize anything as it goes 9% → 10% → 100%. */}
          <span className="w-12 shrink-0 text-right text-xs font-bold tabular-nums">
            {percent}%
          </span>
        </div>
        <Progress
          value={percent}
          className={
            transfer.state === "failed"
              ? "[&_[data-slot=progress-indicator]]:bg-[var(--danger-bg)]"
              : transfer.state === "completed"
                ? "[&_[data-slot=progress-indicator]]:bg-ok-dot"
                : undefined
          }
        />
        {/* Fixed height: the Open folder button only exists once the transfer
            completes, and the row must not grow when it appears. */}
        <div className="flex min-h-[var(--control-h-sm)] items-center justify-between gap-3">
          <span className="text-xs text-muted-foreground tabular-nums">
            {formatBytes(transfer.bytesDone)} of {formatBytes(transfer.bytesTotal)}
          </span>
          {transfer.directory && transfer.state === "completed" && incoming ? (
            <Button
              variant="outline"
              size="sm"
              onClick={() => void commands.openFolder(transfer.directory)}
            >
              Open folder
            </Button>
          ) : null}
        </div>
      </CardContent>
    </Card>
  );
});
