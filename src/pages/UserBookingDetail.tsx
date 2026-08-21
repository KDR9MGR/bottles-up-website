import { useEffect, useState } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { format, parseISO } from 'date-fns';
import { QRCodeSVG } from 'qrcode.react';
import { ArrowLeft, Calendar, MapPin, Users, Clock, Download, Share2, Loader2, Ticket, TableIcon, CheckCircle2, AlertCircle, KeyRound } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Separator } from '@/components/ui/separator';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { useUserAuth } from '@/hooks/useUserAuth';
import Header from '@/components/Header';

type BookingType = 'ticket' | 'table';

interface DetailData {
  code: string;
  title: string;
  venue: string;
  date: string | null;
  time: string;
  guestCount?: number;
  status: string;
  currency: string;
  lineItems: { label: string; amountCents: number }[];
  totalCents: number;
  createdAt: string;
  isNonTransferable?: boolean;
}

const formatMoney = (cents: number, currency: string) => `$${(cents / 100).toFixed(2)} ${currency.toUpperCase()}`;

const statusConfig: Record<string, { icon: typeof CheckCircle2; color: string; label: string }> = {
  paid:      { icon: CheckCircle2, color: 'text-green-400',  label: 'Paid' },
  pending:   { icon: AlertCircle,  color: 'text-yellow-400', label: 'Pending' },
  cancelled: { icon: AlertCircle,  color: 'text-red-400',    label: 'Cancelled' },
  refunded:  { icon: AlertCircle,  color: 'text-red-400',    label: 'Refunded' },
};

