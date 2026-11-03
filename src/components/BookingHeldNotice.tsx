import { Link } from 'react-router-dom';
import { Button } from '@/components/ui/button';

// Shown instead of the confirmation when the guest has paid but their table went to someone else while they were paying. The club's manager has been told and will get in
// touch to move the booking to another table or pay it back. It never shows a booking code or a QR: nothing here promises a table.
const BookingHeldNotice = ({ email }: { email?: string }) => (
  <div className="flex min-h-screen flex-col items-center justify-center bg-black px-4 text-center" data-testid="booking-held">
    <h1 className="mb-4 text-3xl font-bold text-white">Payment received, but we need to check your table</h1>
    <p className="mb-4 max-w-md text-gray-300">
      The table you chose was taken by another guest while you were paying, so we cannot confirm it yet. The club has been told. They will contact you
      {email ? ` at ${email}` : ''} to offer another table, or to pay your payment back in full.
    </p>
    <p className="mb-8 max-w-md text-gray-400">You do not need to pay again, and please do not travel to the venue until you have heard from them.</p>
    <Button asChild className="bg-gradient-orange text-black font-bold hover:opacity-90">
      <Link to="/">Back to BottlesUp</Link>
    </Button>
  </div>
);

export default BookingHeldNotice;
