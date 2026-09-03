import { useState, type ReactNode } from "react";
import { Loader2, Monitor, Pointer, Settings } from "lucide-react";
import { StatusMessage } from "@/components/status-message";
import {
  StatusPill,
  connectionLabel,
  connectionTone,
  type StatusTone,
} from "@/components/status-pill";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { commands } from "@/lib/tauri";
import { errorMessage } from "@/lib/format";
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
  const homeNotice = useReceiverStore((state) => state.homeNotice);
  const setHomeError = useReceiverStore((state) => state.setHomeError);
  const [busy, setBusy] = useState<string | null>(null);
  const [unpairOpen, setUnpairOpen] = useState(false);

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
        {/* Deliberately static: the live detail is in the window header, and
            repeating it here made two lines of text rewrite on every update. */}
        <p className="mt-1 text-sm text-muted-foreground">
          How this PC appears to the paired Mac.
        </p>
      </header>
      <Card className="py-0">
        <CardContent className="divide-y px-0">
          <StatusRow
            icon={<Monitor className="size-4" />}
            title="Controller"
            detail={hostAddress ? `${controllerName || "Mac"} · ${hostAddress}` : "Not set"}
            tone={connectionTone(receiving, control)}
            label={connectionLabel(receiving, control)}
          />
          <StatusRow
            icon={<Settings className="size-4" />}
            title="Receiver service"
            detail="Keeps this PC reachable from the paired Mac."
            tone={serviceRunning ? "active" : "warn"}
            label={serviceRunning ? "Running" : "Stopped"}
            action={
              serviceRunning ? (
                <RowAction
                  label="Stop"
                  hint="Stop the receiver service on this PC."
                  variant="outline"
                  busy={busy === "stop"}
                  disabled={busy !== null}
                  onClick={() => void run("stop", () => commands.stopService())}
                />
              ) : (
                <RowAction
                  label="Start"
                  hint="Start the receiver service so the Mac can reach this PC."
                  busy={busy === "start"}
                  disabled={busy !== null}
                  onClick={() => void run("start", () => commands.startService())}
                />
              )
            }
          />
          <StatusRow
            icon={<Pointer className="size-4" />}
            title="Input access"
            detail={
              uinputReady
                ? "Pointer and keyboard injection is allowed."
                : "Sign out and back in, then restart the receiver to pick up the unispace group."
            }
            tone={uinputReady ? "active" : "warn"}
            label={uinputReady ? "Allowed" : "Needs access"}
            action={
              uinputReady && serviceRunning ? null : (
                <RowAction
                  label="Restart"
                  hint="Restart the receiver so it picks up the current permissions."
                  variant="outline"
                  busy={busy === "restart"}
                  disabled={busy !== null}
                  onClick={() => void run("restart", () => commands.restartReceiver())}
                />
              )
            }
          />
        </CardContent>
      </Card>
      {/* Reserved footer: the message slot is always here, so a notice
          arriving or clearing never moves the card above it. */}
      <div className="mt-auto flex min-h-9 items-center justify-between gap-3">
        <Button variant="ghost" onClick={() => setUnpairOpen(true)}>
          Unpair…
        </Button>
        <StatusMessage
          text={homeError || homeNotice}
          tone={homeError ? "error" : "notice"}
        />
      </div>
      <UnpairDialog open={unpairOpen} onOpenChange={setUnpairOpen} />
    </div>
  );
}

function RowAction({
  label,
  hint,
  busy,
  disabled,
  variant = "default",
  onClick,
}: {
  label: string;
  hint: string;
  busy: boolean;
  disabled: boolean;
  variant?: "default" | "outline";
  onClick: () => void;
}) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button
          size="sm"
          variant={variant}
          className="relative w-full"
          disabled={disabled}
          aria-label={label}
          onClick={onClick}
        >
          {/* The label stays mounted so the button keeps its width while the
              action runs; the spinner sits on top of it. */}
          <span className={busy ? "invisible" : undefined}>{label}</span>
          {busy ? (
            <Loader2 className="absolute size-3.5 animate-spin" aria-hidden="true" />
          ) : null}
        </Button>
      </TooltipTrigger>
      <TooltipContent>{hint}</TooltipContent>
    </Tooltip>
  );
}

function StatusRow({
  icon,
  title,
  detail,
  tone,
  label,
  action,
}: {
  icon: ReactNode;
  title: string;
  detail: string;
  tone: StatusTone;
  label: string;
  action?: ReactNode;
}) {
  return (
    // Fixed track widths. The status column used to be `auto`, so every
    // Running → Stopped or Allowed → Needs access flip resized it and reflowed
    // the title and detail beside it.
    <div
      data-slot="status-row"
      className="grid grid-cols-[2.5rem_minmax(0,1fr)_13.5rem] items-center gap-3 px-4 py-3"
    >
      <div
        className={
          tone === "warn"
            ? "grid size-10 place-items-center rounded-[11px] border border-amber-500/30 bg-amber-500/10 text-amber-600"
            : tone === "active"
              ? "grid size-10 place-items-center rounded-[11px] border border-emerald-500/30 bg-emerald-500/10 text-emerald-600"
              : "grid size-10 place-items-center rounded-[11px] border border-primary/20 bg-primary/10 text-primary"
        }
        aria-hidden="true"
      >
        {icon}
      </div>
      <div className="min-w-0">
        <h3 className="truncate text-sm font-semibold">{title}</h3>
        {/* Two lines are always reserved: the detail text differs in length
            between states, and one wrapping differently changes the row height. */}
        <p className="mt-0.5 line-clamp-2 min-h-8 text-xs text-muted-foreground" title={detail}>
          {detail}
        </p>
      </div>
      <div className="flex items-center justify-end gap-2">
        <StatusPill tone={tone} label={label} className="w-[7.5rem]" />
        <div
          data-slot="row-action"
          className="relative flex h-7 w-[5rem] shrink-0 items-center justify-end"
        >
          {action}
        </div>
      </div>
    </div>
  );
}
