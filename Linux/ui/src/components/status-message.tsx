import { cn } from "@/lib/utils";

/**
 * A single-line message that lives in a slot of fixed height.
 *
 * Errors and service notices arrive and clear on their own while the user is
 * looking at something else. Rendering them into the flow pushes the rest of
 * the panel around, so the slot is always present and only its contents change.
 * Long text is truncated rather than wrapped, with the full text on hover.
 */
export function StatusMessage({
  text,
  tone = "notice",
  className,
}: {
  text: string;
  tone?: "notice" | "error";
  className?: string;
}) {
  return (
    <p
      data-slot="status-message"
      role="status"
      aria-live="polite"
      title={text || undefined}
      className={cn(
        "min-w-0 flex-1 truncate text-right text-[13px]",
        tone === "error" ? "text-destructive" : "text-muted-foreground",
        className,
      )}
    >
      {text}
    </p>
  );
}
