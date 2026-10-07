import { useEffect, useMemo, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { Check } from 'lucide-react';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { AccountError, fetchOrgVenues } from '@/lib/account';
import { onboardingPath, type Business, type Workspace } from '@/lib/accountRouting';
import { formatMoney } from '@/lib/bookingFormat';
import { formatTimeSlot } from '@/lib/bookingNight';
import {
  applyFilter, groupByNight, nightCount, presets, ROW_LIMIT, statusInfo, summarize, validateRange,
  type BookingFilter, type BookingRow, type NightRange, type StatusTone,
} from '@/lib/bookingsView';
import { listVenueBookings } from '@/lib/venueBookingsApi';
import NativeSelect from '../components/NativeSelect';
import { VerificationBanner } from './OwnerSections';

const TONE: Record<StatusTone, string> = {
  good: 'border-green-500/40 text-green-300',
  wait: 'border-amber-500/40 text-amber-300',
  bad: 'border-red-500/40 text-red-300',
  neutral: 'border-gray-700 text-gray-400',
};

function useBookings(venueId: string, range: NightRange) {
  const [rows, setRows] = useState<BookingRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const latest = useRef(0);
  const problem = validateRange(range);

  useEffect(() => {
    // An invalid range must not leave the previous range's numbers on screen under a warning about the new one.
    if (!venueId || problem) {
      latest.current += 1;
      setRows(null);
      setError(null);
      return;
    }
    const mine = ++latest.current;
    setRows(null);
    setError(null);
    listVenueBookings(venueId, range.from, range.to)
      .then((r) => { if (mine === latest.current) setRows(r); })
      .catch((err) => { if (mine === latest.current) setError(err instanceof AccountError ? err.message : 'Bookings could not be loaded. Try again.'); });
  }, [venueId, range.from, range.to, problem]);

  return { rows, error, problem };
}

const Tile = ({ label, value, hint }: { label: string; value: number; hint?: string }) => (
  <div className="rounded-xl border border-gray-800 bg-gray-900/50 p-4">
    <p className="text-2xl font-semibold text-white">{value}</p>
    <p className="text-sm text-gray-300">{label}</p>
    {hint && <p className="mt-1 text-xs text-gray-500">{hint}</p>}
  </div>
);

const BookingItem = ({ b }: { b: BookingRow }) => {
  const info = statusInfo(b.status);
  return (
    <li className="flex flex-wrap items-start gap-x-6 gap-y-2 px-4 py-3">
      <div className="w-24 shrink-0">
        <p className="text-sm font-medium text-white">{formatTimeSlot(b.startTime)}</p>
        {b.slotLabel && <p className="text-xs text-gray-500">{b.slotLabel}</p>}
      </div>
      <div className="min-w-[12rem] flex-1">
        <p className="text-sm font-medium text-white">{b.customerName}</p>
        <p className="text-xs text-gray-400">{b.tableName} · {b.guestCount} {b.guestCount === 1 ? 'guest' : 'guests'}</p>
        <p className="mt-1 flex flex-wrap gap-x-3 text-xs text-gray-500">
          {b.customerPhone && <a href={`tel:${b.customerPhone}`} className="hover:text-white hover:underline">{b.customerPhone}</a>}
          {b.customerEmail && <a href={`mailto:${b.customerEmail}`} className="break-all hover:text-white hover:underline">{b.customerEmail}</a>}
        </p>
      </div>
      <div className="flex flex-col items-start gap-1 sm:items-end">
        <span className="flex flex-wrap items-center gap-2">
          {b.checkedInAt && info.confirmed && (
            <span className="inline-flex items-center gap-1 rounded-full border border-green-500/40 px-2 py-0.5 text-xs text-green-300"><Check className="h-3 w-3" /> Arrived</span>
          )}
          <span className={`rounded-full border px-2 py-0.5 text-xs ${TONE[info.tone]}`}>{info.label}</span>
        </span>
        <p className="text-xs text-gray-400">
          Booked {formatMoney(b.amountTotalCents, b.currency)}{b.depositCents > 0 ? ` · deposit ${formatMoney(b.depositCents, b.currency)}` : ''}
        </p>
        {b.confirmationCode && <p className="font-mono text-xs text-gray-500">{b.confirmationCode}</p>}
      </div>
    </li>
  );
};

/**
 * Tables & Bookings, read only: the reservations of an owner's venues, night by night. The database decides who may read a
 * venue's bookings and which night each one belongs to (a 1:00 AM table is the night before). Amounts are what was booked, not
 * what was collected; walk-ins, guest allowances, table assignment and check-in are not on the website yet.
 */
const OwnerBookings = ({ workspace, business }: { workspace: Workspace; business: Business | undefined }) => {
  const [venues, setVenues] = useState<{ venueId: string; name: string }[] | null>(null);
  const [venuesFailed, setVenuesFailed] = useState(false);
  const [venueId, setVenueId] = useState('');
  const now = useMemo(() => new Date(), []);
  const ready = useMemo(() => presets(now), [now]);
  const [presetId, setPresetId] = useState<string>('tonight');
  const [range, setRange] = useState<NightRange>(ready[0].range);
  const [filter, setFilter] = useState<BookingFilter>('confirmed');

  useEffect(() => {
    let cancelled = false;
    fetchOrgVenues(workspace.orgId)
      .then((v) => {
        if (cancelled) return;
        setVenues(v);
        setVenueId((current) => current || v[0]?.venueId || '');
      })
      .catch(() => { if (!cancelled) setVenuesFailed(true); });
    return () => { cancelled = true; };
  }, [workspace.orgId]);

  const { rows, error, problem } = useBookings(venueId, range);
  const shown = rows ? applyFilter(rows, filter) : [];
  const summary = rows ? summarize(rows) : null;
  const groups = groupByNight(shown);
  const hiddenCount = rows ? rows.length - shown.length : 0;

  return (
    <div>
      <VerificationBanner workspace={workspace} business={business} />

      {venuesFailed && <p className="text-sm text-red-300" role="alert">Your venues could not be loaded. Try again in a moment.</p>}
      {!venuesFailed && venues === null && <p className="text-sm text-gray-500">Loading your venues…</p>}
      {venues?.length === 0 && (
        <p className="text-sm text-gray-400">
          You have no venues yet, so there are no bookings to show. <Link to={onboardingPath(workspace.orgId)} className="text-primary hover:underline">Add or claim one</Link>.
        </p>
      )}

      {venues && venues.length > 0 && (
        <>
          <div className="mb-6 space-y-4 rounded-2xl border border-gray-800 bg-gray-900/50 p-4">
            {venues.length > 1 && (
              <div className="max-w-sm space-y-2">
                <Label htmlFor="bookings-venue" className="text-gray-300">Venue</Label>
                <NativeSelect id="bookings-venue" value={venueId} onChange={(e) => setVenueId(e.target.value)}>
                  {venues.map((v) => <option key={v.venueId} value={v.venueId}>{v.name}</option>)}
                </NativeSelect>
              </div>
            )}
            <div className="flex flex-wrap gap-2" role="group" aria-label="Nights to show">
              {ready.map((p) => (
                <button
                  key={p.id}
                  type="button"
                  aria-pressed={presetId === p.id}
                  onClick={() => { setPresetId(p.id); setRange(p.range); }}
                  className={`rounded-full border px-3 py-1.5 text-sm ${presetId === p.id ? 'border-primary bg-primary/15 text-primary' : 'border-gray-700 text-gray-300 hover:bg-white/5'}`}
                >
                  {p.label}
                </button>
              ))}
            </div>
            <div className="grid max-w-md gap-4 sm:grid-cols-2">
              <div className="space-y-2">
                <Label htmlFor="bookings-from" className="text-gray-300">From night</Label>
                <Input id="bookings-from" type="date" value={range.from} onChange={(e) => { setPresetId('custom'); setRange((r) => ({ ...r, from: e.target.value })); }} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="bookings-to" className="text-gray-300">To night</Label>
                <Input id="bookings-to" type="date" value={range.to} onChange={(e) => { setPresetId('custom'); setRange((r) => ({ ...r, to: e.target.value })); }} />
              </div>
            </div>
            {problem && <p className="text-sm text-amber-300" role="alert">{problem}</p>}
            <div className="flex flex-wrap items-center gap-2" role="group" aria-label="Which bookings">
              {(['confirmed', 'all'] as const).map((f) => (
                <button
                  key={f}
                  type="button"
                  aria-pressed={filter === f}
                  onClick={() => setFilter(f)}
                  className={`rounded-full border px-3 py-1.5 text-sm ${filter === f ? 'border-primary bg-primary/15 text-primary' : 'border-gray-700 text-gray-300 hover:bg-white/5'}`}
                >
                  {f === 'confirmed' ? 'Confirmed only' : 'Everything, including unpaid and cancelled'}
                </button>
              ))}
            </div>
          </div>

          {error && <p className="text-sm text-red-300" role="alert">{error}</p>}
          {!error && !problem && rows === null && <p className="text-sm text-gray-500">Loading bookings…</p>}

          {summary && (
            <>
              <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
                <Tile label="Confirmed bookings" value={summary.bookings} hint={`${nightCount(range)} ${nightCount(range) === 1 ? 'night' : 'nights'}`} />
                <Tile label="Guests expected" value={summary.guests} />
                <Tile label="Arrived" value={summary.checkedIn} hint="Checked in at the venue" />
                <Tile label="Awaiting payment" value={summary.awaitingPayment} hint="Started, not paid yet" />
              </div>

              {rows && rows.length >= ROW_LIMIT && (
                <p className="mb-4 rounded-lg border border-amber-500/30 bg-amber-500/10 p-3 text-sm text-amber-200" role="alert">
                  Only the first {ROW_LIMIT} bookings are shown. Choose fewer nights to see the rest.
                </p>
              )}

              {groups.length === 0 && (
                <p className="rounded-xl border border-dashed border-gray-800 p-6 text-center text-sm text-gray-400">
                  {filter === 'confirmed' && hiddenCount > 0
                    ? `No confirmed bookings for these nights. ${hiddenCount} unpaid or cancelled ${hiddenCount === 1 ? 'is' : 'are'} hidden; choose “Everything” to see them.`
                    : 'No bookings for these nights.'}
                </p>
              )}

              <div className="space-y-6">
                {groups.map((g) => (
                  <section key={g.night} aria-label={g.label}>
                    <h3 className="mb-2 flex items-baseline justify-between text-sm font-medium text-gray-300">
                      <span>{g.label}</span>
                      <span className="text-xs font-normal text-gray-500">{g.guests} {g.guests === 1 ? 'guest' : 'guests'} expected</span>
                    </h3>
                    <ul className="divide-y divide-gray-800 rounded-xl border border-gray-800">
                      {g.rows.map((b) => <BookingItem key={b.bookingId} b={b} />)}
                    </ul>
                  </section>
                ))}
              </div>

              <p className="mt-6 text-xs text-gray-500">
                Amounts are what was booked, not what has been collected. Walk-ins, guest allowances, table assignment, check-in and bottle
                orders are not on the website yet.
              </p>
            </>
          )}
        </>
      )}
    </div>
  );
};

export default OwnerBookings;
