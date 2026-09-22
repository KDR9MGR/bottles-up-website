import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/button';
import { getMyProfile, STAFF_ROLE_LABELS, type MyProfile } from '@/lib/staffDashboard';
import { doorSignOut } from '../../door/useDoorAuth';

const Profile = () => {
  const [profile, setProfile] = useState<MyProfile | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    getMyProfile().then(setProfile).finally(() => setLoading(false));
  }, []);

  return (
    <div className="mx-auto max-w-sm px-4 py-6">
      <h1 className="mb-4 text-xl font-bold text-white">Profile</h1>

      {loading ? (
        <div className="text-center text-gray-400">Loading...</div>
      ) : !profile ? (
        <div className="text-center text-gray-500">Could not load your profile.</div>
      ) : (
        <div className="space-y-3 rounded-lg border border-gray-800 p-4 text-sm">
          <div>
            <div className="text-xs text-gray-500">Name</div>
            <div className="text-white">{profile.name ?? '-'}</div>
          </div>
          <div>
            <div className="text-xs text-gray-500">Email</div>
            <div className="text-white">{profile.email}</div>
          </div>
          <div>
            <div className="text-xs text-gray-500">Role</div>
            <div className="text-white">{STAFF_ROLE_LABELS[profile.role]}</div>
          </div>
          <div>
            <div className="text-xs text-gray-500">Event</div>
            <div className="text-white">{profile.eventTitle ?? 'Not assigned to a specific event'}</div>
          </div>
          <div>
            <div className="text-xs text-gray-500">Assigned tables / section</div>
            <div className="text-white">{profile.assignedTables ?? '-'}</div>
          </div>
          <div>
            <div className="text-xs text-gray-500">Access window</div>
            <div className="text-white">
              {profile.accessStartAt || profile.accessEndAt
                ? `${profile.accessStartAt ? new Date(profile.accessStartAt).toLocaleString() : 'now'} - ${profile.accessEndAt ? new Date(profile.accessEndAt).toLocaleString() : 'open'}`
                : 'Always'}
            </div>
          </div>
          <div>
            <div className="text-xs text-gray-500">Can record club payments</div>
            <div className={profile.canRecordPayments ? 'text-green-400' : 'text-gray-400'}>
              {profile.canRecordPayments ? 'Yes' : 'No'}
            </div>
          </div>
        </div>
      )}

      <Button variant="outline" className="mt-6 w-full border-gray-700 text-gray-300" onClick={() => doorSignOut()}>
        Sign out
      </Button>
    </div>
  );
};

export default Profile;
