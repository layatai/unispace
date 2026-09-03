import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

/**
 * The desktop convention for a titled block of settings: a small bold group
 * title with an optional dimmed description, then the content below it
 * (AdwPreferencesGroup on GNOME, a titled form section on KDE).
 *
 * The description is one reserved line so live text can change without moving
 * the list underneath it.
 */
export function PreferencesGroup({
  title,
  description,
  action,
  className,
  children,
}: {
  title: string;
  description?: string;
  action?: ReactNode;
  className?: string;
  children: ReactNode;
}) {
  return (
    <section className={cn("flex flex-col", className)}>
      <div className="flex items-end gap-3 px-1 pb-2">
        <div className="min-w-0 flex-1">
          <h2 className="truncate text-[15px] font-bold">{title}</h2>
          {description === undefined ? null : (
            <p
              className="mt-0.5 h-[18px] truncate text-[13px] text-muted-foreground"
              title={description}
            >
              {description}
            </p>
          )}
        </div>
        {action}
      </div>
      {children}
    </section>
  );
}
