import { useState } from 'react';
import { Loader2, Mail, Lock, User, Eye, EyeOff } from 'lucide-react';
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs';
import { useToast } from '@/hooks/use-toast';
import { userSignIn, userSignUp, userSignInWithMagicLink } from '@/hooks/useUserAuth';
import { getAuthRedirectBase } from '@/lib/authRedirect';

interface Props {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  defaultTab?: 'signin' | 'signup';
}

export default function UserAuthModal({ open, onOpenChange, defaultTab = 'signin' }: Props) {
  const { toast } = useToast();
  const [tab, setTab] = useState<string>(defaultTab);
  const [loading, setLoading] = useState(false);
  const [showPassword, setShowPassword] = useState(false);
  const [magicLinkSent, setMagicLinkSent] = useState(false);

  // Sign in fields
  const [siEmail, setSiEmail] = useState('');
  const [siPassword, setSiPassword] = useState('');

  // Sign up fields
  const [suName, setSuName] = useState('');
  const [suEmail, setSuEmail] = useState('');
  const [suPassword, setSuPassword] = useState('');
  const [suConfirm, setSuConfirm] = useState('');

  // Magic link field
  const [mlEmail, setMlEmail] = useState('');

  const reset = () => {
    setLoading(false);
    setMagicLinkSent(false);
    setSiEmail(''); setSiPassword('');
    setSuName(''); setSuEmail(''); setSuPassword(''); setSuConfirm('');
    setMlEmail('');
  };

  const handleSignIn = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    try {
      await userSignIn(siEmail, siPassword);
      toast({ title: 'Welcome back!' });
      reset();
      onOpenChange(false);
    } catch (err: unknown) {
      toast({ title: 'Sign in failed', description: (err as Error).message, variant: 'destructive' });
    } finally {
      setLoading(false);
    }
  };

  const handleSignUp = async (e: React.FormEvent) => {
    e.preventDefault();
    if (suPassword !== suConfirm) {
      toast({ title: 'Passwords do not match', variant: 'destructive' });
      return;
    }
    if (suPassword.length < 6) {
      toast({ title: 'Password must be at least 6 characters', variant: 'destructive' });
      return;
    }
    setLoading(true);
    try {
      await userSignUp(suName.trim(), suEmail, suPassword);
      toast({ title: 'Account created!', description: 'Check your email to confirm your account, then sign in.' });
      reset();
      setTab('signin');
    } catch (err: unknown) {
      toast({ title: 'Sign up failed', description: (err as Error).message, variant: 'destructive' });
    } finally {
      setLoading(false);
    }
  };

  const handleMagicLink = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    try {
      await userSignInWithMagicLink(mlEmail, `${getAuthRedirectBase()}/dashboard`);
      setMagicLinkSent(true);
    } catch (err: unknown) {
      toast({ title: 'Could not send link', description: (err as Error).message, variant: 'destructive' });
    } finally {
      setLoading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={(v) => { if (!v) reset(); onOpenChange(v); }}>
      <DialogContent className="sm:max-w-md bg-zinc-950 border-white/10 text-white">
        <DialogHeader>
          <DialogTitle className="text-xl font-bold text-white">Your BottlesUp Account</DialogTitle>
        </DialogHeader>

        <Tabs value={tab} onValueChange={setTab} className="mt-2">
          <TabsList className="w-full bg-zinc-900 border border-white/10">
            <TabsTrigger value="signin" className="flex-1 data-[state=active]:bg-orange-500 data-[state=active]:text-black font-medium">
              Sign In
            </TabsTrigger>
            <TabsTrigger value="signup" className="flex-1 data-[state=active]:bg-orange-500 data-[state=active]:text-black font-medium">
              Sign Up
            </TabsTrigger>
            <TabsTrigger value="magic" className="flex-1 data-[state=active]:bg-orange-500 data-[state=active]:text-black font-medium">
              Magic Link
            </TabsTrigger>
          </TabsList>

          {/* SIGN IN */}
          <TabsContent value="signin" className="mt-4">
            <form onSubmit={handleSignIn} className="space-y-4">
              <div className="space-y-1.5">
                <Label className="text-gray-300">Email</Label>
                <div className="relative">
                  <Mail className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-gray-500" />
                  <Input
                    type="email"
                    value={siEmail}
                    onChange={(e) => setSiEmail(e.target.value)}
                    className="pl-9 bg-zinc-900 border-white/10 text-white placeholder:text-gray-600"
                    placeholder="you@example.com"
                    required
                  />
                </div>
              </div>
              <div className="space-y-1.5">
                <Label className="text-gray-300">Password</Label>
                <div className="relative">
                  <Lock className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-gray-500" />
                  <Input
                    type={showPassword ? 'text' : 'password'}
                    value={siPassword}
                    onChange={(e) => setSiPassword(e.target.value)}
                    className="pl-9 pr-10 bg-zinc-900 border-white/10 text-white placeholder:text-gray-600"
                    placeholder="••••••••"
                    required
                  />
                  <button
                    type="button"
                    onClick={() => setShowPassword((v) => !v)}
                    className="absolute right-3 top-1/2 -translate-y-1/2 text-gray-500 hover:text-gray-300"
                  >
                    {showPassword ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                  </button>
                </div>
              </div>
              <Button
                type="submit"
                disabled={loading}
                className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
              >
                {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Sign In'}
              </Button>
              <p className="text-center text-sm text-gray-500">
                No password?{' '}
                <button type="button" onClick={() => setTab('magic')} className="text-orange-500 hover:underline">
                  Use magic link instead
                </button>
              </p>
            </form>
          </TabsContent>

          {/* SIGN UP */}
          <TabsContent value="signup" className="mt-4">
            <form onSubmit={handleSignUp} className="space-y-4">
              <div className="space-y-1.5">
                <Label className="text-gray-300">Full Name</Label>
                <div className="relative">
                  <User className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-gray-500" />
                  <Input
                    type="text"
                    value={suName}
                    onChange={(e) => setSuName(e.target.value)}
                    className="pl-9 bg-zinc-900 border-white/10 text-white placeholder:text-gray-600"
                    placeholder="John Smith"
                    required
                  />
                </div>
              </div>
              <div className="space-y-1.5">
                <Label className="text-gray-300">Email</Label>
                <div className="relative">
                  <Mail className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-gray-500" />
                  <Input
                    type="email"
                    value={suEmail}
                    onChange={(e) => setSuEmail(e.target.value)}
                    className="pl-9 bg-zinc-900 border-white/10 text-white placeholder:text-gray-600"
                    placeholder="you@example.com"
                    required
                  />
                </div>
              </div>
              <div className="space-y-1.5">
                <Label className="text-gray-300">Password</Label>
                <div className="relative">
                  <Lock className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-gray-500" />
                  <Input
                    type={showPassword ? 'text' : 'password'}
                    value={suPassword}
                    onChange={(e) => setSuPassword(e.target.value)}
                    className="pl-9 pr-10 bg-zinc-900 border-white/10 text-white placeholder:text-gray-600"
                    placeholder="Min. 6 characters"
                    required
                  />
                  <button
                    type="button"
                    onClick={() => setShowPassword((v) => !v)}
                    className="absolute right-3 top-1/2 -translate-y-1/2 text-gray-500 hover:text-gray-300"
                  >
                    {showPassword ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                  </button>
                </div>
              </div>
              <div className="space-y-1.5">
                <Label className="text-gray-300">Confirm Password</Label>
                <div className="relative">
                  <Lock className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-gray-500" />
                  <Input
                    type={showPassword ? 'text' : 'password'}
                    value={suConfirm}
                    onChange={(e) => setSuConfirm(e.target.value)}
                    className="pl-9 bg-zinc-900 border-white/10 text-white placeholder:text-gray-600"
                    placeholder="••••••••"
                    required
                  />
                </div>
              </div>
              <Button
                type="submit"
                disabled={loading}
                className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
              >
                {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Create Account'}
              </Button>
              <p className="text-xs text-center text-gray-500">
                Same account works on the BottlesUp mobile app
              </p>
            </form>
          </TabsContent>

          {/* MAGIC LINK */}
          <TabsContent value="magic" className="mt-4">
            {magicLinkSent ? (
              <div className="text-center py-4 space-y-3">
                <Mail className="mx-auto h-10 w-10 text-orange-500" />
                <p className="text-white font-medium">Check your inbox</p>
                <p className="text-gray-400 text-sm">
                  We sent a sign-in link to <span className="text-white font-medium">{mlEmail}</span>. Click it to access your account.
                </p>
                <Button variant="ghost" className="text-gray-400 hover:text-white text-sm" onClick={() => setMagicLinkSent(false)}>
                  Try a different email
                </Button>
              </div>
            ) : (
              <form onSubmit={handleMagicLink} className="space-y-4">
                <p className="text-sm text-gray-400">
                  Enter your email and we'll send you a one-click sign-in link — no password needed.
                </p>
                <div className="space-y-1.5">
                  <Label className="text-gray-300">Email</Label>
                  <div className="relative">
                    <Mail className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-gray-500" />
                    <Input
                      type="email"
                      value={mlEmail}
                      onChange={(e) => setMlEmail(e.target.value)}
                      className="pl-9 bg-zinc-900 border-white/10 text-white placeholder:text-gray-600"
                      placeholder="you@example.com"
                      required
                    />
                  </div>
                </div>
                <Button
                  type="submit"
                  disabled={loading}
                  className="w-full bg-gradient-orange text-black font-bold hover:opacity-90"
                >
                  {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Send Magic Link'}
                </Button>
              </form>
            )}
          </TabsContent>
        </Tabs>
      </DialogContent>
    </Dialog>
  );
}
