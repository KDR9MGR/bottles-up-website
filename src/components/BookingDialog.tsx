import { useEffect, useState } from 'react';
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import TicketSelectionForm from './TicketSelectionForm';
import type { EventWithTiers } from './PopularEvents';

interface BookingDialogProps {
  event: EventWithTiers | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  initialTierId?: string | null;
}

const BookingDialog = ({ event, open, onOpenChange, initialTierId }: BookingDialogProps) => {
  const [tierId, setTierId] = useState('');

  useEffect(() => {
    if (event && event.ticket_tiers.length > 0) {
      const preselected = initialTierId && event.ticket_tiers.some((t) => t.id === initialTierId);
      setTierId(preselected ? initialTierId! : event.ticket_tiers[0].id);
    }
  }, [event, initialTierId]);

  if (!event) return null;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] overflow-y-auto border-gray-800 bg-gray-950">
        <DialogHeader>
          <DialogTitle className="text-white">Book: {event.title}</DialogTitle>
        </DialogHeader>
        <TicketSelectionForm event={event} tierId={tierId} onTierChange={setTierId} />
      </DialogContent>
    </Dialog>
  );
};

export default BookingDialog;
