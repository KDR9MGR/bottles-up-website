import { useEffect, useState } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { format, parseISO } from 'date-fns';
import { QRCodeSVG } from 'qrcode.react';
import { ArrowLeft, Calendar, MapPin, Users, Clock, Download, Share2, Loader2, Ticket, TableIcon, CheckCircle2, AlertCircle } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Separator } from '@/components/ui/separator';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { useUserAuth } from '@/hooks/useUserAuth';
import Header from '@/components/Header';

interface Booking {
  id: string;
  booking_id: string | null;
  event_id: string | null;
  amount: string;
  currency: string;
  status: string;
  payment_type: string;
  metadata: Record<string, unknown>;
  created_at: string;
}

const formatMoney = (amount: string, currency: string) =>
  `$${parseFloat(amount).toFixed(2)} ${currency.toUpperCase()}`;

const statusConfig: Record<string, { icon: typeof CheckCircle2; color: string; label: string }> = {
  paid:      { icon: CheckCircle2, color: 'text-green-400',  label: 'Paid' },
  confirmed: { icon: CheckCircle2, color: 'text-green-400',  label: 'Confirmed' },
  pending:   { icon: AlertCircle,  color: 'text-yellow-400', label: 'Pending' },
  cancelled: { icon: AlertCircle,  color: 'text-red-400',    label: 'Cancelled' },
};

