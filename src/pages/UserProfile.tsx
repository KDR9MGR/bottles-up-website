import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Loader2, User, Mail, Phone, Hash, Lock, LogOut, Trash2, ChevronRight, Save } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Separator } from '@/components/ui/separator';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import { useUserAuth, userSignOut } from '@/hooks/useUserAuth';
import UserAuthModal from '@/components/UserAuthModal';
import Header from '@/components/Header';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog';
import { Dialog, DialogContent, DialogHeader, DialogTitle } from '@/components/ui/dialog';

function SectionRow({
  icon: Icon,
  label,
  value,
  onClick,
}: {
  icon: typeof User;
  label: string;
  value: string;
  onClick?: () => void;
}) {
  return (
    <button
      onClick={onClick}
      disabled={!onClick}
      className="flex items-center gap-4 w-full py-3 text-left hover:bg-white/3 disabled:cursor-default transition-colors rounded-lg px-2 -mx-2 group"
    >
      <div className="h-9 w-9 flex items-center justify-center rounded-lg bg-zinc-800">
        <Icon className="h-4 w-4 text-gray-400" />
      </div>
      <div className="flex-1 min-w-0">
        <p className="text-xs text-gray-500 mb-0.5">{label}</p>
        <p className="text-white text-sm truncate">{value || '—'}</p>
      </div>
      {onClick && <ChevronRight className="h-4 w-4 text-gray-600 group-hover:text-gray-400 transition-colors" />}
    </button>
  );
}

