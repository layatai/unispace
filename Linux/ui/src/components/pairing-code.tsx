import { cn } from "@/lib/utils";

export function PairingCode({ code }: { code: string }) {
  const digits = Array.from(String(code));
  return (
    <div className="flex justify-center gap-2" aria-live="polite">
      {digits.map((digit, index) => (
        <span
          key={`${digit}-${index}`}
          className={cn(
            "grid size-12 place-items-center rounded-[var(--r-md)] border border-border bg-secondary font-mono text-3xl font-bold tabular-nums",
          )}
        >
          {digit}
        </span>
      ))}
    </div>
  );
}
