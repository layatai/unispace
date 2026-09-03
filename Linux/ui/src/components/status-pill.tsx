import { cn } from "@/lib/utils";

export type StatusTone = "active" | "ready" | "idle" | "warn";

const surface: Record<StatusTone, string> = {
  active: "border-emerald-500/30 bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
  ready: "border-primary/25 bg-primary/10 text-primary",
  idle: "border-border bg-muted text-muted-foreground",
  warn: "border-amber-500/30 bg-amber-500/10 text-amber-700 dark:text-amber-500",
};

const dot: Record<StatusTone, string> = {
  active: "bg-emerald-500",
  ready: "bg-primary",
  idle: "bg-muted-foreground/60",
  warn: "bg-amber-500",
};

/**
 * A status chip with a reserved width.
 *
 * Status labels change length ("Waiting" → "Receiving", "Allowed" → "Needs
 * access"). Sizing the chip to its text means every status update resizes its
 * column and nudges everything around it, so callers give it a fixed width and
 * the label is centred inside.
 */
export function StatusPill({
  tone,
  label,
  className,
}: {
  tone: StatusTone;
  label: string;
  className?: string;
}) {
  return (
    <span
      data-slot="status-pill"
      data-tone={tone}
      className={cn(
        "inline-flex h-6 shrink-0 items-center justify-center gap-1.5 rounded-full border px-2.5 text-xs font-semibold whitespace-nowrap",
        surface[tone],
        className,
      )}
    >
      <span className={cn("size-1.5 shrink-0 rounded-full", dot[tone])} aria-hidden="true" />
      {label}
    </span>
  );
}

export function connectionTone(receiving: boolean, control: string): StatusTone {
  if (receiving) return "active";
  return control === "connected" ? "ready" : "idle";
}

export function connectionLabel(receiving: boolean, control: string): string {
  if (receiving) return "Receiving";
  return control === "connected" ? "Connected" : "Waiting";
}
