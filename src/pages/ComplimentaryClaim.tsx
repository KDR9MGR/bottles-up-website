import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { CheckCircle2, Loader2, MapPin } from 'lucide-react';
import { Button } from '@/components/ui/button';
import {
  endMessage,
  expiryText,
  giftLabel,
  isClaimToken,
  listedTables,
  mapFloors,
  markerStyle,
  submitClaim,
  tablesOnFloor,
  viewClaim,
  type ClaimResult,
} from '@/lib/compClaim';

// Public, no login required: reached by the link in the e-mail a club sends with a complimentary bottle. The token in the address is the capability (the same idea as
// /club-payment/confirm/:token). The page asks the comp-claim function, which counts every visit and returns only what is shown here; it never shows another guest or a booking.
const ComplimentaryClaim = () => {
  const { token } = useParams<{ token: string }>();
  const [result, setResult] = useState<ClaimResult | null>(null);
  const [chosen, setChosen] = useState<string | null>(null);
  const [floorId, setFloorId] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [problem, setProblem] = useState<Exclude<ClaimResult, { state: 'open' }> | null>(null);

  // A page with a secret in its address is not for search engines.
  useEffect(() => {
    const meta = document.createElement('meta');
    meta.name = 'robots';
    meta.content = 'noindex, nofollow';
    document.head.appendChild(meta);
    const previous = document.title;
    document.title = 'Your complimentary bottle';
    return () => {
      document.head.removeChild(meta);
      document.title = previous;
    };
  }, []);

  useEffect(() => {
    // A link that cannot be one never reaches the server.
    if (!isClaimToken(token)) {
      setResult({ state: 'not_found' });
      return;
    }
    let live = true;
    viewClaim(token).then((r) => {
      if (!live) return;
      setResult(r);
      if (r.state === 'open') setFloorId(mapFloors(r)[0]?.id ?? null);
    });
    return () => {
      live = false;
    };
  }, [token]);

  const submit = async () => {
    if (!isClaimToken(token) || !chosen || submitting) return;
    setSubmitting(true);
    setProblem(null);
    const r = await submitClaim(token, chosen);
    setSubmitting(false);
    // Choosing again (a place that is not this venue's) or trying again later keeps the form; anything else is the end of it.
    if (r.state === 'open') setProblem({ state: 'error' });
    else if (r.state === 'bad_table' || r.state === 'rate_limited' || r.state === 'error') setProblem(r);
    else setResult(r);
  };

  if (result === null) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-black" role="status" aria-label="Loading your offer">
        <Loader2 className="h-8 w-8 animate-spin text-orange-500" />
      </div>
    );
  }

  if (result.state !== 'open') {
    const { title, body } = endMessage(result);
    const good = result.state === 'submitted' || result.state === 'claimed';
    return (
      <div className="flex min-h-screen flex-col items-center justify-center bg-black px-4 text-center">
        {good && <CheckCircle2 className="mb-4 h-12 w-12 text-green-500" aria-hidden="true" />}
        <h1 className="text-2xl font-bold text-white">{title}</h1>
        <p className="mt-2 max-w-md text-gray-400">{body}</p>
        <Button asChild className="mt-6 bg-gradient-orange text-black font-bold hover:opacity-90">
          <Link to="/">Back to BottlesUp</Link>
        </Button>
      </div>
    );
  }

  const claim = result;
  const floors = mapFloors(claim);
  const activeFloor = floors.find((f) => f.id === floorId) ?? floors[0] ?? null;
  const listed = listedTables(claim);
  const chosenTable = claim.tables.find((t) => t.id === chosen) ?? null;

  return (
    <div className="flex min-h-screen flex-col items-center bg-black px-4 py-10">
      <div className="w-full max-w-md space-y-6">
        <header className="space-y-2 text-center">
          <p className="text-sm font-semibold uppercase tracking-wide text-orange-500">{claim.venueName}</p>
          <h1 className="text-3xl font-bold text-white">A bottle on the house</h1>
          {claim.recipientName && <p className="text-gray-300">Hi {claim.recipientName},</p>}
          <p className="text-gray-300">
            {claim.venueName} would like to give you <strong className="text-white">{giftLabel(claim)}</strong>
            {claim.eventTitle ? ` for ${claim.eventTitle}` : ''}.
          </p>
          {claim.sign && <p className="rounded-lg border border-border bg-card px-3 py-2 text-sm italic text-gray-200">&ldquo;{claim.sign}&rdquo;</p>}
          <p className="text-xs text-gray-500">This link works once and stops working on {expiryText(claim.expiresAt)}. Nothing is charged.</p>
        </header>

        <section aria-labelledby="where-title" className="space-y-3">
          <h2 id="where-title" className="text-lg font-semibold text-white">
            Where are you?
          </h2>
          <p className="text-sm text-gray-400">Choose your table or the place nearest you. A member of staff will bring your bottle to you.</p>

          {activeFloor && (
            <div className="space-y-2">
              {floors.length > 1 && (
                <div className="flex flex-wrap gap-2" role="tablist" aria-label="Floors">
                  {floors.map((f) => (
                    <button
                      key={f.id}
                      type="button"
                      role="tab"
                      aria-selected={f.id === activeFloor.id}
                      onClick={() => setFloorId(f.id)}
                      className={`rounded-full border px-3 py-1 text-xs font-semibold ${f.id === activeFloor.id ? 'border-primary bg-primary/20 text-white' : 'border-border text-gray-400'}`}
                    >
                      {f.label}
                    </button>
                  ))}
                </div>
              )}
              <div className="relative w-full select-none overflow-hidden rounded-lg border border-border">
                <img src={activeFloor.imageUrl ?? undefined} alt={`${activeFloor.label} floor plan`} className="block w-full" />
                {tablesOnFloor(claim, activeFloor.id).map((t) => (
                  <button
                    key={t.id}
                    type="button"
                    aria-pressed={t.id === chosen}
                    aria-label={t.name}
                    onClick={() => setChosen(t.id)}
                    className={`absolute flex items-center justify-center rounded border-2 text-[10px] font-bold uppercase tracking-wide transition-colors ${
                      t.id === chosen ? 'border-white bg-primary text-black' : 'border-primary bg-primary/25 text-white hover:bg-primary/40'
                    }`}
                    style={markerStyle(t)}
                  >
                    <span className="truncate px-1">{t.name}</span>
                  </button>
                ))}
              </div>
            </div>
          )}

          {listed.length > 0 && (
            <div className="space-y-2">
              {activeFloor && <p className="text-sm font-semibold text-white">More places</p>}
              <ul className="space-y-2">
                {listed.map((t) => (
                  <li key={t.id}>
                    <button
                      type="button"
                      aria-pressed={t.id === chosen}
                      onClick={() => setChosen(t.id)}
                      className={`flex w-full items-center gap-2 rounded-lg border px-3 py-3 text-left text-sm ${t.id === chosen ? 'border-primary bg-primary/20 text-white' : 'border-border bg-card text-gray-200'}`}
                    >
                      <MapPin className="h-4 w-4 shrink-0 text-orange-500" aria-hidden="true" />
                      {t.name}
                    </button>
                  </li>
                ))}
              </ul>
            </div>
          )}

          {claim.tables.length === 0 && <p className="text-sm text-gray-400">This venue has not listed its tables. Ask a member of staff and they will find you.</p>}
        </section>

        {problem && (
          <p role="alert" className="rounded-lg border border-red-500/40 bg-red-500/10 px-3 py-2 text-sm text-red-200">
            {endMessage(problem).title}. {endMessage(problem).body}
          </p>
        )}

        <div className="space-y-2">
          {chosenTable && <p className="text-center text-sm text-gray-300">You are at: <strong className="text-white">{chosenTable.name}</strong></p>}
          <Button
            type="button"
            disabled={!chosenTable || submitting}
            onClick={submit}
            className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
          >
            {submitting ? 'Telling the staff…' : 'Tell them where I am'}
          </Button>
        </div>
      </div>
    </div>
  );
};

export default ComplimentaryClaim;