export default function UserBookingDetail() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const { toast } = useToast();
  const { session, loading: authLoading } = useUserAuth();
  const [booking, setBooking] = useState<Booking | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (authLoading || !session || !id) return;
    supabase
      .from('payment_transactions')
      .select('*')
      .eq('id', id)
      .eq('user_id', session.user.id)
      .maybeSingle()
      .then(({ data }) => {
        setBooking(data as Booking | null);
        setLoading(false);
      });
  }, [authLoading, session, id]);

  const handleShare = async () => {
    const text = `BottlesUp Booking: ${getLabel()} — ${getDateStr()}`;
    if (navigator.share) {
      await navigator.share({ title: 'BottlesUp Booking', text });
    } else {
      await navigator.clipboard.writeText(text);
      toast({ title: 'Copied to clipboard' });
    }
  };

  const handleDownload = () => {
    const svg = document.querySelector('#booking-qr svg') as SVGElement | null;
    if (!svg) return;
    const blob = new Blob([svg.outerHTML], { type: 'image/svg+xml' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `bottlesup-booking-${id?.slice(0, 8)}.svg`;
    a.click();
    URL.revokeObjectURL(url);
  };

  if (authLoading || loading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-black">
        <Loader2 className="h-8 w-8 animate-spin text-orange-500" />
      </div>
    );
  }

  if (!session) {
    navigate('/dashboard');
    return null;
  }

  if (!booking) {
    return (
      <>
        <Header />
        <div className="flex min-h-screen flex-col items-center justify-center bg-black text-center pt-20 px-4">
          <p className="text-gray-400">Booking not found.</p>
          <Button variant="ghost" className="mt-4 text-white" onClick={() => navigate('/dashboard')}>
            Back to Dashboard
          </Button>
        </div>
      </>
    );
  }

  const meta = booking.metadata;
  const isTable = booking.payment_type === 'tableBooking';
  const qrData = booking.booking_id ?? booking.id;
  const confirmationCode = (booking.booking_id ?? booking.id).slice(0, 8).toUpperCase();

  const getLabel = () => String(meta.event_name ?? meta.club_name ?? 'Booking');
  const getVenue = () => String(meta.club_name ?? '');
  const getDateStr = () => {
    const raw = String(meta.event_date ?? meta.date ?? '');
    if (!raw) return '';
    try { return format(parseISO(raw), 'EEEE, MMMM d, yyyy'); } catch { return raw; }
  };
  const getTime = () => String(meta.event_time ?? meta.time_slot ?? '');

  const StatusIcon = (statusConfig[booking.status] ?? statusConfig.pending).icon;
  const statusColor = (statusConfig[booking.status] ?? statusConfig.pending).color;
  const statusLabel = (statusConfig[booking.status] ?? statusConfig.pending).label;

  return (
    <>
      <Header />
      <div className="min-h-screen bg-black pt-24 pb-16 px-4">
        <div className="mx-auto max-w-lg">
          {/* Back */}
          <button
            onClick={() => navigate('/dashboard')}
            className="flex items-center gap-2 text-gray-400 hover:text-white mb-6 transition-colors"
          >
            <ArrowLeft className="h-4 w-4" />
            Back to Dashboard
          </button>

          {/* QR Code card */}
          <div className="rounded-2xl border border-white/10 bg-zinc-900 overflow-hidden">
            <div className="bg-gradient-to-br from-orange-500/20 to-zinc-900 p-6 flex flex-col items-center">
              <div className="flex items-center gap-2 mb-4">
                {isTable ? (
                  <TableIcon className="h-5 w-5 text-orange-500" />
                ) : (
                  <Ticket className="h-5 w-5 text-orange-500" />
                )}
                <span className="text-sm font-medium text-orange-400 uppercase tracking-wide">
                  {isTable ? 'Table Booking' : 'Event Ticket'}
                </span>
              </div>

              <h1 className="text-xl font-bold text-white text-center mb-1">{getLabel()}</h1>
              {getVenue() && <p className="text-gray-400 text-sm mb-4">{getVenue()}</p>}

              {/* QR Code */}
              <div id="booking-qr" className="bg-white p-4 rounded-2xl mb-4">
                <QRCodeSVG
                  value={qrData}
                  size={200}
                  level="H"
                  includeMargin={false}
                />
              </div>

              <p className="text-xs text-gray-500 mb-1">Confirmation Code</p>
              <p className="text-2xl font-mono font-bold text-white tracking-widest">{confirmationCode}</p>

              <div className="flex items-center gap-2 mt-3">
                <StatusIcon className={`h-4 w-4 ${statusColor}`} />
                <span className={`text-sm font-medium ${statusColor}`}>{statusLabel}</span>
              </div>

              <p className="text-xs text-gray-500 mt-3 text-center">
                Screenshot or save this QR code. Door staff will scan it at entry.
              </p>
            </div>

            <Separator className="bg-white/5" />

            {/* Event details */}
            <div className="p-5 space-y-3">
              {getDateStr() && (
                <div className="flex items-center gap-3 text-sm">
                  <Calendar className="h-4 w-4 text-gray-500 shrink-0" />
                  <span className="text-gray-300">{getDateStr()}</span>
                </div>
              )}
              {getTime() && (
                <div className="flex items-center gap-3 text-sm">
                  <Clock className="h-4 w-4 text-gray-500 shrink-0" />
                  <span className="text-gray-300">{getTime()}</span>
                </div>
              )}
              {getVenue() && (
                <div className="flex items-center gap-3 text-sm">
                  <MapPin className="h-4 w-4 text-gray-500 shrink-0" />
                  <span className="text-gray-300">{getVenue()}</span>
                </div>
              )}
              {meta.guest_count && (
                <div className="flex items-center gap-3 text-sm">
                  <Users className="h-4 w-4 text-gray-500 shrink-0" />
                  <span className="text-gray-300">{String(meta.guest_count)} guests</span>
                </div>
              )}

              <Separator className="bg-white/5 my-2" />

              {/* Price breakdown */}
              <div className="space-y-1.5">
                {meta.ticket_quantity && (
                  <div className="flex justify-between text-sm">
                    <span className="text-gray-400">Tickets × {String(meta.ticket_quantity)}</span>
                    <span className="text-gray-300">{formatMoney(booking.amount, booking.currency)}</span>
                  </div>
                )}
                <div className="flex justify-between text-sm font-bold pt-1">
                  <span className="text-white">Total</span>
                  <span className="text-orange-500">{formatMoney(booking.amount, booking.currency)}</span>
                </div>
              </div>
            </div>

            {/* Actions */}
            <div className="px-5 pb-5 grid grid-cols-2 gap-3">
              <Button
                variant="outline"
                className="border-white/10 text-white hover:bg-white/5"
                onClick={handleDownload}
              >
                <Download className="mr-2 h-4 w-4" />
                Save QR
              </Button>
              <Button
                variant="outline"
                className="border-white/10 text-white hover:bg-white/5"
                onClick={handleShare}
              >
                <Share2 className="mr-2 h-4 w-4" />
                Share
              </Button>
            </div>
          </div>

          <p className="text-center text-xs text-gray-600 mt-4">
            Booked on {format(parseISO(booking.created_at), 'MMM d, yyyy')}
          </p>
        </div>
      </div>
    </>
  );
}
