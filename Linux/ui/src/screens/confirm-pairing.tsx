import { useState } from "react";
import { PairingCode } from "@/components/pairing-code";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { commands } from "@/lib/tauri";
import { errorMessage } from "@/lib/format";
import { useReceiverStore } from "@/state/receiver-store";

export function ConfirmPairing() {
  const offer = useReceiverStore((state) => state.offer);
  const confirmError = useReceiverStore((state) => state.confirmError);
  const apply = useReceiverStore((state) => state.apply);
  const setPhase = useReceiverStore((state) => state.setPhase);
  const setConfirmError = useReceiverStore((state) => state.setConfirmError);
  const setHomeError = useReceiverStore((state) => state.setHomeError);
  const [busy, setBusy] = useState(false);

  async function confirm() {
    setConfirmError("");
    setBusy(true);
    try {
      const result = await commands.confirmPairing();
      apply(result.state);
      setHomeError(result.warning ?? "");
    } catch (error) {
      setConfirmError(errorMessage(error));
    } finally {
      setBusy(false);
    }
  }

  async function cancel() {
    setConfirmError("");
    setBusy(true);
    try {
      await commands.cancelPairing();
      setPhase("welcome");
    } catch (error) {
      setConfirmError(errorMessage(error));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="flex h-full flex-col items-center justify-center px-9 text-center">
      <p className="mb-4 text-[13px] font-semibold tracking-[0.04em] text-primary uppercase">
        UniSpace
      </p>
      <h1 className="text-[30px] leading-tight font-bold tracking-tight">Confirm pairing</h1>
      <p className="mt-2 max-w-md text-[15px] text-muted-foreground">
        {offer
          ? `Check that ${offer.peerName} is showing this same code, then approve on both devices.`
          : "Confirm the pairing code on both devices."}
      </p>
      <div className="my-7">
        <PairingCode code={offer?.code ?? ""} />
      </div>
      <div className="flex gap-2.5">
        <Button variant="outline" onClick={() => void cancel()} disabled={busy}>
          Cancel
        </Button>
        <Button onClick={() => void confirm()} disabled={busy}>
          {busy ? "Confirming…" : "Codes match"}
        </Button>
      </div>
      {confirmError ? (
        <Alert variant="destructive" className="mt-4 max-w-md text-left">
          <AlertDescription>{confirmError}</AlertDescription>
        </Alert>
      ) : null}
    </section>
  );
}
