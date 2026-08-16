import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { format, parseISO, isAfter } from 'date-fns';
import { Loader2, Calendar, MapPin, Users, ChevronDown, ChevronUp, Ticket, TableIcon } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { useUserAuth } from '@/hooks/useUserAuth';
import { useUserBookings, type UnifiedBooking } from '@/hooks/useUserBookings';
import { formatMoney, statusBadgeClass } from '@/lib/bookingFormat';
import UserAuthModal from '@/components/UserAuthModal';
import Header from '@/components/Header';

const isUpcoming = (b: UnifiedBooking) => {
  if (!b.date) return false;
  try { return isAfter(parseISO(b.date), new Date()); } catch { return false; }
};

function BookingCard({ booking }: { booking: UnifiedBooking }) {
  let date: Date | null = null;
  try { date = booking.date ? parseISO(booking.date) : null; } catch { date = null; }

  return (
    <Link
      to={`/bookings/${booking.type}/${booking.id}`}
      className="block rounded-xl border border-white/10 bg-zinc-900 p-4 hover:border-orange-500/40 hover:bg-zinc-800 transition-all"
    >
      <div className="flex items-start justify-between gap-3">
        <div className="flex items-start gap-3 min-w-0">
          <div className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-orange-500/10">
            {booking.type === 'table' ? (
              <TableIcon className="h-4 w-4 text-orange-500" />
            ) : (
              <Ticket className="h-4 w-4 text-orange-500" />
            )}
          </div>
          <div className="min-w-0">
            <p className="font-semibold text-white truncate">{booking.title}</p>
            {booking.venue && (
              <p className="text-sm text-gray-400 flex items-center gap-1 mt-0.5">
                <MapPin className="h-3 w-3 shrink-0" />
                {booking.venue}
              </p>
            )}
            {date && (
              <p className="text-sm text-gray-400 flex items-center gap-1 mt-0.5">
                <Calendar className="h-3 w-3 shrink-0" />
                {format(date, 'MMM d, yyyy')}
                {booking.time && ` · ${booking.time}`}
              </p>
            )}
            {booking.guestCount != null && (
              <p className="text-sm text-gray-400 flex items-center gap-1 mt-0.5">
                <Users className="h-3 w-3 shrink-0" />
                {booking.guestCount} guests
              </p>
            )}
          </div>
        </div>
        <div className="text-right shrink-0">
          <p className="font-bold text-white">{formatMoney(booking.amountCents, booking.currency)}</p>
          <Badge
            variant="outline"
            className={`mt-1 text-xs capitalize ${statusBadgeClass[booking.status] ?? 'border-white/20 text-gray-400'}`}
          >
            {booking.status}
          </Badge>
        </div>
      </div>
    </Link>
  );
}

export default function UserDashboard() {
  const navigate = useNavigate();
  const { session, profile, loading } = useUserAuth();
  const [authOpen, setAuthOpen] = useState(false);
  const { bookings, loading: loadingBookings } = useUserBookings(session);
  const [showPast, setShowPast] = useState(false);

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-black">
        <Loader2 className="h-8 w-8 animate-spin text-orange-500" />
      </div>
    );
  }

  if (!session) {
    return (
      <>
        <Header />
        <div className="flex min-h-screen flex-col items-center justify-center bg-black px-4 text-center pt-20">
          <Ticket className="mb-4 h-12 w-12 text-orange-500" />
          <h1 className="mb-2 text-2xl font-bold text-white">Your Bookings</h1>
          <p className="mb-8 max-w-sm text-gray-400">
            Sign in to view your upcoming events, VIP table reservations, and QR tickets.
          </p>
          <Button
            onClick={() => setAuthOpen(true)}
            className="bg-gradient-orange text-black font-bold hover:opacity-90 px-8"
          >
            Sign In
          </Button>
        </div>
        <UserAuthModal open={authOpen} onOpenChange={setAuthOpen} />
      </>
    );
  }

  const paid = bookings.filter((b) => b.status === 'paid');
  const upcoming = paid.filter(isUpcoming);
  const past = paid.filter((b) => !isUpcoming(b));
  const displayName = profile?.name ?? session.user.email?.split('@')[0] ?? 'there';

  return (
    <>
      <Header />
      <div className="min-h-screen bg-black pt-24 pb-16 px-4">
        <div className="mx-auto max-w-2xl">
          {/* Greeting */}
          <div className="mb-8">
            <p className="text-orange-500 text-sm font-medium mb-1">Welcome back</p>
            <h1 className="text-3xl font-bold text-white">{displayName} 👋</h1>
            <p className="text-gray-400 mt-1">
              {upcoming.length > 0
                ? `You have ${upcoming.length} upcoming booking${upcoming.length > 1 ? 's' : ''}`
                : 'No upcoming bookings yet'}
            </p>
          </div>

          {loadingBookings ? (
            <div className="flex justify-center py-16">
              <Loader2 className="h-8 w-8 animate-spin text-orange-500" />
            </div>
          ) : (
            <>
              {/* Upcoming */}
              <section>
                <h2 className="text-sm font-semibold uppercase tracking-wider text-gray-500 mb-3">Upcoming</h2>
                {upcoming.length === 0 ? (
                  <div className="rounded-xl border border-dashed border-white/10 p-8 text-center">
                    <p className="text-gray-500">No upcoming bookings</p>
                    <div className="mt-4 flex gap-3 justify-center">
                      <Button
                        variant="outline"
                        size="sm"
                        className="border-white/10 text-white hover:bg-white/5"
                        onClick={() => navigate('/events')}
                      >
                        Browse Events
                      </Button>
                      <Button
                        variant="outline"
                        size="sm"
                        className="border-white/10 text-white hover:bg-white/5"
                        onClick={() => navigate('/vip-tables')}
                      >
                        VIP Tables
                      </Button>
                    </div>
                  </div>
                ) : (
                  <div className="space-y-3">
                    {upcoming.map((b) => <BookingCard key={`${b.type}-${b.id}`} booking={b} />)}
                  </div>
                )}
              </section>

              {/* Past */}
              {past.length > 0 && (
                <section className="mt-8">
                  <button
                    onClick={() => setShowPast((v) => !v)}
                    className="flex items-center gap-2 text-sm font-semibold uppercase tracking-wider text-gray-500 hover:text-gray-300 transition-colors mb-3"
                  >
                    Past ({past.length})
                    {showPast ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
                  </button>
                  {showPast && (
                    <div className="space-y-3 opacity-70">
                      {past.map((b) => <BookingCard key={`${b.type}-${b.id}`} booking={b} />)}
                    </div>
                  )}
                </section>
              )}

              {/* Quick links */}
              <div className="mt-10 flex gap-3">
                <Button
                  variant="outline"
                  className="border-white/10 text-white hover:bg-white/5"
                  onClick={() => navigate('/profile')}
                >
                  Account Settings
                </Button>
              </div>
            </>
          )}
        </div>
      </div>
    </>
  );
}
