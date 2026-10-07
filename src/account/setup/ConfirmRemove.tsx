import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter,
  AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog';

interface Props {
  open: boolean;
  title: string;
  description: string;
  busy?: boolean;
  onConfirm: () => void;
  onClose: () => void;
}

/** "Are you sure" before something is removed. Closing it, or Keep, changes nothing. */
const ConfirmRemove = ({ open, title, description, busy = false, onConfirm, onClose }: Props) => (
  <AlertDialog open={open} onOpenChange={(o) => { if (!o && !busy) onClose(); }}>
    <AlertDialogContent>
      <AlertDialogHeader>
        <AlertDialogTitle>{title}</AlertDialogTitle>
        <AlertDialogDescription>{description}</AlertDialogDescription>
      </AlertDialogHeader>
      <AlertDialogFooter>
        <AlertDialogCancel disabled={busy}>Keep it</AlertDialogCancel>
        <AlertDialogAction
          disabled={busy}
          onClick={(e) => { e.preventDefault(); onConfirm(); }}
          className="bg-red-600 text-white hover:bg-red-700"
        >
          {busy ? 'Removing…' : 'Remove'}
        </AlertDialogAction>
      </AlertDialogFooter>
    </AlertDialogContent>
  </AlertDialog>
);

export default ConfirmRemove;
