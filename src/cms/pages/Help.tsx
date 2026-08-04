import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from '@/components/ui/accordion';
import { AlertTriangle } from 'lucide-react';

const Steps = ({ items }: { items: string[] }) => (
  <ol className="list-decimal space-y-2 pl-5 text-sm text-gray-300">
    {items.map((step, i) => (
      <li key={i}>{step}</li>
    ))}
  </ol>
);

const CmsHelp = () => {
  return (
    <div className="max-w-3xl space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-white">Help &amp; Guides</h1>
        <p className="mt-1 text-sm text-gray-400">Step-by-step walkthroughs for the most common CMS tasks.</p>
      </div>

      <Accordion type="multiple" defaultValue={['venue']} className="space-y-3">
        <AccordionItem value="venue" className="rounded-lg border border-gray-800 px-4">
          <AccordionTrigger className="text-white">Creating a Venue</AccordionTrigger>
          <AccordionContent className="space-y-4">
            <div className="flex gap-2 rounded-lg border border-amber-900/50 bg-amber-950/30 p-3 text-sm text-amber-300">
              <AlertTriangle className="h-4 w-4 shrink-0 mt-0.5" />
              <span>
                A venue can only be set to <strong>Published</strong> once it has at least one complete table type
                (name, max guests, and # available all filled in). If Save doesn't seem to do anything, this is
                almost always why - check for an error message at the top-right of the screen, or set the venue to
                <strong> Draft</strong> first and publish once tables are added.
              </span>
            </div>
            <Steps
              items={[
                'Go to Venues → New Venue.',
                'Fill in Name, Description, Address, and upload a Cover Image.',
                'Add Gallery photos (optional).',
                'Add at least one Time Slot (day of week + arrival time) - without one, tables show as "Coming Soon" and can\'t be booked.',
                'Add at least one Table Type: name, max guests, min spend, deposit (or switch to Hourly pricing), and # of tables available.',
                'Optional: use "Place on floor plan" per table type for the interactive cinema-style picker - see the Floor Plan guide below.',
                'Optional: set a Booking Window if the venue should only take bookings within a specific date range.',
                'Set Status to Published once ready, then Save Venue.',
              ]}
            />
          </AccordionContent>
        </AccordionItem>

        <AccordionItem value="floorplan" className="rounded-lg border border-gray-800 px-4">
          <AccordionTrigger className="text-white">Setting up an Interactive Floor Plan (VIP Tables)</AccordionTrigger>
          <AccordionContent className="space-y-4">
            <Steps
              items={[
                'In the venue form, scroll to the Floors section and click Add Floor.',
                'Give it a label (e.g. "Downstairs") and upload the venue\'s real floor plan image.',
                'Repeat for each level/section the venue has.',
                'For each Table Type you want on the interactive map, click "Place on floor plan".',
                'Pick the floor, then drag the orange box onto the table\'s real position in the image and drag its corner handle to resize.',
                'Click Save Placement. Repeat for every table you want customers to click directly on the floor plan.',
                'A table type left un-placed still works - it just shows as a plain card instead of a map hotspot.',
                'Tip: if the floor plan image is very tall, the placement window scrolls - the Save Placement button is always at the bottom.',
              ]}
            />
          </AccordionContent>
        </AccordionItem>

        <AccordionItem value="event" className="rounded-lg border border-gray-800 px-4">
          <AccordionTrigger className="text-white">Creating an Event</AccordionTrigger>
          <AccordionContent className="space-y-4">
            <Steps
              items={[
                'Go to Events → New Event.',
                'Fill in Title, Description, Venue Name, Address, and Start Date/Time.',
                'Upload a Cover Image (used on cards) and a Banner Image (used on the event page).',
                'Add Gallery photos (optional).',
                'Add a Category (used for filter pills on the public Events page - comma-separate multiple tags).',
                'Add at least one Ticket Tier: name, price, and capacity - without one, tickets show as "Coming Soon".',
                'Set Status to Published, then Save.',
              ]}
            />
          </AccordionContent>
        </AccordionItem>
      </Accordion>
    </div>
  );
};

export default CmsHelp;
