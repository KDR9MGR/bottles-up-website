import { QRCodeSVG } from 'qrcode.react';
import { Calendar, MapPin } from 'lucide-react';

export interface TicketCardData {
  ticketCode: string;
  customerName: string;
  quantity: number;
  eventTitle: string;
  venueName: string;
  startDate: string;
  tierName: string;
}

const TicketCard = ({ ticket, label = 'BottlesUp E-Ticket' }: { ticket: TicketCardData; label?: string }) => {
  return (
    <div className="w-full max-w-sm overflow-hidden rounded-2xl border border-gray-800 bg-gray-950">
      <div className="bg-gradient-orange px-6 py-4 text-left">
        <div className="text-xs font-medium uppercase tracking-wide text-black/70">{label}</div>
        <div className="text-lg font-bold text-black">{ticket.eventTitle}</div>
      </div>

      <div className="space-y-4 p-6">
        <div className="flex justify-center rounded-xl bg-white p-4">
          <QRCodeSVG value={ticket.ticketCode} size={180} />
        </div>

        <div className="text-center text-xl font-bold tracking-[0.2em] text-white">{ticket.ticketCode}</div>

        <div className="space-y-2 border-t border-gray-800 pt-4 text-left text-sm text-gray-400">
          {ticket.venueName && (
            <div className="flex items-center gap-2">
              <MapPin className="h-4 w-4 text-primary" />
              <span>{ticket.venueName}</span>
            </div>
          )}
          {ticket.startDate && (
            <div className="flex items-center gap-2">
              <Calendar className="h-4 w-4 text-primary" />
              <span>
                {new Date(ticket.startDate).toLocaleString(undefined, {
                  weekday: 'short',
                  month: 'short',
                  day: 'numeric',
                  hour: 'numeric',
                  minute: '2-digit',
                })}
              </span>
            </div>
          )}
          <div className="flex items-center justify-between pt-1">
            <span>{ticket.tierName}</span>
            <span>× {ticket.quantity}</span>
          </div>
        </div>
      </div>
    </div>
  );
};

export default TicketCard;
