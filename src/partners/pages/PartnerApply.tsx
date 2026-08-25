import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ArrowLeft, Building2, Megaphone, Music } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { isDisposableEmail } from '@/lib/disposableEmail';
import type { PartnerType } from '@/types/database';

const ROLE_OPTIONS: { value: PartnerType; label: string; description: string; icon: typeof Building2 }[] = [
  { value: 'venue_operator', label: 'Venue Owner', description: 'List your venue, manage tables and events', icon: Building2 },
  { value: 'promoter', label: 'Promoter', description: 'Run events and build guest lists', icon: Megaphone },
  { value: 'organizer', label: 'Organizer / Artist', description: 'Book gigs and manage performances', icon: Music },
];

const MIN_AGE = 18;
const MAX_AGE = 120;

function calculateAge(dob: string): number | null {
  const d = new Date(dob);
  if (Number.isNaN(d.getTime())) return null;
  const now = new Date();
  let age = now.getFullYear() - d.getFullYear();
  const monthDiff = now.getMonth() - d.getMonth();
  if (monthDiff < 0 || (monthDiff === 0 && now.getDate() < d.getDate())) age--;
  return age;
}

const PartnerApply = () => {
  const navigate = useNavigate();
  const { toast } = useToast();
  const [userType, setUserType] = useState<PartnerType>('venue_operator');
  const [legalName, setLegalName] = useState('');
  const [dateOfBirth, setDateOfBirth] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!legalName.trim() || !dateOfBirth || !email.trim() || !password) {
      toast({ title: 'Please fill in all fields', variant: 'destructive' });
      return;
    }
    const age = calculateAge(dateOfBirth);
    if (age === null) {
      toast({ title: 'Invalid date of birth', variant: 'destructive' });
      return;
    }
    if (age < MIN_AGE) {
      toast({ title: 'You must be 18 or older to register', variant: 'destructive' });
      return;
    }
    if (age > MAX_AGE) {
      toast({ title: 'Invalid date of birth', variant: 'destructive' });
      return;
    }
    if (isDisposableEmail(email)) {
      toast({ title: 'Please use a real email address', description: 'Disposable/temporary email addresses are not accepted.', variant: 'destructive' });
      return;
    }
    if (password.length < 8 || !/[A-Z]/.test(password) || !/[0-9]/.test(password) || !/[^A-Za-z0-9]/.test(password)) {
      toast({
        title: 'Password too weak',
        description: 'Use at least 8 characters, including one uppercase letter, one number, and one symbol.',
        variant: 'destructive',
      });
      return;
    }
    if (password !== confirmPassword) {
      toast({ title: 'Passwords do not match', variant: 'destructive' });
      return;
    }

    setSubmitting(true);
    try {
      const { data: signUpData, error: signUpError } = await supabase.auth.signUp({ email: email.trim(), password });
      if (signUpError) throw signUpError;
      if (!signUpData.user) throw new Error('Failed to create account');

      const { error: accountError } = await supabase.rpc('create_partner_account', {
        p_user_type: userType,
        p_legal_name: legalName.trim(),
        p_date_of_birth: dateOfBirth,
      });
      if (accountError) throw accountError;

      toast({
        title: 'Application received!',
        description: 'Check your email to confirm your account, then sign in to continue.',
      });
      navigate('/partners/login');
    } catch (error) {
      toast({
        title: 'Could not submit application',
        description: error instanceof Error ? error.message : 'Please try again.',
        variant: 'destructive',
      });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="flex min-h-screen flex-col items-center bg-black px-4 py-12">
      <Link to="/" className="mb-6 inline-flex items-center gap-2 text-sm text-gray-400 transition-colors hover:text-primary">
        <ArrowLeft className="h-4 w-4" />
        Back to website
      </Link>

      <div className="w-full max-w-lg rounded-2xl border border-gray-800 bg-gray-900/50 p-8">
        <h1 className="mb-1 text-2xl font-bold text-white">Partner with BottlesUp</h1>
        <p className="mb-6 text-sm text-gray-400">
          Step 1 of 8 - Create your account. We'll email you when the next step (profile & verification) is ready.
        </p>

        <div className="mb-6 grid grid-cols-1 gap-2 sm:grid-cols-3">
          {ROLE_OPTIONS.map((role) => {
            const Icon = role.icon;
            const selected = userType === role.value;
            return (
              <button
                key={role.value}
                type="button"
                onClick={() => setUserType(role.value)}
                className={`rounded-lg border p-3 text-left transition-colors ${
                  selected ? 'border-primary bg-primary/10 ring-1 ring-primary' : 'border-gray-800 hover:border-primary/40'
                }`}
              >
                <Icon className="mb-1.5 h-5 w-5 text-primary" />
                <div className="text-sm font-medium text-white">{role.label}</div>
                <div className="text-xs text-gray-500">{role.description}</div>
              </button>
            );
          })}
        </div>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label className="text-gray-300">Legal Name</Label>
            <Input value={legalName} onChange={(e) => setLegalName(e.target.value)} placeholder="As it appears on your ID" required />
          </div>
          <div className="space-y-2">
            <Label className="text-gray-300">Date of Birth</Label>
            <Input type="date" value={dateOfBirth} onChange={(e) => setDateOfBirth(e.target.value)} required />
            <p className="text-xs text-gray-500">You must be 18 or older to register as a partner.</p>
          </div>
          <div className="space-y-2">
            <Label className="text-gray-300">Email</Label>
            <Input type="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
          </div>
          <div className="space-y-2">
            <Label className="text-gray-300">Password</Label>
            <Input type="password" value={password} onChange={(e) => setPassword(e.target.value)} required />
            <p className="text-xs text-gray-500">At least 8 characters, with an uppercase letter, a number, and a symbol.</p>
          </div>
          <div className="space-y-2">
            <Label className="text-gray-300">Confirm Password</Label>
            <Input type="password" value={confirmPassword} onChange={(e) => setConfirmPassword(e.target.value)} required />
          </div>

          <Button
            type="submit"
            disabled={submitting}
            className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
          >
            {submitting ? 'Submitting...' : 'Create Partner Account'}
          </Button>
        </form>

        <p className="mt-4 text-center text-xs text-gray-500">
          Already applied?{' '}
          <Link to="/partners/login" className="text-primary hover:underline">
            Sign in
          </Link>
        </p>
      </div>
    </div>
  );
};

export default PartnerApply;
