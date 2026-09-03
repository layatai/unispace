import { useState, type ReactNode } from "react";
import { Monitor, Pointer, Settings } from "lucide-react";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { commands } from "@/lib/tauri";
import { connectionDetail, errorMessage } from "@/lib/format";
import { cn } from "@/lib/utils";
import { useReceiverStore } from "@/state/receiver-store";
import { UnpairDialog } from "@/panels/unpair-dialog";

export function HomePanel() {
  const receiving = useReceiverStore((state) => state.snapshot.receiving);
  const control = useReceiverStore((state) => state.snapshot.control);
  const controllerName = useReceiverStore((state) => state.snapshot.controllerName);
  const hostAddress = useReceiverStore((state) => state.snapshot.hostAddress);
  const serviceRunning = useReceiverStore((state) => state.snapshot.serviceRunning);
  const uinputReady = useReceiverStore((state) => state.snapshot.uinputReady);
  const homeError = useReceiverStore((state) => state.homeError);
  const setHomeError = useReceiverStore((state) => state.setHomeError);
  const [busy, setBusy] = useState<string | null>(null);
  const [unpairOpen, setUnpairOpen] = useState(false);
  const detail = connectionDetail(receiving, control, controllerName);

  async function run(name: string, action: () => Promise<void>) {
    setHomeError("");
    setBusy(name);
    try {
      await action();
    } catch (error) {
      setHomeError(errorMessage(error));
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-auto p-5">
      <header>
        <h2 className="text-[22px] font-bold tracking-tight">Receiver</h2>
        <p className="mt-1 text-sm text-muted-foreground">{detail}</p>
      </header>
      <Card className="py-0">
        <CardContent className="divide-y px-0">
          <StatusRow
            icon={<Monitor className="size-4" />}
            title="Controller"
            detail={controllerName || "Mac"}
            value={hostAddress || "—"}
          />
          <StatusRow
            icon={<Settings className="size-4" />}
            title="Receiver service"
            detail="Keeps this PC reachable from the paired Mac."
            value={serviceRunning ? "Running" : "Stopped"}
            ok={serviceRunning}
            action={
              serviceRunning ? (
                <Button
                  variant="ghost"
                  size="sm"
                  disabled={busy !== null}
                  onClick={() => void run("stop", () => commands.stopService())}
                >
                  Stop
                </Button>
              ) : (
                <Button
                  size="sm"
                  disabled={busy !== null}
                  onClick={() => void run("start", () => commands.startService())}
                >
                  Start
                </Button>
              )
            }
          />
          <StatusRow
            icon={<Pointer className="size-4" />}
            title="Input access"
            detail={
              uinputReady
                ? "Required to move the pointer and type."
                : "Sign out and back in, then restart the receiver to pick up the unispace group."
            }
            value={uinputReady ? "Allowed" : "Needs access"}
            ok={uinputReady}
            action={
              uinputReady && serviceRunning ? null : (
                <Button
                  size="sm"
                  disabled={busy !== null}
                  onClick={() => void run("restart", () => commands.restartReceiver())}
                >
                  Restart receiver
                </Button>
              )
            }
          />
        </CardContent>
      </Card>
      <div className="mt-auto flex items-center justify-between gap-3">
        <Button variant="ghost" onClick={() => setUnpairOpen(true)}>
          Unpair…
        </Button>
        {homeError ? (
          <Alert variant="destructive" className="max-w-sm">
            <AlertDescription>{homeError}</AlertDescription>
          </Alert>
        ) : null}
      </div>
      <UnpairDialog open={unpairOpen} onOpenChange={setUnpairOpen} />
    </div>
  );
}

function StatusRow({
  icon,
  title,
  detail,
  value,
  ok,
  action,
}: {
  icon: ReactNode;
  title: string;
  detail: string;
  value: string;
  ok?: boolean;
  action?: ReactNode;
}) {
  return (
    <div className="grid grid-cols-[40px_1fr_auto] items-center gap-3 px-4 py-3">
      <div
        className={cn(
          "grid size-10 place-items-center rounded-[11px] border",
          ok === false
            ? "border-amber-500/30 bg-amber-500/10 text-amber-600"
            : ok
              ? "border-emerald-500/30 bg-emerald-500/10 text-emerald-600"
              : "border-primary/20 bg-primary/10 text-primary",
        )}
        aria-hidden="true"
      >
        {icon}
      </div>
      <div>
        <h3 className="text-sm font-semibold">{title}</h3>
        <p className="mt-0.5 text-xs text-muted-foreground">{detail}</p>
      </div>
      <div className="flex items-center gap-2">
        <span
          className={cn(
            "text-right text-[13px] font-semibold",
            ok === false ? "text-amber-600" : ok ? "text-emerald-600" : undefined,
          )}
        >
          {value}
        </span>
        {action}
      </div>
    </div>
  );
}
