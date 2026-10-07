import { useEffect, useRef, useState } from 'react';
import { Navigate, useNavigate, useSearchParams } from 'react-router-dom';
import { Loader2, Check, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import { useToast } from '@/hooks/use-toast';
import { skipProfileThisSession, useAccount } from '@/hooks/useAccount';
import { userUploadAvatar } from '@/hooks/useUserAuth';
import { AccountError, fetchMyProfile, saveMyProfile, usernameAvailable } from '@/lib/account';
import { normalizeUsername, USERNAME_HELP, validateUsernameShape } from '@/lib/profileForm';
import { sanitizeNext, withNext } from '@/lib/safeNext';
import AccountShell from '../components/AccountShell';
import { FullPageSpinner } from './Home';

type Availability = 'idle' | 'checking' | 'available' | 'taken' | 'invalid';

const SOCIALS: { key: string; label: string; placeholder: string }[] = [
  { key: 'instagram', label: 'Instagram', placeholder: '@yourname' },
  { key: 'tiktok', label: 'TikTok', placeholder: '@yourname' },
  { key: 'x', label: 'X', placeholder: '@yourname' },
  { key: 'website', label: 'Website', placeholder: 'https://' },
];

/**
 * "Complete Your Profile": the first task after registering. An existing app user with an unfinished
 * profile lands here too, rather than in a second registration flow.
 */
const ProfileOnboarding = () => {
  const { loading, session, refresh } = useAccount();
  const [params] = useSearchParams();
  const next = sanitizeNext(params.get('next'), '');
  const navigate = useNavigate();
  const { toast } = useToast();

  const [ready, setReady] = useState(false);
  const [name, setName] = useState('');
  const [username, setUsername] = useState('');
  const [city, setCity] = useState('');
  const [bio, setBio] = useState('');
  const [social, setSocial] = useState<Record<string, string>>({});
  const [photo, setPhoto] = useState<File | null>(null);
  const [availability, setAvailability] = useState<Availability>('idle');
  const [saving, setSaving] = useState(false);
  const checkTicket = useRef(0);
  const userId = session?.user.id;

  // Pre-fill from whatever the account already has (an existing app user keeps their name).
  useEffect(() => {
    if (!session) return;
    let cancelled = false;
    fetchMyProfile(session.user.id).then((p) => {
      if (cancelled) return;
      const meta = session.user.user_metadata as Record<string, unknown> | undefined;
      setName(p?.name ?? (typeof meta?.full_name === 'string' ? meta.full_name : ''));
      setUsername(p?.username ?? '');
      setCity(p?.city ?? '');
      setBio(p?.bio ?? '');
      setSocial(p?.social_links ?? {});
      setReady(true);
    });
    return () => {
      cancelled = true;
    };
  }, [session]);

  // Live "is this username free?", ignoring answers that arrive late.
  useEffect(() => {
    const value = normalizeUsername(username);
    if (!value) return setAvailability('idle');
    if (validateUsernameShape(value)) return setAvailability('invalid');
    setAvailability('checking');
    const ticket = ++checkTicket.current;
    const timer = window.setTimeout(async () => {
      try {
        const free = await usernameAvailable(value);
        if (ticket === checkTicket.current) setAvailability(free ? 'available' : 'taken');
      } catch {
        if (ticket === checkTicket.current) setAvailability('idle');
      }
    }, 350);
    return () => window.clearTimeout(timer);
  }, [username]);

  if (loading) return <FullPageSpinner />;
  if (!session) return <Navigate to={withNext('/login', '/onboarding/profile')} replace />;

  const skip = () => {
    skipProfileThisSession();
    navigate(withNext('/home', next), { replace: true });
  };

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    const shape = validateUsernameShape(normalizeUsername(username));
    if (!name.trim() || !city.trim()) {
      toast({ title: 'Name and city are required', variant: 'destructive' });
      return;
    }
    if (shape) {
      toast({ title: 'Check your username', description: shape, variant: 'destructive' });
      return;
    }
    setSaving(true);
    try {
      await saveMyProfile({ name, username: normalizeUsername(username), city, bio, social });
      if (photo && userId) {
        try {
          await userUploadAvatar(userId, photo);
        } catch {
          // The profile is saved; only the photo failed. Say so instead of losing everything.
          toast({ title: 'Profile saved, but the photo did not upload', description: 'You can add it later from your profile.' });
        }
      }
      await refresh();
      navigate(withNext('/home', next), { replace: true });
    } catch (err) {
      toast({ title: 'Could not save your profile', description: err instanceof AccountError ? err.message : 'Please try again.', variant: 'destructive' });
    } finally {
      setSaving(false);
    }
  };

  if (!ready) return <FullPageSpinner />;

  return (
    <AccountShell title="Complete your profile" subtitle="This is how other people see you on BottlesUp." wide>
      <form onSubmit={submit} className="space-y-5" noValidate>
        <div className="grid gap-5 sm:grid-cols-2">
          <div className="space-y-2">
            <Label htmlFor="pf-name" className="text-gray-300">Name</Label>
            <Input id="pf-name" value={name} onChange={(e) => setName(e.target.value)} maxLength={100} required />
          </div>
          <div className="space-y-2">
            <Label htmlFor="pf-city" className="text-gray-300">City</Label>
            <Input id="pf-city" value={city} onChange={(e) => setCity(e.target.value)} maxLength={80} required />
          </div>
        </div>

        <div className="space-y-2">
          <Label htmlFor="pf-username" className="text-gray-300">Username</Label>
          <div className="relative">
            <Input
              id="pf-username"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              maxLength={30}
              autoCapitalize="none"
              autoCorrect="off"
              spellCheck={false}
              aria-describedby="pf-username-help"
              required
            />
            <span className="absolute right-3 top-1/2 -translate-y-1/2" aria-live="polite">
              {availability === 'checking' && <Loader2 className="h-4 w-4 animate-spin text-gray-500" />}
              {availability === 'available' && <Check className="h-4 w-4 text-green-400" aria-label="Available" />}
              {(availability === 'taken' || availability === 'invalid') && <X className="h-4 w-4 text-red-400" aria-label="Not available" />}
            </span>
          </div>
          <p id="pf-username-help" className="text-xs text-gray-500">
            {availability === 'taken' ? 'That username is taken. Try another.' : availability === 'invalid' ? validateUsernameShape(normalizeUsername(username)) : USERNAME_HELP}
          </p>
        </div>

        <div className="space-y-2">
          <Label htmlFor="pf-bio" className="text-gray-300">Short bio <span className="text-gray-500">(optional)</span></Label>
          <Textarea id="pf-bio" value={bio} onChange={(e) => setBio(e.target.value)} maxLength={280} rows={3} />
          <p className="text-right text-xs text-gray-500">{bio.length}/280</p>
        </div>

        <div className="space-y-2">
          <Label htmlFor="pf-photo" className="text-gray-300">Profile photo <span className="text-gray-500">(optional)</span></Label>
          <Input id="pf-photo" type="file" accept="image/*" onChange={(e) => setPhoto(e.target.files?.[0] ?? null)} />
        </div>

        <fieldset className="space-y-3">
          <legend className="text-sm text-gray-300">Social links <span className="text-gray-500">(optional)</span></legend>
          <div className="grid gap-3 sm:grid-cols-2">
            {SOCIALS.map((s) => (
              <Input
                key={s.key}
                aria-label={s.label}
                placeholder={`${s.label} ${s.placeholder}`}
                value={social[s.key] ?? ''}
                onChange={(e) => setSocial((prev) => ({ ...prev, [s.key]: e.target.value }))}
                maxLength={200}
              />
            ))}
          </div>
        </fieldset>

        <div className="flex flex-col gap-3 pt-2 sm:flex-row">
          <Button type="submit" disabled={saving || availability === 'taken'} className="flex-1 bg-gradient-orange font-bold text-black hover:opacity-90">
            {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Save and continue'}
          </Button>
          <Button type="button" variant="ghost" onClick={skip} disabled={saving} className="text-gray-400 hover:bg-white/5 hover:text-white">
            Skip for now
          </Button>
        </div>
      </form>
    </AccountShell>
  );
};

export default ProfileOnboarding;
