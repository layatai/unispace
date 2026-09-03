import { TooltipProvider } from "@/components/ui/tooltip";
import { useReceiverRuntime } from "@/lib/runtime";
import { ConfirmPairing } from "@/screens/confirm-pairing";
import { Shell } from "@/screens/shell";
import { Welcome } from "@/screens/welcome";
import { useReceiverStore } from "@/state/receiver-store";

export function App() {
  useReceiverRuntime();
  const phase = useReceiverStore((state) => state.phase);

  return (
    <TooltipProvider>
      {phase === "confirm" ? (
        <ConfirmPairing />
      ) : phase === "shell" ? (
        <Shell />
      ) : (
        <Welcome />
      )}
    </TooltipProvider>
  );
}
