import { memo, useState } from "react";
import { ArrowDownToLine, ArrowUpFromLine, Folder } from "lucide-react";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Progress } from "@/components/ui/progress";
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
    <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-auto p-5">
      <header>
        <h2 className="text-[22px] font-bold tracking-tight">Transfers</h2>
        <p className="mt-1 text-sm text-muted-foreground">
          Encrypted, resumable file delivery between this PC and the paired Mac.
        </p>
      </header>
      <div className="flex flex-wrap items-center gap-2.5">
        <Button disabled={!files || busy} onClick={() => void sendFiles()}>
          Send Files…
        </Button>
        <Button variant="outline" onClick={() => void commands.openFolder()}>
          Open received folder
        </Button>
        <p className="min-w-[180px] flex-1 text-[13px] text-muted-foreground">
          {files ? "File transfer is ready." : "Waiting for the file-transfer channel."}
        </p>
      </div>
      {transfers.length === 0 ? (
        <Card className="flex flex-1 flex-col items-center justify-center py-10 text-center">
          <div className="grid size-10 place-items-center rounded-[11px] border border-primary/20 bg-primary/10 text-primary">
            <Folder className="size-4" aria-hidden="true" />
          </div>
          <strong className="mt-2 text-[15px]">No file transfers yet</strong>
          <p className="mt-1 max-w-xs text-[13px] text-muted-foreground">
            Copy files on the Mac while this PC is active, or choose Send Files.
          </p>
        </Card>
      ) : (
        <div className="flex flex-col gap-2.5">
          {transfers.map((transfer) => (
            <TransferCard key={transfer.id} transfer={transfer} />
          ))}
        </div>
      )}
      {transferError ? (
        <Alert variant="destructive">
          <AlertDescription>{transferError}</AlertDescription>
        </Alert>
      ) : null}
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
        <div className="flex gap-3">
          <div
            className={
              incoming
                ? "grid size-10 place-items-center rounded-[11px] border border-primary/20 bg-primary/10 text-primary"
                : "grid size-10 place-items-center rounded-[11px] border bg-muted text-muted-foreground"
            }
            aria-hidden="true"
          >
            <Icon className="size-4" />
          </div>
          <div className="min-w-0 flex-1">
            <strong className="block truncate text-sm" title={transfer.displayName}>
              {transfer.displayName}
            </strong>
            <span className="text-xs text-muted-foreground">
              {incoming ? "From Mac" : "To Mac"} · {stateLabel(transfer.state)}
            </span>
          </div>
        </div>
        <Progress
          value={percent}
          className={
            transfer.state === "failed"
              ? "[&_[data-slot=progress-indicator]]:bg-destructive"
              : transfer.state === "completed"
                ? "[&_[data-slot=progress-indicator]]:bg-emerald-500"
                : undefined
          }
        />
        <div className="flex items-center justify-between">
          <span className="text-xs text-muted-foreground">
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
