import { useEffect, useState } from 'react';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';

type AuditLogRow = Database['public']['Tables']['audit_log']['Row'];

const CmsAuditLog = () => {
  const [rows, setRows] = useState<AuditLogRow[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    supabase
      .from('audit_log')
      .select('*')
      .order('created_at', { ascending: false })
      .limit(200)
      .then(({ data }) => {
        setRows(data ?? []);
        setLoading(false);
      });
  }, []);

  return (
    <div>
      <h1 className="mb-2 text-2xl font-bold text-white">Audit Log ({rows.length})</h1>
      <p className="mb-6 max-w-xl text-sm text-gray-400">
        Every event edit, door-staff change, ticket resend, and site content update - who did it and when.
      </p>

      {loading ? (
        <div className="text-gray-400">Loading...</div>
      ) : (
        <div className="rounded-lg border border-gray-800">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Action</TableHead>
                <TableHead>Entity</TableHead>
                <TableHead>Actor</TableHead>
                <TableHead>Details</TableHead>
                <TableHead>When</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id}>
                  <TableCell>{row.action}</TableCell>
                  <TableCell>
                    {row.entity_type}
                    {row.entity_id ? ` (${row.entity_id.slice(0, 8)})` : ''}
                  </TableCell>
                  <TableCell>{row.actor_email}</TableCell>
                  <TableCell className="max-w-xs truncate text-xs text-gray-400">
                    {row.details ? JSON.stringify(row.details) : '-'}
                  </TableCell>
                  <TableCell>{new Date(row.created_at).toLocaleString()}</TableCell>
                </TableRow>
              ))}
              {rows.length === 0 && (
                <TableRow>
                  <TableCell colSpan={5} className="text-center text-gray-500">
                    No audit entries yet.
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

export default CmsAuditLog;
