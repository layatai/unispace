import { cn } from "@/lib/utils";

export type StatusTone = "active" | "ready" | "idle" | "warn";

const surface: Record<StatusTone, string> = {
  active: "border-transparent bg-ok-surface text-ok",
  ready: "border-transparent bg-accent-soft text-accent-text",
  idle: "border-border bg-secondary text-muted-foreground",
  warn: "border-transparent bg-warn-surface text-warn",
};

const dot: Record<StatusTone, string> = {
  active: "bg-ok-dot",
  ready: "bg-[var(--accent-bg)]",
  idle: "bg-muted-foreground/60",
  warn: "bg-warn-dot",
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
        "inline-flex h-[22px] shrink-0 items-center justify-center gap-1.5 rounded-full border px-2.5 text-xs font-bold whitespace-nowrap",
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
