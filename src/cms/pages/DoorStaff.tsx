import { useEffect, useState } from 'react';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { Trash2 } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';

type DoorStaffRow = Database['public']['Tables']['door_staff']['Row'];

const CmsDoorStaff = () => {
  const { toast } = useToast();
  const [staff, setStaff] = useState<DoorStaffRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [email, setEmail] = useState('');
  const [adding, setAdding] = useState(false);
  const [removingId, setRemovingId] = useState<string | null>(null);

  const loadStaff = async () => {
    setLoading(true);
    const { data } = await supabase.from('door_staff').select('*').order('created_at', { ascending: false });
    setStaff(data ?? []);
    setLoading(false);
  };

  useEffect(() => {
    loadStaff();
  }, []);

  const handleAdd = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!email.trim()) return;

    setAdding(true);
    const { data, error } = await supabase.functions.invoke('manage-door-staff', {
      body: { email: email.trim() },
    });
    setAdding(false);

    if (error || data?.error) {
      toast({
        title: 'Failed to add door staff',
        description: data?.error ?? error?.message,
        variant: 'destructive',
      });
      return;
    }

    toast({ title: 'Door staff added' });
    setEmail('');
    loadStaff();
  };

  const handleRemove = async (id: string) => {
    setRemovingId(id);
    const { error } = await supabase.from('door_staff').delete().eq('id', id);
    setRemovingId(null);

    if (error) {
      toast({ title: 'Failed to remove', description: error.message, variant: 'destructive' });
      return;
    }
    loadStaff();
  };

  return (
    <div>
      <h1 className="mb-2 text-2xl font-bold text-white">Door Staff ({staff.length})</h1>
      <p className="mb-6 max-w-xl text-sm text-gray-400">
        People who can sign in at <span className="font-mono">/door/login</span> to scan and check in tickets. They
        can only scan - they can't see or edit events, bookings, or site content.
      </p>

      <form onSubmit={handleAdd} className="mb-6 flex max-w-sm gap-2">
        <Input
          type="email"
          placeholder="staff@example.com"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          required
        />
        <Button type="submit" disabled={adding} className="bg-gradient-orange text-black font-bold hover:opacity-90">
          {adding ? 'Adding...' : 'Add'}
        </Button>
      </form>

      {loading ? (
        <div className="text-gray-400">Loading...</div>
      ) : (
        <div className="rounded-lg border border-gray-800">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Email</TableHead>
                <TableHead>Added</TableHead>
                <TableHead className="text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {staff.map((row) => (
                <TableRow key={row.id}>
                  <TableCell>{row.email}</TableCell>
                  <TableCell>{new Date(row.created_at).toLocaleDateString()}</TableCell>
                  <TableCell className="text-right">
                    <Button
                      size="sm"
                      variant="ghost"
                      disabled={removingId === row.id}
                      onClick={() => handleRemove(row.id)}
                    >
                      <Trash2 className="mr-1 h-3 w-3" />
                      Remove
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
              {staff.length === 0 && (
                <TableRow>
                  <TableCell colSpan={3} className="text-center text-gray-500">
                    No door staff yet.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  );
};

export default CmsDoorStaff;
