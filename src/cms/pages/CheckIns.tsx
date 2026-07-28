import { useEffect, useMemo, useState } from 'react';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { supabase } from '@/lib/supabase';
import type { ScanResult } from '@/types/database';

type CheckInRow = {
  id: string;
  ticket_code: string | null;
  customer_name: string;
  quantity: number;
  checked_in_at: string;
  checked_in_by: string | null;
  site_ticket_tiers: { name: string } | null;
  site_events: { title: string } | null;
};

type ScanIssueRow = {
  id: string;
  ticket_code_attempted: string;
  result: ScanResult;
  scanned_by: string;
  created_at: string;
};

const issueLabel: Record<Exclude<ScanResult, 'ok'>, string> = {
  already_checked_in: 'Already checked in',
  not_paid: 'Not paid',
  not_found: 'Not found',
  expired: 'Event ended',
};

const CmsCheckIns = () => {
  const [rows, setRows] = useState<CheckInRow[]>([]);
  const [issues, setIssues] = useState<ScanIssueRow[]>([]);
  const [staffMap, setStaffMap] = useState<Record<string, string>>({});
  const [eventFilter, setEventFilter] = useState('all');
  const [loading, setLoading] = useState(true);

  const loadData = async () => {
    setLoading(true);
    const [{ data: checkins }, { data: scanIssues }, { data: doorStaff }, { data: admins }] = await Promise.all([
      supabase
        .from('site_orders')
        .select(
          'id, ticket_code, customer_name, quantity, checked_in_at, checked_in_by, site_ticket_tiers(name), site_events(title)',
        )
        .not('checked_in_at', 'is', null)
        .order('checked_in_at', { ascending: false }),
      supabase
        .from('scan_attempts')
        .select('id, ticket_code_attempted, result, scanned_by, created_at')
        .neq('result', 'ok')
        .order('created_at', { ascending: false })
        .limit(50),
      supabase.from('door_staff').select('id, email'),
      supabase.from('cms_admins').select('id, email'),
    ]);

    const map: Record<string, string> = {};
    (doorStaff ?? []).forEach((s) => {
      map[s.id] = s.email;
    });
    (admins ?? []).forEach((a) => {
      map[a.id] = a.email;
    });

    setStaffMap(map);
    setRows((checkins as unknown as CheckInRow[]) ?? []);
    setIssues((scanIssues as ScanIssueRow[]) ?? []);
    setLoading(false);
  };

  useEffect(() => {
    loadData();
  }, []);

  const eventTitles = useMemo(
    () => Array.from(new Set(rows.map((r) => r.site_events?.title).filter((t): t is string => !!t))),
    [rows],
  );

  const filtered = useMemo(
    () => (eventFilter === 'all' ? rows : rows.filter((r) => r.site_events?.title === eventFilter)),
    [rows, eventFilter],
  );

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-2xl font-bold text-white">Check-ins ({rows.length})</h1>
        <Select value={eventFilter} onValueChange={setEventFilter}>
          <SelectTrigger className="w-56">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">All events</SelectItem>
            {eventTitles.map((title) => (
              <SelectItem key={title} value={title}>
                {title}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      {loading ? (
        <div className="text-gray-400">Loading...</div>
      ) : (
        <div className="rounded-lg border border-gray-800">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Ticket Code</TableHead>
                <TableHead>Event</TableHead>
                <TableHead>Tier</TableHead>
                <TableHead>Customer</TableHead>
                <TableHead>Qty</TableHead>
                <TableHead>Checked in at</TableHead>
                <TableHead>Checked in by</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {filtered.map((row) => (
                <TableRow key={row.id}>
                  <TableCell className="font-mono text-xs">{row.ticket_code ?? '-'}</TableCell>
                  <TableCell>{row.site_events?.title ?? '-'}</TableCell>
                  <TableCell>{row.site_ticket_tiers?.name ?? '-'}</TableCell>
                  <TableCell>{row.customer_name}</TableCell>
                  <TableCell>{row.quantity}</TableCell>
                  <TableCell>{new Date(row.checked_in_at).toLocaleString()}</TableCell>
                  <TableCell>{row.checked_in_by ? (staffMap[row.checked_in_by] ?? 'Unknown') : '-'}</TableCell>
                </TableRow>
              ))}
              {filtered.length === 0 && (
                <TableRow>
                  <TableCell colSpan={7} className="text-center text-gray-500">
                    No check-ins yet.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </div>
      )}

      <h2 className="mb-3 mt-10 text-lg font-semibold text-white">Recent Scan Issues</h2>
      <p className="mb-4 text-sm text-gray-500">
        Duplicate, invalid, or unpaid ticket codes scanned at the door - not customer-facing errors, just a log for
        spotting fraud attempts or scanner mistakes.
      </p>
      {!loading && (
        <div className="rounded-lg border border-gray-800">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Ticket Code</TableHead>
                <TableHead>Result</TableHead>
                <TableHead>Scanned by</TableHead>
                <TableHead>When</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {issues.map((issue) => (
                <TableRow key={issue.id}>
                  <TableCell className="font-mono text-xs">{issue.ticket_code_attempted}</TableCell>
                  <TableCell>{issueLabel[issue.result as Exclude<ScanResult, 'ok'>]}</TableCell>
                  <TableCell>{staffMap[issue.scanned_by] ?? 'Unknown'}</TableCell>
                  <TableCell>{new Date(issue.created_at).toLocaleString()}</TableCell>
                </TableRow>
              ))}
              {issues.length === 0 && (
                <TableRow>
                  <TableCell colSpan={4} className="text-center text-gray-500">
                    No scan issues logged.
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

export default CmsCheckIns;
