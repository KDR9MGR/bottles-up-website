import { useState } from 'react';
import { Link, Navigate } from 'react-router-dom';
import { ArrowLeft } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { usePartnerAuth } from '../usePartnerAuth';

const PartnerLogin = () => {
  const { session, loading } = usePartnerAuth();
  const { toast } = useToast();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [submitting, setSubmitting] = useState(false);

  if (!loading && session) {
    return <Navigate to="/partners/onboarding" replace />;
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSubmitting(true);
    try {
      const { error } = await supabase.auth.signInWithPassword({ email, password });
      if (error) throw error;
    } catch (error) {
      toast({
        title: 'Sign in failed',
        description: error instanceof Error ? error.message : 'Check your credentials and try again.',
        variant: 'destructive',
      });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-black px-4">
      <Link to="/" className="mb-6 inline-flex items-center gap-2 text-sm text-gray-400 transition-colors hover:text-primary">
        <ArrowLeft className="h-4 w-4" />
        Back to website
      </Link>
      <div className="w-full max-w-sm rounded-2xl border border-gray-800 bg-gray-900/50 p-8">
        <h1 className="mb-6 text-2xl font-bold text-white">Partner Sign In</h1>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="email" className="text-gray-300">Email</Label>
            <Input id="email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} required autoComplete="email" />
          </div>
          <div className="space-y-2">
            <Label htmlFor="password" className="text-gray-300">Password</Label>
            <Input
              id="password"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
              autoComplete="current-password"
            />
          </div>
          <Button
            type="submit"
            disabled={submitting}
            className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
          >
            {submitting ? 'Signing in...' : 'Sign In'}
          </Button>
        </form>
        <p className="mt-4 text-center text-xs text-gray-500">
          Haven't applied yet?{' '}
          <Link to="/partners/apply" className="text-primary hover:underline">
            Apply here
          </Link>
        </p>
      </div>
    </div>
  );
};

export default PartnerLogin;
