import { cn } from "@/lib/utils";

export function PairingCode({ code }: { code: string }) {
  const digits = Array.from(String(code));
  return (
    <div className="flex justify-center gap-2" aria-live="polite">
      {digits.map((digit, index) => (
        <span
          key={`${digit}-${index}`}
          className={cn(
            "grid size-12 place-items-center rounded-lg border bg-muted font-mono text-3xl font-semibold",
          )}
        >
          {digit}
        </span>
      ))}
    </div>
  );
}
