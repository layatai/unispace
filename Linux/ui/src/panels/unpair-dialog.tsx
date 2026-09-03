import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { commands } from "@/lib/tauri";
import { errorMessage } from "@/lib/format";
import { useReceiverStore } from "@/state/receiver-store";

export function UnpairDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const resetUnpaired = useReceiverStore((state) => state.resetUnpaired);
  const setHomeError = useReceiverStore((state) => state.setHomeError);

  async function confirm() {
    try {
      await commands.unpair();
      onOpenChange(false);
      resetUnpaired();
    } catch (error) {
      onOpenChange(false);
      setHomeError(errorMessage(error));
    }
  }

  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>Leave this workspace?</AlertDialogTitle>
          <AlertDialogDescription>
            This PC will forget the workspace and return to setup. The Mac and its other
            devices are unchanged.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Cancel</AlertDialogCancel>
          <AlertDialogAction variant="destructive" onClick={() => void confirm()}>
            Unpair
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
