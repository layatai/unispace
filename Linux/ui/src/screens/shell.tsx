import type { ComponentType } from "react";
import { ArrowDownUp, Clipboard, House } from "lucide-react";
import { StatusPill, connectionLabel, connectionTone } from "@/components/status-pill";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { ClipboardPanel } from "@/panels/clipboard-panel";
import { HomePanel } from "@/panels/home-panel";
import { TransfersPanel } from "@/panels/transfers-panel";
import { useReceiverStore } from "@/state/receiver-store";
import type { Panel } from "@/lib/types";

const panelClass =
  "flex min-h-0 flex-1 flex-col overflow-hidden data-[state=inactive]:hidden";

const views: { value: Panel; label: string; icon: ComponentType<{ className?: string }> }[] = [
  { value: "home", label: "Home", icon: House },
  { value: "transfers", label: "Transfers", icon: ArrowDownUp },
  { value: "clipboard", label: "Clipboard", icon: Clipboard },
];

export function Shell() {
  const panel = useReceiverStore((state) => state.panel);
  const setPanel = useReceiverStore((state) => state.setPanel);

  return (
    <Tabs
      value={panel}
      onValueChange={(value) => setPanel(value as Panel)}
      className="flex h-full min-h-0 flex-col gap-0"
    >
      <HeaderBar />
      <TabsContent value="home" forceMount className={panelClass}>
        <HomePanel />
      </TabsContent>
      <TabsContent value="transfers" forceMount className={panelClass}>
        <TransfersPanel />
      </TabsContent>
      <TabsContent value="clipboard" forceMount className={panelClass}>
        <ClipboardPanel />
      </TabsContent>
    </Tabs>
  );
}

/**
 * A header bar in the desktop sense: the workspace at the start, the view
 * switcher centred, status at the end. The three columns are a 1fr/auto/1fr
 * grid so the switcher stays optically centred no matter how long the
 * workspace name or the status label is.
 */
function HeaderBar() {
  const workspaceName = useReceiverStore((state) => state.snapshot.workspaceName);
  const receiving = useReceiverStore((state) => state.snapshot.receiving);
  const control = useReceiverStore((state) => state.snapshot.control);
  const name = workspaceName || "UniSpace";

  return (
    <header className="grid h-[var(--headerbar-h)] shrink-0 grid-cols-[1fr_auto_1fr] items-center gap-3 border-b border-separator bg-headerbar px-3">
      <h1 className="truncate pl-1 text-sm font-bold" title={name}>
        {name}
      </h1>
      <TabsList className="h-[var(--control-h)] gap-1 rounded-none bg-transparent p-0">
        {views.map(({ value, label, icon: Icon }) => (
          <TabsTrigger
            key={value}
            value={value}
            className="h-full rounded-lg px-3 text-sm text-foreground/75 hover:bg-secondary data-active:bg-switcher-active data-active:font-bold data-active:text-foreground data-active:shadow-none dark:data-active:border-transparent dark:data-active:bg-switcher-active"
          >
            <Icon className="size-4" />
            {label}
          </TabsTrigger>
        ))}
      </TabsList>
      <div className="flex justify-end">
        <StatusPill
          tone={connectionTone(receiving, control)}
          label={connectionLabel(receiving, control)}
          className="w-[7rem]"
        />
      </div>
    </header>
  );
}
