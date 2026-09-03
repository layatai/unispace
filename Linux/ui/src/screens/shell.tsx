import { Link2 } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { connectionDetail } from "@/lib/format";
import { ClipboardPanel } from "@/panels/clipboard-panel";
import { HomePanel } from "@/panels/home-panel";
import { TransfersPanel } from "@/panels/transfers-panel";
import { useReceiverStore } from "@/state/receiver-store";

export function Shell() {
  const snapshot = useReceiverStore((state) => state.snapshot);
  const panel = useReceiverStore((state) => state.panel);
  const setPanel = useReceiverStore((state) => state.setPanel);
  const name = snapshot.workspaceName || "UniSpace";
  const detail = connectionDetail(
    snapshot.receiving,
    snapshot.control,
    snapshot.controllerName,
  );
  const status = snapshot.receiving
    ? "Receiving"
    : snapshot.control === "connected"
      ? "Connected"
      : "Waiting";

  return (
    <section className="flex h-full min-h-0 flex-col">
      <header className="flex items-center gap-3.5 px-5 pt-5 pb-3.5">
        <div className="grid size-11 place-items-center rounded-[13px] border border-primary/20 bg-primary/10 text-primary">
          <Link2 className="size-5" aria-hidden="true" />
        </div>
        <div className="min-w-0">
          <h1 className="text-xl font-bold tracking-tight">{name}</h1>
          <p className="mt-0.5 text-[13px] text-muted-foreground">{detail}</p>
        </div>
        <div className="ml-auto">
          <Badge variant={snapshot.receiving ? "default" : "secondary"}>{status}</Badge>
        </div>
      </header>
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
        <TabsContent value="home" className="flex min-h-0 flex-1 flex-col overflow-hidden">
          <HomePanel />
        </TabsContent>
        <TabsContent value="transfers" className="flex min-h-0 flex-1 flex-col overflow-hidden">
          <TransfersPanel />
        </TabsContent>
        <TabsContent value="clipboard" className="flex min-h-0 flex-1 flex-col overflow-hidden">
          <ClipboardPanel />
        </TabsContent>
      </Tabs>
    </section>
  );
}