export default function UserProfile() {
  const navigate = useNavigate();
  const { toast } = useToast();
  const { session, profile, loading, refreshProfile } = useUserAuth();
  const [authOpen, setAuthOpen] = useState(false);

  // Edit profile dialog
  const [editOpen, setEditOpen] = useState(false);
  const [editName, setEditName] = useState('');
  const [editPhone, setEditPhone] = useState('');
  const [editAge, setEditAge] = useState('');
  const [saving, setSaving] = useState(false);

  // Change password dialog
  const [pwOpen, setPwOpen] = useState(false);
  const [newPw, setNewPw] = useState('');
  const [confirmPw, setConfirmPw] = useState('');
  const [savingPw, setSavingPw] = useState(false);

  const openEdit = () => {
    setEditName(profile?.name ?? '');
    setEditPhone(profile?.phone_number ?? '');
    setEditAge(profile?.age?.toString() ?? '');
    setEditOpen(true);
  };

  const handleSaveProfile = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!session) return;
    setSaving(true);
    const { error } = await supabase
      .from('profiles')
      .update({
        name: editName.trim(),
        phone_number: editPhone.trim() || null,
        age: editAge ? parseInt(editAge) : null,
        updated_at: new Date().toISOString(),
      })
      .eq('id', session.user.id);

    setSaving(false);
    if (error) {
      toast({ title: 'Update failed', description: error.message, variant: 'destructive' });
    } else {
      toast({ title: 'Profile updated' });
      await refreshProfile();
      setEditOpen(false);
    }
  };

  const handleChangePassword = async (e: React.FormEvent) => {
    e.preventDefault();
    if (newPw !== confirmPw) {
      toast({ title: 'Passwords do not match', variant: 'destructive' });
      return;
    }
    if (newPw.length < 6) {
      toast({ title: 'Password must be at least 6 characters', variant: 'destructive' });
      return;
    }
    setSavingPw(true);
    const { error } = await supabase.auth.updateUser({ password: newPw });
    setSavingPw(false);
    if (error) {
      toast({ title: 'Failed to update password', description: error.message, variant: 'destructive' });
    } else {
      toast({ title: 'Password updated' });
      setNewPw(''); setConfirmPw('');
      setPwOpen(false);
    }
  };

  const handleSignOut = async () => {
    await userSignOut();
    navigate('/');
  };

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
          <User className="mb-4 h-12 w-12 text-orange-500" />
          <h1 className="mb-2 text-2xl font-bold text-white">Account</h1>
          <p className="mb-8 max-w-sm text-gray-400">Sign in to manage your profile and preferences.</p>
          <Button onClick={() => setAuthOpen(true)} className="bg-gradient-orange text-black font-bold hover:opacity-90 px-8">
            Sign In
          </Button>
        </div>
        <UserAuthModal open={authOpen} onOpenChange={setAuthOpen} />
      </>
    );
  }

  const initials = (profile?.name ?? session.user.email ?? '?')
    .split(' ')
    .map((w) => w[0])
    .join('')
    .toUpperCase()
    .slice(0, 2);

  const memberSince = new Date(session.user.created_at).toLocaleDateString('en-US', {
    month: 'long',
    year: 'numeric',
  });

  return (
    <>
      <Header />
      <div className="min-h-screen bg-black pt-24 pb-16 px-4">
        <div className="mx-auto max-w-lg">

          {/* Avatar & name */}
          <div className="flex flex-col items-center mb-8">
            <div className="h-20 w-20 rounded-full bg-gradient-to-br from-orange-500 to-orange-600 flex items-center justify-center text-black text-2xl font-bold mb-3">
              {initials}
            </div>
            <h1 className="text-xl font-bold text-white">{profile?.name ?? 'Your Account'}</h1>
            <p className="text-sm text-gray-400">Member since {memberSince}</p>
          </div>

          {/* Account section */}
          <div className="rounded-2xl border border-white/10 bg-zinc-900 p-5 mb-4">
            <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-500 mb-3">Account</h2>
            <SectionRow icon={User}  label="Full Name"  value={profile?.name ?? ''} onClick={openEdit} />
            <SectionRow icon={Mail}  label="Email"      value={session.user.email ?? ''} />
            <SectionRow icon={Phone} label="Phone"      value={profile?.phone_number ?? ''} onClick={openEdit} />
            <SectionRow icon={Hash}  label="Age"        value={profile?.age?.toString() ?? ''} onClick={openEdit} />
            <Button
              variant="ghost"
              size="sm"
              className="mt-2 text-orange-500 hover:text-orange-400 hover:bg-orange-500/10 w-full"
              onClick={openEdit}
            >
              Edit Profile
            </Button>
          </div>

          {/* Security */}
          <div className="rounded-2xl border border-white/10 bg-zinc-900 p-5 mb-4">
            <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-500 mb-3">Security</h2>
            <button
              onClick={() => setPwOpen(true)}
              className="flex items-center gap-4 w-full py-3 hover:bg-white/3 transition-colors rounded-lg px-2 -mx-2 group"
            >
              <div className="h-9 w-9 flex items-center justify-center rounded-lg bg-zinc-800">
                <Lock className="h-4 w-4 text-gray-400" />
              </div>
              <div className="flex-1 text-left">
                <p className="text-white text-sm">Change Password</p>
              </div>
              <ChevronRight className="h-4 w-4 text-gray-600 group-hover:text-gray-400 transition-colors" />
            </button>
          </div>

          {/* Actions */}
          <div className="rounded-2xl border border-white/10 bg-zinc-900 p-5 space-y-2">
            <Button
              variant="ghost"
              className="w-full justify-start gap-3 text-white hover:bg-white/5"
              onClick={() => navigate('/dashboard')}
            >
              My Bookings
            </Button>
            <Button
              variant="ghost"
              className="w-full justify-start gap-3 text-white hover:bg-white/5"
              onClick={() => navigate('/my-tickets')}
            >
              Event Tickets
            </Button>
            <Separator className="bg-white/5" />
            <Button
              variant="ghost"
              className="w-full justify-start gap-3 text-red-500 hover:bg-red-500/10 hover:text-red-400"
              onClick={handleSignOut}
            >
              <LogOut className="h-4 w-4" />
              Sign Out
            </Button>
            <AlertDialog>
              <AlertDialogTrigger asChild>
                <Button
                  variant="ghost"
                  className="w-full justify-start gap-3 text-red-700 hover:bg-red-500/10 hover:text-red-500"
                >
                  <Trash2 className="h-4 w-4" />
                  Delete Account
                </Button>
              </AlertDialogTrigger>
              <AlertDialogContent className="bg-zinc-950 border-white/10 text-white">
                <AlertDialogHeader>
                  <AlertDialogTitle>Delete account?</AlertDialogTitle>
                  <AlertDialogDescription className="text-gray-400">
                    This will permanently delete your account and all your booking history. This cannot be undone.
                  </AlertDialogDescription>
                </AlertDialogHeader>
                <AlertDialogFooter>
                  <AlertDialogCancel className="border-white/10 text-white hover:bg-white/5">Cancel</AlertDialogCancel>
                  <AlertDialogAction
                    className="bg-red-600 hover:bg-red-700 text-white"
                    onClick={async () => {
                      await userSignOut();
                      navigate('/');
                    }}
                  >
                    Delete
                  </AlertDialogAction>
                </AlertDialogFooter>
              </AlertDialogContent>
            </AlertDialog>
          </div>
        </div>
      </div>

      {/* Edit Profile Dialog */}
      <Dialog open={editOpen} onOpenChange={setEditOpen}>
        <DialogContent className="sm:max-w-md bg-zinc-950 border-white/10 text-white">
          <DialogHeader>
            <DialogTitle>Edit Profile</DialogTitle>
          </DialogHeader>
          <form onSubmit={handleSaveProfile} className="space-y-4 mt-2">
            <div className="space-y-1.5">
              <Label className="text-gray-300">Full Name</Label>
              <Input
                value={editName}
                onChange={(e) => setEditName(e.target.value)}
                className="bg-zinc-900 border-white/10 text-white"
                placeholder="Your name"
                required
              />
            </div>
            <div className="space-y-1.5">
              <Label className="text-gray-300">Phone Number</Label>
              <Input
                value={editPhone}
                onChange={(e) => setEditPhone(e.target.value)}
                className="bg-zinc-900 border-white/10 text-white"
                placeholder="+1 (555) 000-0000"
                type="tel"
              />
            </div>
            <div className="space-y-1.5">
              <Label className="text-gray-300">Age</Label>
              <Input
                value={editAge}
                onChange={(e) => setEditAge(e.target.value)}
                className="bg-zinc-900 border-white/10 text-white"
                placeholder="e.g. 25"
                type="number"
                min={18}
                max={99}
              />
            </div>
            <div className="flex gap-3 pt-2">
              <Button type="button" variant="outline" className="flex-1 border-white/10 text-white hover:bg-white/5" onClick={() => setEditOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" disabled={saving} className="flex-1 bg-gradient-orange text-black font-bold hover:opacity-90">
                {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : <><Save className="mr-2 h-4 w-4" />Save</>}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>

      {/* Change Password Dialog */}
      <Dialog open={pwOpen} onOpenChange={setPwOpen}>
        <DialogContent className="sm:max-w-md bg-zinc-950 border-white/10 text-white">
          <DialogHeader>
            <DialogTitle>Change Password</DialogTitle>
          </DialogHeader>
          <form onSubmit={handleChangePassword} className="space-y-4 mt-2">
            <div className="space-y-1.5">
              <Label className="text-gray-300">New Password</Label>
              <Input
                type="password"
                value={newPw}
                onChange={(e) => setNewPw(e.target.value)}
                className="bg-zinc-900 border-white/10 text-white"
                placeholder="Min. 6 characters"
                required
              />
            </div>
            <div className="space-y-1.5">
              <Label className="text-gray-300">Confirm New Password</Label>
              <Input
                type="password"
                value={confirmPw}
                onChange={(e) => setConfirmPw(e.target.value)}
                className="bg-zinc-900 border-white/10 text-white"
                placeholder="••••••••"
                required
              />
            </div>
            <div className="flex gap-3 pt-2">
              <Button type="button" variant="outline" className="flex-1 border-white/10 text-white hover:bg-white/5" onClick={() => setPwOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" disabled={savingPw} className="flex-1 bg-gradient-orange text-black font-bold hover:opacity-90">
                {savingPw ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Update Password'}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>
    </>
  );
}
