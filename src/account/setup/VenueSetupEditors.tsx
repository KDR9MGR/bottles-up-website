import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import BookingTimesEditor from './BookingTimesEditor';
import BottlesEditor from './BottlesEditor';
import FloorsEditor from './FloorsEditor';
import TableTypesEditor from './TableTypesEditor';

interface Props {
  orgId: string;
  venueId: string;
  /** Called after any change, so the venue's setup checklist can refresh. */
  onChanged: () => void;
}

/** The four setup editors of one venue, in the order of the checklist. */
const VenueSetupEditors = ({ orgId, venueId, onChanged }: Props) => (
  <section className="mt-5 border-t border-gray-800 pt-5" aria-label="Venue setup">
    <h4 className="mb-3 text-sm font-medium text-white">Set up what guests can book</h4>
    <Tabs defaultValue="floors">
      <TabsList className="flex h-auto w-full flex-wrap justify-start gap-1 bg-gray-900">
        <TabsTrigger value="floors">Floor plans</TabsTrigger>
        <TabsTrigger value="tables">Tables</TabsTrigger>
        <TabsTrigger value="bottles">Bottle menu</TabsTrigger>
        <TabsTrigger value="times">Booking times</TabsTrigger>
      </TabsList>
      <TabsContent value="floors" className="mt-5"><FloorsEditor orgId={orgId} venueId={venueId} onChanged={onChanged} /></TabsContent>
      <TabsContent value="tables" className="mt-5"><TableTypesEditor orgId={orgId} venueId={venueId} onChanged={onChanged} /></TabsContent>
      <TabsContent value="bottles" className="mt-5"><BottlesEditor orgId={orgId} venueId={venueId} onChanged={onChanged} /></TabsContent>
      <TabsContent value="times" className="mt-5"><BookingTimesEditor venueId={venueId} onChanged={onChanged} /></TabsContent>
    </Tabs>
  </section>
);

export default VenueSetupEditors;
