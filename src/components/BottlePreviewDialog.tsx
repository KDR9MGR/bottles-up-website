import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Wine } from 'lucide-react';

export interface PreviewBottle {
  name: string;
  size?: string | null;
  category?: string | null;
  description?: string | null;
  price_cents: number;
  image_url?: string | null;
}

interface BottlePreviewDialogProps {
  bottle: PreviewBottle | null;
  onOpenChange: (open: boolean) => void;
  // Some venues turn photos off entirely (site_venues.show_bottle_images) -
  // the preview still works without one, just falls back to the same Wine
  // icon used inline on the picker rows.
  showImage?: boolean;
}

const money = (cents: number) => `$${(cents / 100).toFixed(2)}`;

// A bigger look at a bottle before committing to a quantity - reused across
// every "pick bottles" surface (table booking, order-more-by-code, staff/CMS
// add-bottles) since they all render the same site_bottles row shape today,
// just with inconsistent amounts of it (some drop the photo, none show
// category, only one shows description). Read-only by design: quantity stays
// owned by whichever picker list opened this, so there's no second qty state
// to keep in sync.
const BottlePreviewDialog = ({ bottle, onOpenChange, showImage = true }: BottlePreviewDialogProps) => (
  <Dialog open={!!bottle} onOpenChange={onOpenChange}>
    <DialogContent className="border-gray-800 bg-gray-950 sm:max-w-sm">
      {bottle && (
        <>
          <DialogHeader>
            <DialogTitle className="text-white">{bottle.name}</DialogTitle>
          </DialogHeader>
          {showImage && bottle.image_url ? (
            <img src={bottle.image_url} alt={bottle.name} className="aspect-square w-full rounded-lg object-cover" />
          ) : (
            <div className="flex aspect-square w-full items-center justify-center rounded-lg bg-gray-900 text-gray-600">
              <Wine className="h-12 w-12" />
            </div>
          )}
          <div className="space-y-1 text-sm">
            {(bottle.size || bottle.category) && (
              <div className="flex flex-wrap gap-x-2 text-gray-400">
                {bottle.size && <span>{bottle.size}</span>}
                {bottle.category && <span>{bottle.size ? `· ${bottle.category}` : bottle.category}</span>}
              </div>
            )}
            {bottle.description && <p className="text-gray-300">{bottle.description}</p>}
            <p className="pt-1 text-lg font-semibold text-white">{money(bottle.price_cents)}</p>
          </div>
        </>
      )}
    </DialogContent>
  </Dialog>
);

export default BottlePreviewDialog;