export default function UserBookingDetail() {
  const { type, id } = useParams<{ type: BookingType; id: string }>();
  const navigate = useNavigate();
  const { toast } = useToast();
  const { session, loading: authLoading } = useUserAuth();
  const [data, setData] = useState<DetailData | null>(null);
  const [loading, setLoading] = useState(true);
  const [requestingCode, setRequestingCode] = useState(false);
  const [codeSentTo, setCodeSentTo] = useState<string | null>(null);

  useEffect(() => {
    if (authLoading || !session || !id || !type) return;

    const load = async () => {
      if (type === 'ticket') {
        const { data: order } = await supabase
          .from('site_orders')
          .select('id, status, ticket_code, quantity, amount_total_cents, currency, created_at, is_non_transferable, site_ticket_tiers(name), site_events(title, venue_name, start_date)')
          .eq('id', id)
          .maybeSingle();

        if (!order) { setData(null); setLoading(false); return; }

        const tier = order.site_ticket_tiers as unknown as { name: string } | null;
        const event = order.site_events as unknown as { title: string; venue_name: string; start_date: string } | null;
        let time = '';
        if (event?.start_date) {
          try { time = format(parseISO(event.start_date), 'h:mm a'); } catch { time = ''; }
        }

        setData({
          code: order.ticket_code ?? order.id.slice(0, 8).toUpperCase(),
          title: event?.title ?? 'Event Ticket',
          venue: event?.venue_name ?? '',
          date: event?.start_date ?? null,
          time,
          status: order.status,
          currency: order.currency,
          lineItems: [{ label: `${tier?.name ?? 'Ticket'} × ${order.quantity}`, amountCents: order.amount_total_cents }],
          totalCents: order.amount_total_cents,
          createdAt: order.created_at,
          isNonTransferable: order.is_non_transferable,
        });
      } else {
        const { data: booking } = await supabase
          .from('site_table_bookings')
          .select('id, status, confirmation_code, guest_count, booking_date, deposit_cents, bottle_subtotal_cents, tax_cents, bottlesup_fee_cents, amount_total_cents, currency, created_at, site_table_types(name), site_venues(name), site_venue_time_slots(start_time)')
          .eq('id', id)
          .maybeSingle();

        if (!booking) { setData(null); setLoading(false); return; }

        const { data: bottles } = await supabase
          .from('site_table_booking_bottles')
          .select('bottle_name, size, quantity, line_total_cents')
          .eq('booking_id', booking.id);

        const tableType = booking.site_table_types as unknown as { name: string } | null;
        const venue = booking.site_venues as unknown as { name: string } | null;
        const timeSlot = booking.site_venue_time_slots as unknown as { start_time: string } | null;

        const lineItems = [
          { label: tableType?.name ?? 'Table', amountCents: booking.deposit_cents },
          ...(bottles ?? []).map((b) => ({
            label: `${b.bottle_name}${b.size ? ` (${b.size})` : ''} × ${b.quantity}`,
            amountCents: b.line_total_cents,
          })),
          ...(booking.tax_cents > 0 ? [{ label: 'Tax', amountCents: booking.tax_cents }] : []),
          ...(booking.bottlesup_fee_cents > 0 ? [{ label: 'BottlesUp fee', amountCents: booking.bottlesup_fee_cents }] : []),
        ];

        setData({
          code: booking.confirmation_code ?? booking.id.slice(0, 8).toUpperCase(),
          title: tableType?.name ?? 'VIP Table',
          venue: venue?.name ?? '',
          date: booking.booking_date,
          time: timeSlot?.start_time ?? '',
          guestCount: booking.guest_count,
          status: booking.status,
          currency: booking.currency,
          lineItems,
          totalCents: booking.amount_total_cents,
          createdAt: booking.created_at,
        });
      }
      setLoading(false);
    };

    load();
  }, [authLoading, session, id, type]);

  const handleShare = async () => {
    if (!data) return;
    const text = `BottlesUp Booking: ${data.title} — ${data.date ? format(parseISO(data.date), 'MMM d, yyyy') : ''}`;
    if (navigator.share) {
      await navigator.share({ title: 'BottlesUp Booking', text });
    } else {
      await navigator.clipboard.writeText(text);
      toast({ title: 'Copied to clipboard' });
    }
  };

  const handleRequestCode = async () => {
    if (!id || requestingCode) return;
    setRequestingCode(true);
    try {
      const { data: sessionData } = await supabase.auth.getSession();
      const token = sessionData.session?.access_token;
      const { data: result, error } = await supabase.functions.invoke('request-ticket-otp', {
        body: { order_id: id },
        headers: token ? { Authorization: `Bearer ${token}` } : undefined,
      });
      if (error || result?.error) {
        toast({ title: 'Could not send code', description: result?.error ?? error?.message, variant: 'destructive' });
        return;
      }
      setCodeSentTo(result.email_preview ?? null);
      toast({ title: 'Entry code sent', description: 'Check your email - it expires in 5 minutes.' });
    } finally {
      setRequestingCode(false);
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

  if (!data) {
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

  const isTable = type === 'table';
  const dateStr = data.date ? (() => { try { return format(parseISO(data.date!), 'EEEE, MMMM d, yyyy'); } catch { return data.date; } })() : '';
  const { icon: StatusIcon, color: statusColor, label: statusLabel } = statusConfig[data.status] ?? statusConfig.pending;

  return (
    <>
      <Header />
      <div className="min-h-screen bg-black pt-24 pb-16 px-4">
        <div className="mx-auto max-w-lg">
          <button
            onClick={() => navigate('/dashboard')}
            className="flex items-center gap-2 text-gray-400 hover:text-white mb-6 transition-colors"
          >
            <ArrowLeft className="h-4 w-4" />
            Back to Dashboard
          </button>

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

              <h1 className="text-xl font-bold text-white text-center mb-1">{data.title}</h1>
              {data.venue && <p className="text-gray-400 text-sm mb-4">{data.venue}</p>}

              <div id="booking-qr" className="bg-white p-4 rounded-2xl mb-4">
                <QRCodeSVG value={data.code} size={200} level="H" includeMargin={false} />
              </div>

              <p className="text-xs text-gray-500 mb-1">Confirmation Code</p>
              <p className="text-2xl font-mono font-bold text-white tracking-widest">{data.code}</p>

              <div className="flex items-center gap-2 mt-3">
                <StatusIcon className={`h-4 w-4 ${statusColor}`} />
                <span className={`text-sm font-medium ${statusColor}`}>{statusLabel}</span>
              </div>

              <p className="text-xs text-gray-500 mt-3 text-center">
                Screenshot or save this QR code. Door staff will scan it at entry.
              </p>

              {!isTable && data.isNonTransferable && (
                <div className="mt-4 w-full rounded-xl border border-orange-500/20 bg-orange-500/5 p-3 text-center">
                  <p className="text-xs text-gray-400 mb-2">
                    This ticket is non-transferable. Request your entry code when you arrive at the door.
                  </p>
                  <Button
                    size="sm"
                    variant="outline"
                    className="border-orange-500/40 text-orange-400 hover:bg-orange-500/10"
                    onClick={handleRequestCode}
                    disabled={requestingCode}
                  >
                    <KeyRound className="mr-2 h-4 w-4" />
                    {requestingCode ? 'Sending...' : 'Get Entry Code'}
                  </Button>
                  {codeSentTo && <p className="mt-2 text-xs text-gray-500">Sent to {codeSentTo}</p>}
                </div>
              )}
            </div>

            <Separator className="bg-white/5" />

            <div className="p-5 space-y-3">
              {dateStr && (
                <div className="flex items-center gap-3 text-sm">
                  <Calendar className="h-4 w-4 text-gray-500 shrink-0" />
                  <span className="text-gray-300">{dateStr}</span>
                </div>
              )}
              {data.time && (
                <div className="flex items-center gap-3 text-sm">
                  <Clock className="h-4 w-4 text-gray-500 shrink-0" />
                  <span className="text-gray-300">{data.time}</span>
                </div>
              )}
              {data.venue && (
                <div className="flex items-center gap-3 text-sm">
                  <MapPin className="h-4 w-4 text-gray-500 shrink-0" />
                  <span className="text-gray-300">{data.venue}</span>
                </div>
              )}
              {data.guestCount != null && (
                <div className="flex items-center gap-3 text-sm">
                  <Users className="h-4 w-4 text-gray-500 shrink-0" />
                  <span className="text-gray-300">{data.guestCount} guests</span>
                </div>
              )}

              <Separator className="bg-white/5 my-2" />

              <div className="space-y-1.5">
                {data.lineItems.map((item, i) => (
                  <div key={i} className="flex justify-between text-sm">
                    <span className="text-gray-400">{item.label}</span>
                    <span className="text-gray-300">{formatMoney(item.amountCents, data.currency)}</span>
                  </div>
                ))}
                <div className="flex justify-between text-sm font-bold pt-1">
                  <span className="text-white">Total</span>
                  <span className="text-orange-500">{formatMoney(data.totalCents, data.currency)}</span>
                </div>
              </div>
            </div>

            <div className="px-5 pb-5 grid grid-cols-2 gap-3">
              <Button variant="outline" className="border-white/10 text-white hover:bg-white/5" onClick={handleDownload}>
                <Download className="mr-2 h-4 w-4" />
                Save QR
              </Button>
              <Button variant="outline" className="border-white/10 text-white hover:bg-white/5" onClick={handleShare}>
                <Share2 className="mr-2 h-4 w-4" />
                Share
              </Button>
            </div>
          </div>

          <p className="text-center text-xs text-gray-600 mt-4">
            Booked on {format(parseISO(data.createdAt), 'MMM d, yyyy')}
          </p>
        </div>
      </div>
    </>
  );
}
