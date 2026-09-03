import { useState } from "react";
import { Link2, Lock } from "lucide-react";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { commands } from "@/lib/tauri";
import { errorMessage } from "@/lib/format";
import { useReceiverStore } from "@/state/receiver-store";

export function Welcome() {
  const pairError = useReceiverStore((state) => state.pairError);
  const setOffer = useReceiverStore((state) => state.setOffer);
  const setPairError = useReceiverStore((state) => state.setPairError);
  const [address, setAddress] = useState("");
  const [busy, setBusy] = useState(false);

  async function connect() {
    setPairError("");
    const trimmed = address.trim();
    if (!trimmed) {
      setPairError("Enter the controller Mac hostname or address.");
      return;
    }
    setBusy(true);
    try {
      setOffer(await commands.beginPairing(trimmed));
    } catch (error) {
      setPairError(errorMessage(error));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="flex h-full flex-col items-center justify-center bg-[radial-gradient(1100px_380px_at_50%_-8%,color-mix(in_srgb,var(--brand)_12%,transparent),transparent_72%)] px-9 text-center">
      <p className="mb-4 text-[13px] font-semibold tracking-[0.04em] text-primary uppercase">
        UniSpace
      </p>
      <div className="mb-4 grid size-14 place-items-center rounded-2xl border border-primary/20 bg-primary/10 text-primary">
        <Link2 className="size-7" aria-hidden="true" />
      </div>
      <h1 className="text-[30px] leading-tight font-bold tracking-tight">
        One keyboard. Every device.
      </h1>
      <p className="mt-2 max-w-md text-[15px] text-muted-foreground">
        Pair this Linux PC with the Mac whose keyboard you want to use, over your LAN or
        private Tailscale network.
      </p>
      <Card className="mt-7 w-full max-w-md text-left">
        <CardContent className="flex flex-col gap-3">
          <Label htmlFor="address" className="sr-only">
            Controller Mac hostname or Tailscale address
          </Label>
          <Input
            id="address"
            value={address}
            onChange={(event) => setAddress(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") void connect();
            }}
            placeholder="Controller Mac hostname or Tailscale address"
            autoComplete="off"
            spellCheck={false}
          />
          <Button className="w-full" onClick={() => void connect()} disabled={busy}>
            {busy ? "Connecting…" : "Connect"}
          </Button>
          {pairError ? (
            <Alert variant="destructive">
              <AlertDescription>{pairError}</AlertDescription>
            </Alert>
          ) : null}
        </CardContent>
      </Card>
      <p className="mt-auto flex items-center gap-2 pt-8 text-xs text-muted-foreground">
        <Lock className="size-3.5" aria-hidden="true" />
        Pairing uses an encrypted private connection and a code you confirm on both devices.
      </p>
    </section>
  );
}
