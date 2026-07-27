import { useState } from 'react';
import { Navigate, useLocation } from 'react-router-dom';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { getAuthRedirectBase } from '@/lib/authRedirect';
import { doorSignOut, useDoorAuth } from '../useDoorAuth';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const DoorLogin = () => {
  const { session, isDoorStaff, loading } = useDoorAuth();
  const location = useLocation();
  const { toast } = useToast();
  const [email, setEmail] = useState('');
  const [sending, setSending] = useState(false);
  const [linkSent, setLinkSent] = useState(false);

  if (!loading && session && isDoorStaff) {
    const from = (location.state as { from?: Location })?.from?.pathname ?? '/door/scan';
    return <Navigate to={from} replace />;
  }

  if (!loading && session && !isDoorStaff) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center bg-black px-4 text-center">
        <h1 className="mb-2 text-2xl font-bold text-white">Not authorized</h1>
        <p className="mb-6 max-w-sm text-gray-400">
          {session.user.email} isn't registered as door staff. Ask an admin to add you in the CMS.
        </p>
        <Button variant="outline" className="border-gray-700 text-white hover:bg-gray-900" onClick={() => doorSignOut()}>
          Try a different email
        </Button>
      </div>
    );
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!EMAIL_RE.test(email)) {
      toast({ title: 'Please enter a valid email', variant: 'destructive' });
      return;
    }

    setSending(true);
    const { error } = await supabase.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: `${getAuthRedirectBase()}/door/scan` },
    });
    setSending(false);

    if (error) {
      toast({ title: 'Could not send link', description: error.message, variant: 'destructive' });
      return;
    }
    setLinkSent(true);
  };

  return (
    <div className="flex min-h-screen items-center justify-center bg-black px-4">
      <div className="w-full max-w-sm rounded-2xl border border-gray-800 bg-gray-900/50 p-8 text-center">
        <h1 className="mb-6 text-2xl font-bold text-white">Door Staff Sign In</h1>

        {linkSent ? (
          <p className="text-gray-300">
            Check <span className="font-semibold text-white">{email}</span> for a sign-in link.
          </p>
        ) : (
          <form onSubmit={handleSubmit} className="space-y-4 text-left">
            <div className="space-y-2">
              <Label htmlFor="email" className="text-gray-300">Email</Label>
              <Input
                id="email"
                type="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                required
                autoComplete="email"
              />
            </div>
            <Button
              type="submit"
              disabled={sending}
              className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
            >
              {sending ? 'Sending...' : 'Send me a link'}
            </Button>
          </form>
        )}
      </div>
    </div>
  );
};

export default DoorLogin;
