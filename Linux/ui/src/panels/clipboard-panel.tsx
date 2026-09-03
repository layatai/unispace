import { Clipboard } from "lucide-react";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { useReceiverStore } from "@/state/receiver-store";

export function ClipboardPanel() {
  const snapshot = useReceiverStore((state) => state.snapshot);
  const controller = snapshot.controllerName || "Mac";
  const on = snapshot.clipboard;
  return (
    <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-auto p-5">
      <header>
        <h2 className="text-[22px] font-bold tracking-tight">Clipboard</h2>
        <p className="mt-1 text-sm text-muted-foreground">
          Carry text and links between this PC and the active UniSpace peer.
        </p>
      </header>
      <Card>
        <CardContent className="grid grid-cols-[44px_1fr_auto] items-start gap-3.5">
          <div
            className={
              on
                ? "grid size-11 place-items-center rounded-[11px] border border-emerald-500/30 bg-emerald-500/10 text-emerald-600"
                : "grid size-11 place-items-center rounded-[11px] border border-amber-500/30 bg-amber-500/10 text-amber-600"
            }
            aria-hidden="true"
          >
            <Clipboard className="size-4" />
          </div>
          <div>
            <h3 className="text-base font-semibold">Sharing</h3>
            <p className="mt-1 text-[13px] text-muted-foreground">
              {on
                ? `Sharing text and links with ${controller}.`
                : "Reconnecting the clipboard channel."}
            </p>
          </div>
          <Badge variant={on ? "default" : "secondary"}>{on ? "Enabled" : "Reconnecting"}</Badge>
        </CardContent>
      </Card>
      {!on ? (
        <Alert>
          <AlertDescription>Waiting for the clipboard channel.</AlertDescription>
        </Alert>
      ) : null}
      <p className="text-xs text-muted-foreground">
        Text and links sync automatically. Regular files continue through Transfers.
      </p>
    </div>
  );
}
