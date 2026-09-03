import { useState, type ReactNode } from "react";
import { Loader2, Monitor, Pointer, Settings } from "lucide-react";
import { PreferencesGroup } from "@/components/preferences-group";
import { RowStatus } from "@/components/row-status";
import { StatusMessage } from "@/components/status-message";
import { connectionLabel, connectionTone, type StatusTone } from "@/components/status-pill";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { commands } from "@/lib/tauri";
import { connectionDetail, errorMessage } from "@/lib/format";
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
    <div className="min-h-0 flex-1 overflow-auto">
      <div className="mx-auto flex min-h-full w-full max-w-[640px] flex-col gap-5 px-6 py-6">
        <PreferencesGroup
          title="Receiver"
          description={connectionDetail(receiving, control, controllerName)}
        >
          <Card className="gap-0 py-0">
            <CardContent className="divide-y divide-separator px-0">
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
        </PreferencesGroup>
        {/* Reserved row: the message slot is always here, so a notice arriving
            or clearing never moves the list above it. */}
        <div className="flex min-h-[var(--control-h)] items-center justify-between gap-3 px-1">
          <StatusMessage
            text={homeError || homeNotice}
            tone={homeError ? "error" : "notice"}
            className="text-left"
          />
          <Button variant="outline" onClick={() => setUnpairOpen(true)}>
            Unpair…
          </Button>
        </div>
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
      className="grid grid-cols-[1.25rem_minmax(0,1fr)_13rem] items-center gap-3.5 px-4 py-2"
    >
      <span className="text-muted-foreground" aria-hidden="true">
        {icon}
      </span>
      <div className="min-w-0">
        <h3 className="truncate text-sm">{title}</h3>
        {/* Two lines are always reserved: the detail text differs in length
            between states, and one wrapping differently changes the row height. */}
        <p className="line-clamp-2 min-h-8 text-xs text-muted-foreground" title={detail}>
          {detail}
        </p>
      </div>
      <div className="flex items-center justify-end gap-2">
        <RowStatus tone={tone} label={label} className="w-[7.5rem]" />
        <div
          data-slot="row-action"
          className="relative flex h-[var(--control-h-sm)] w-[5rem] shrink-0 items-center justify-end"
        >
          {action}
        </div>
      </div>
    </div>
  );
}
