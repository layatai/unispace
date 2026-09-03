import { Clipboard } from "lucide-react";
import { PreferencesGroup } from "@/components/preferences-group";
import { RowStatus } from "@/components/row-status";
import { Card, CardContent } from "@/components/ui/card";
import { useReceiverStore } from "@/state/receiver-store";

export function ClipboardPanel() {
  const clipboard = useReceiverStore((state) => state.snapshot.clipboard);
  const controllerName = useReceiverStore((state) => state.snapshot.controllerName);
  const controller = controllerName || "Mac";
  const on = clipboard;
  return (
    <div className="min-h-0 flex-1 overflow-auto">
      <div className="mx-auto flex min-h-full w-full max-w-[640px] flex-col gap-5 px-6 py-6">
        <PreferencesGroup
          title="Clipboard"
          description="Carry text and links between this PC and the active UniSpace peer."
        >
          <Card className="gap-0 py-0">
            <CardContent className="px-0">
              <div className="grid grid-cols-[1.25rem_minmax(0,1fr)_8rem] items-center gap-3.5 px-4 py-2">
                <span className="text-muted-foreground" aria-hidden="true">
                  <Clipboard className="size-4" />
                </span>
                <div className="min-w-0">
                  <h3 className="truncate text-sm">Sharing</h3>
                  {/* Reserved lines: the two messages differ in length, and the
                      shorter one used to shrink the card as it reconnected. */}
                  <p className="line-clamp-2 min-h-8 text-xs text-muted-foreground" aria-live="polite">
                    {on
                      ? `Sharing text and links with ${controller}.`
                      : "Waiting for the clipboard channel to reconnect."}
                  </p>
                </div>
                <RowStatus
                  tone={on ? "active" : "warn"}
                  label={on ? "Enabled" : "Reconnecting"}
                  className="w-full"
                />
              </div>
            </CardContent>
          </Card>
        </PreferencesGroup>
        <p className="px-1 text-xs text-muted-foreground">
          Text and links sync automatically. Regular files continue through Transfers.
        </p>
      </div>
    </div>
  );
}
