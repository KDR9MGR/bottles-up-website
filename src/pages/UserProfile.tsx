import { useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { format, parseISO } from 'date-fns';
import {
  Loader2, User, Mail, Phone, Hash, Lock, LogOut, Trash2, ChevronRight,
  Save, Camera, BadgeCheck, Ticket, TableIcon, Download, Mailbox, ShieldCheck, Clock,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Badge } from '@/components/ui/badge';
import { Separator } from '@/components/ui/separator';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import {
  useUserAuth, userSignOut, userSignOutEverywhere, userChangeEmail,
  userUploadAvatar, userDeleteAccount, userExportData,
} from '@/hooks/useUserAuth';
import { useUserBookings } from '@/hooks/useUserBookings';
import { formatMoney, statusBadgeClass } from '@/lib/bookingFormat';
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
  const { bookings, loading: loadingBookings } = useUserBookings(session);
  const [authOpen, setAuthOpen] = useState(false);
  const avatarInputRef = useRef<HTMLInputElement>(null);
  const [uploadingAvatar, setUploadingAvatar] = useState(false);

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

  // Change email dialog
  const [emailOpen, setEmailOpen] = useState(false);
  const [newEmail, setNewEmail] = useState('');
  const [savingEmail, setSavingEmail] = useState(false);

  const [deleting, setDeleting] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [signingOutEverywhere, setSigningOutEverywhere] = useState(false);

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

  const handleAvatarClick = () => avatarInputRef.current?.click();

  const handleAvatarChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file || !session) return;
    if (file.size > 5 * 1024 * 1024) {
      toast({ title: 'Image too large', description: 'Please choose a photo under 5MB.', variant: 'destructive' });
      return;
    }
    setUploadingAvatar(true);
    try {
      await userUploadAvatar(session.user.id, file);
      await refreshProfile();
      toast({ title: 'Photo updated' });
    } catch (err: unknown) {
      toast({ title: 'Upload failed', description: (err as Error).message, variant: 'destructive' });
    } finally {
      setUploadingAvatar(false);
      if (avatarInputRef.current) avatarInputRef.current.value = '';
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

  const handleChangeEmail = async (e: React.FormEvent) => {
    e.preventDefault();
    setSavingEmail(true);
    try {
      await userChangeEmail(newEmail.trim());
      toast({ title: 'Check your new inbox', description: 'Click the confirmation link to finish changing your email.' });
      setEmailOpen(false);
      setNewEmail('');
    } catch (err: unknown) {
      toast({ title: 'Could not change email', description: (err as Error).message, variant: 'destructive' });
    } finally {
      setSavingEmail(false);
    }
  };

  const handleSignOut = async () => {
    await userSignOut();
    navigate('/');
  };

  const handleSignOutEverywhere = async () => {
    setSigningOutEverywhere(true);
    try {
      await userSignOutEverywhere();
      navigate('/');
    } catch (err: unknown) {
      toast({ title: 'Could not sign out everywhere', description: (err as Error).message, variant: 'destructive' });
      setSigningOutEverywhere(false);
    }
  };

  const handleExportData = async () => {
    if (!session) return;
    setExporting(true);
    try {
      const data = await userExportData(session.user.id);
      const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `bottlesup-my-data-${session.user.id.slice(0, 8)}.json`;
      a.click();
      URL.revokeObjectURL(url);
    } catch (err: unknown) {
      toast({ title: 'Export failed', description: (err as Error).message, variant: 'destructive' });
    } finally {
      setExporting(false);
    }
  };

  const handleDeleteAccount = async () => {
    setDeleting(true);
    try {
      await userDeleteAccount();
      navigate('/');
    } catch (err: unknown) {
      toast({ title: 'Could not delete account', description: (err as Error).message, variant: 'destructive' });
      setDeleting(false);
    }
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

  const lastSignIn = session.user.last_sign_in_at
    ? format(parseISO(session.user.last_sign_in_at), "MMM d, yyyy 'at' h:mm a")
    : null;

  const totalBookings = bookings.filter((b) => b.status === 'paid').length;
  const upcomingCount = bookings.filter(
    (b) => b.status === 'paid' && b.date && new Date(b.date) > new Date(),
  ).length;

  return (
    <>
      <Header />
      <div className="min-h-screen bg-black pt-24 pb-16 px-4">
        <div className="mx-auto max-w-lg">

          {/* Avatar & name */}
          <div className="flex flex-col items-center mb-8">
            <div className="relative">
              <button
                onClick={handleAvatarClick}
                disabled={uploadingAvatar}
                className="h-20 w-20 rounded-full bg-gradient-to-br from-orange-500 to-orange-600 flex items-center justify-center text-black text-2xl font-bold overflow-hidden relative group"
              >
                {profile?.avatar_url ? (
                  <img src={profile.avatar_url} alt="" className="h-full w-full object-cover" />
                ) : (
                  initials
                )}
                <div className="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
                  {uploadingAvatar ? (
                    <Loader2 className="h-5 w-5 text-white animate-spin" />
                  ) : (
                    <Camera className="h-5 w-5 text-white" />
                  )}
                </div>
              </button>
              <input
                ref={avatarInputRef}
                type="file"
                accept="image/*"
                className="hidden"
                onChange={handleAvatarChange}
              />
            </div>
            <div className="flex items-center gap-1.5 mt-3">
              <h1 className="text-xl font-bold text-white">{profile?.name ?? 'Your Account'}</h1>
              {profile?.verified && <BadgeCheck className="h-5 w-5 text-orange-500" />}
            </div>
            <p className="text-sm text-gray-400">Member since {memberSince}</p>
          </div>

          {/* Quick stats */}
          <div className="grid grid-cols-2 gap-3 mb-6">
            <div className="rounded-xl border border-white/10 bg-zinc-900 p-4 text-center">
              <p className="text-2xl font-bold text-white">{loadingBookings ? '—' : totalBookings}</p>
              <p className="text-xs text-gray-500 mt-0.5">Total Bookings</p>
            </div>
            <div className="rounded-xl border border-white/10 bg-zinc-900 p-4 text-center">
              <p className="text-2xl font-bold text-orange-500">{loadingBookings ? '—' : upcomingCount}</p>
              <p className="text-xs text-gray-500 mt-0.5">Upcoming</p>
            </div>
          </div>

          {/* Account section */}
          <div className="rounded-2xl border border-white/10 bg-zinc-900 p-5 mb-4">
            <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-500 mb-3">Account</h2>
            <SectionRow icon={User}  label="Full Name"  value={profile?.name ?? ''} onClick={openEdit} />
            <SectionRow
              icon={Mail}
              label="Email"
              value={session.user.email ?? ''}
              onClick={() => { setNewEmail(session.user.email ?? ''); setEmailOpen(true); }}
            />
            <SectionRow icon={Phone} label="Phone"      value={profile?.phone_number ?? ''} onClick={openEdit} />
            <SectionRow icon={Hash}  label="Age"        value={profile?.age?.toString() ?? ''} onClick={openEdit} />
            {lastSignIn && (
              <div className="flex items-center gap-4 w-full py-3">
                <div className="h-9 w-9 flex items-center justify-center rounded-lg bg-zinc-800">
                  <Clock className="h-4 w-4 text-gray-400" />
                </div>
                <div className="flex-1 min-w-0">
                  <p className="text-xs text-gray-500 mb-0.5">Last Signed In</p>
                  <p className="text-white text-sm truncate">{lastSignIn}</p>
                </div>
                <Badge variant="outline" className="border-green-500/30 bg-green-500/20 text-green-400 text-xs">
                  Active
                </Badge>
              </div>
            )}
            <Button
              variant="ghost"
              size="sm"
              className="mt-2 text-orange-500 hover:text-orange-400 hover:bg-orange-500/10 w-full"
              onClick={openEdit}
            >
              Edit Profile
            </Button>
          </div>

          {/* Billing history */}
          <div className="rounded-2xl border border-white/10 bg-zinc-900 p-5 mb-4">
            <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-500 mb-3">Billing History</h2>
            {loadingBookings ? (
              <div className="flex justify-center py-6">
                <Loader2 className="h-5 w-5 animate-spin text-orange-500" />
              </div>
            ) : bookings.length === 0 ? (
              <p className="text-sm text-gray-500 py-2">No transactions yet.</p>
            ) : (
              <div className="divide-y divide-white/5">
                {bookings.slice(0, 8).map((b) => (
                  <div key={`${b.type}-${b.id}`} className="flex items-center gap-3 py-2.5">
                    <div className="h-8 w-8 shrink-0 flex items-center justify-center rounded-lg bg-orange-500/10">
                      {b.type === 'table' ? (
                        <TableIcon className="h-3.5 w-3.5 text-orange-500" />
                      ) : (
                        <Ticket className="h-3.5 w-3.5 text-orange-500" />
                      )}
                    </div>
                    <div className="flex-1 min-w-0">
                      <p className="text-sm text-white truncate">{b.title}</p>
                      <p className="text-xs text-gray-500">
                        {(() => { try { return format(parseISO(b.createdAt), 'MMM d, yyyy'); } catch { return ''; } })()}
                      </p>
                    </div>
                    <div className="text-right shrink-0">
                      <p className="text-sm font-medium text-white">{formatMoney(b.amountCents, b.currency)}</p>
                      <Badge
                        variant="outline"
                        className={`mt-0.5 text-[10px] capitalize ${statusBadgeClass[b.status] ?? 'border-white/20 text-gray-400'}`}
                      >
                        {b.status}
                      </Badge>
                    </div>
                  </div>
                ))}
              </div>
            )}
            <Button
              variant="ghost"
              size="sm"
              className="mt-2 text-orange-500 hover:text-orange-400 hover:bg-orange-500/10 w-full"
              onClick={() => navigate('/dashboard')}
            >
              View All Bookings
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
            <button
              onClick={handleSignOutEverywhere}
              disabled={signingOutEverywhere}
              className="flex items-center gap-4 w-full py-3 hover:bg-white/3 transition-colors rounded-lg px-2 -mx-2 group disabled:opacity-50"
            >
              <div className="h-9 w-9 flex items-center justify-center rounded-lg bg-zinc-800">
                {signingOutEverywhere ? (
                  <Loader2 className="h-4 w-4 text-gray-400 animate-spin" />
                ) : (
                  <ShieldCheck className="h-4 w-4 text-gray-400" />
                )}
              </div>
              <div className="flex-1 text-left">
                <p className="text-white text-sm">Sign Out of All Devices</p>
                <p className="text-xs text-gray-500">Revokes every active session, including this one</p>
              </div>
            </button>
          </div>

          {/* Support & Help */}
          <div className="rounded-2xl border border-white/10 bg-zinc-900 p-5 mb-4">
            <h2 className="text-xs font-semibold uppercase tracking-wider text-gray-500 mb-3">Support & Help</h2>
            <a
              href="mailto:bottlesupapp@gmail.com"
              className="flex items-center gap-4 w-full py-3 hover:bg-white/3 transition-colors rounded-lg px-2 -mx-2 group"
            >
              <div className="h-9 w-9 flex items-center justify-center rounded-lg bg-zinc-800">
                <Mailbox className="h-4 w-4 text-gray-400" />
              </div>
              <div className="flex-1 text-left">
                <p className="text-white text-sm">Contact Support</p>
                <p className="text-xs text-gray-500">bottlesupapp@gmail.com</p>
              </div>
              <ChevronRight className="h-4 w-4 text-gray-600 group-hover:text-gray-400 transition-colors" />
            </a>
            <button
              onClick={() => navigate('/privacy-policy')}
              className="flex items-center gap-4 w-full py-3 hover:bg-white/3 transition-colors rounded-lg px-2 -mx-2 group"
            >
              <div className="h-9 w-9 flex items-center justify-center rounded-lg bg-zinc-800">
                <ShieldCheck className="h-4 w-4 text-gray-400" />
              </div>
              <div className="flex-1 text-left">
                <p className="text-white text-sm">Privacy Policy</p>
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
              onClick={handleExportData}
              disabled={exporting}
            >
              {exporting ? <Loader2 className="h-4 w-4 animate-spin" /> : <Download className="h-4 w-4" />}
              Download My Data
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
                    This permanently deletes your login and profile. This cannot be undone. Your past order and
                    booking records are kept for receipts and venue check-in history, the same as any completed
                    purchase.
                  </AlertDialogDescription>
                </AlertDialogHeader>
                <AlertDialogFooter>
                  <AlertDialogCancel className="border-white/10 text-white hover:bg-white/5">Cancel</AlertDialogCancel>
                  <AlertDialogAction
                    className="bg-red-600 hover:bg-red-700 text-white"
                    disabled={deleting}
                    onClick={handleDeleteAccount}
                  >
                    {deleting ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Delete'}
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

      {/* Change Email Dialog */}
      <Dialog open={emailOpen} onOpenChange={setEmailOpen}>
        <DialogContent className="sm:max-w-md bg-zinc-950 border-white/10 text-white">
          <DialogHeader>
            <DialogTitle>Change Email</DialogTitle>
          </DialogHeader>
          <form onSubmit={handleChangeEmail} className="space-y-4 mt-2">
            <p className="text-sm text-gray-400">
              We'll send a confirmation link to the new address. Your email won't change until you click it.
            </p>
            <div className="space-y-1.5">
              <Label className="text-gray-300">New Email</Label>
              <Input
                type="email"
                value={newEmail}
                onChange={(e) => setNewEmail(e.target.value)}
                className="bg-zinc-900 border-white/10 text-white"
                required
              />
            </div>
            <div className="flex gap-3 pt-2">
              <Button type="button" variant="outline" className="flex-1 border-white/10 text-white hover:bg-white/5" onClick={() => setEmailOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" disabled={savingEmail} className="flex-1 bg-gradient-orange text-black font-bold hover:opacity-90">
                {savingEmail ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Send Confirmation'}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>
    </>
  );
}
