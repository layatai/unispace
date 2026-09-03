import { TriangleAlert } from "lucide-react";
import type { StatusTone } from "@/components/status-pill";
import { cn } from "@/lib/utils";

/**
 * The value at the end of a list row.
 *
 * Desktop lists state their status as plain dimmed text and save colour for
 * something the user has to act on, so only the warning tone is tinted — and it
 * carries an icon, so the meaning does not rest on colour alone. The width is
 * fixed by the caller: these labels change length ("Allowed" → "Needs access")
 * and a status update must not resize the row around them.
 */
export function RowStatus({
  tone,
  label,
  className,
}: {
  tone: StatusTone;
  label: string;
  className?: string;
}) {
  const warn = tone === "warn";
  return (
    <span
      data-slot="row-status"
      data-tone={tone}
      className={cn(
        "inline-flex items-center justify-end gap-1.5 text-right text-[13px] whitespace-nowrap",
        warn ? "font-bold text-warn" : "text-muted-foreground",
        className,
      )}
    >
      {warn ? <TriangleAlert className="size-3.5 shrink-0" aria-hidden="true" /> : null}
      {label}
    </span>
  );
}
