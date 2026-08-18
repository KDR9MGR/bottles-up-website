import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { Plus, Pencil, Trash2 } from 'lucide-react';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/lib/supabase';
import type { Database } from '@/types/database';
import PromoCodeFormDialog from '../components/PromoCodeFormDialog';

type PromoCodeRow = Database['public']['Tables']['promo_codes']['Row'];
type PromoCodeWithVenues = PromoCodeRow & { promo_code_venues: { venue_id: string; site_venues: { name: string } | null }[] };

const formatDiscount = (row: PromoCodeRow) =>
  row.discount_type === 'percentage' ? `${row.discount_value}% off` : `$${(row.discount_value / 100).toFixed(2)} off`;

const appliesToLabel: Record<string, string> = {
  both: 'Tickets & Tables',
  tickets: 'Tickets only',
  tables: 'Tables only',
};

const statusFor = (row: PromoCodeRow): { label: string; variant: 'default' | 'secondary' | 'destructive' } => {
  if (!row.is_active) return { label: 'Inactive', variant: 'secondary' };
  if (row.expires_at && new Date(row.expires_at) < new Date()) return { label: 'Expired', variant: 'destructive' };
  if (row.max_uses !== null && row.used_count >= row.max_uses) return { label: 'Limit reached', variant: 'destructive' };
  return { label: 'Active', variant: 'default' };
};

const CmsPromoCodes = () => {
  const { toast } = useToast();
  const [promoCodes, setPromoCodes] = useState<PromoCodeWithVenues[]>([]);
  const [loading, setLoading] = useState(true);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingPromoCode, setEditingPromoCode] = useState<PromoCodeRow | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<PromoCodeRow | null>(null);

  const loadPromoCodes = async () => {
    setLoading(true);
    const { data } = await supabase
      .from('promo_codes')
      .select('*, promo_code_venues(venue_id, site_venues(name))')
      .order('created_at', { ascending: false });
    setPromoCodes((data as PromoCodeWithVenues[]) ?? []);
    setLoading(false);
  };

  useEffect(() => {
    loadPromoCodes();
  }, []);

  const handleDelete = async () => {
    if (!deleteTarget) return;
    const { error } = await supabase.from('promo_codes').delete().eq('id', deleteTarget.id);
    if (error) {
      toast({ title: 'Failed to delete promo code', description: error.message, variant: 'destructive' });
    } else {
      toast({ title: 'Promo code deleted' });
      loadPromoCodes();
    }
    setDeleteTarget(null);
  };

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">Promo Codes</h1>
          <p className="text-sm text-gray-500">Discount codes customers can apply at checkout for event tickets and VIP tables.</p>
        </div>
        <Button
          onClick={() => {
            setEditingPromoCode(null);
            setDialogOpen(true);
          }}
          className="bg-gradient-orange text-black font-bold hover:opacity-90"
        >
          <Plus className="mr-2 h-4 w-4" />
          New Promo Code
        </Button>
      </div>

      {loading ? (
        <div className="text-gray-400">Loading...</div>
      ) : (
        <div className="rounded-lg border border-gray-800">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Code</TableHead>
                <TableHead>Discount</TableHead>
                <TableHead>Applies To</TableHead>
                <TableHead>Venues</TableHead>
                <TableHead>Usage</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {promoCodes.map((promo) => {
                const status = statusFor(promo);
                const venueNames = promo.promo_code_venues.map((v) => v.site_venues?.name).filter(Boolean);
                return (
                  <TableRow key={promo.id}>
                    <TableCell className="font-mono font-semibold text-white">{promo.code}</TableCell>
                    <TableCell>{formatDiscount(promo)}</TableCell>
                    <TableCell>{appliesToLabel[promo.applies_to]}</TableCell>
                    <TableCell className="max-w-[200px] truncate">
                      {venueNames.length === 0 ? (
                        <span className="text-gray-500">All venues</span>
                      ) : (
                        venueNames.join(', ')
                      )}
                    </TableCell>
                    <TableCell>
                      {promo.used_count}
                      {promo.max_uses !== null ? ` / ${promo.max_uses}` : ''}
                    </TableCell>
                    <TableCell>
                      <Badge variant={status.variant}>{status.label}</Badge>
                    </TableCell>
                    <TableCell className="text-right">
                      <Button
                        size="icon"
                        variant="ghost"
                        onClick={() => {
                          setEditingPromoCode(promo);
                          setDialogOpen(true);
                        }}
                      >
                        <Pencil className="h-4 w-4" />
                      </Button>
                      <Button size="icon" variant="ghost" onClick={() => setDeleteTarget(promo)}>
                        <Trash2 className="h-4 w-4" />
                      </Button>
                    </TableCell>
                  </TableRow>
                );
              })}
              {promoCodes.length === 0 && (
                <TableRow>
                  <TableCell colSpan={7} className="text-center text-gray-500">
                    No promo codes yet.
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </div>
      )}

      <PromoCodeFormDialog
        promoCode={editingPromoCode}
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        onSaved={loadPromoCodes}
      />

      <AlertDialog open={!!deleteTarget} onOpenChange={(open) => !open && setDeleteTarget(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete "{deleteTarget?.code}"?</AlertDialogTitle>
            <AlertDialogDescription>
              Past orders that used this code keep their discount on record. This only stops the code from being
              applied to new checkouts. This cannot be undone.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={handleDelete}>Delete</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
};

export default CmsPromoCodes;
