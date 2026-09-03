import { Link2 } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { connectionDetail } from "@/lib/format";
import { ClipboardPanel } from "@/panels/clipboard-panel";
import { HomePanel } from "@/panels/home-panel";
import { TransfersPanel } from "@/panels/transfers-panel";
import { useReceiverStore } from "@/state/receiver-store";

export function Shell() {
  const panel = useReceiverStore((state) => state.panel);
  const setPanel = useReceiverStore((state) => state.setPanel);

  return (
    <section className="flex h-full min-h-0 flex-col">
      <ShellStatus />
      <Tabs
        value={panel}
        onValueChange={(value) => setPanel(value as typeof panel)}
        className="flex min-h-0 flex-1 flex-col gap-0 px-5 pb-4"
      >
        <TabsList className="w-full">
          <TabsTrigger value="home">Home</TabsTrigger>
          <TabsTrigger value="transfers">Transfers</TabsTrigger>
          <TabsTrigger value="clipboard">Clipboard</TabsTrigger>
        </TabsList>
        <TabsContent
          value="home"
          forceMount
          className="flex min-h-0 flex-1 flex-col overflow-hidden data-[state=inactive]:hidden"
        >
          <HomePanel />
        </TabsContent>
        <TabsContent
          value="transfers"
          forceMount
          className="flex min-h-0 flex-1 flex-col overflow-hidden data-[state=inactive]:hidden"
        >
          <TransfersPanel />
        </TabsContent>
        <TabsContent
          value="clipboard"
          forceMount
          className="flex min-h-0 flex-1 flex-col overflow-hidden data-[state=inactive]:hidden"
        >
          <ClipboardPanel />
        </TabsContent>
      </Tabs>
    </section>
  );
}

function ShellStatus() {
  const workspaceName = useReceiverStore((state) => state.snapshot.workspaceName);
  const receiving = useReceiverStore((state) => state.snapshot.receiving);
  const control = useReceiverStore((state) => state.snapshot.control);
  const controllerName = useReceiverStore((state) => state.snapshot.controllerName);
  const name = workspaceName || "UniSpace";
  const detail = connectionDetail(receiving, control, controllerName);
  const status = receiving ? "Receiving" : control === "connected" ? "Connected" : "Waiting";

  return (
    <header className="flex items-center gap-3.5 px-5 pt-5 pb-3.5">
      <div className="grid size-11 place-items-center rounded-[13px] border border-primary/20 bg-primary/10 text-primary">
        <Link2 className="size-5" aria-hidden="true" />
      </div>
      <div className="min-w-0">
        <h1 className="text-xl font-bold tracking-tight">{name}</h1>
        <p className="mt-0.5 text-[13px] text-muted-foreground">{detail}</p>
      </div>
      <div className="ml-auto">
        <Badge variant={receiving ? "default" : "secondary"}>{status}</Badge>
      </div>
    </header>
  );
}
