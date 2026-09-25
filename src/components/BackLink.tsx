import { Link } from 'react-router-dom';
import { ArrowLeft } from 'lucide-react';

// Same visual pattern already used ad hoc on EventDetail/VenueDetail/TableDetail/
// UserBookingDetail - pulled into one component so pages that are missing a way
// back (mostly deep-link/standalone pages with no shared Header) can get it
// without re-copying the same JSX a tenth time. Generous vertical padding
// (py-2, -my-2 to cancel the visual gap) keeps the tap target comfortable on
// mobile without changing how it reads on desktop.
const BackLink = ({ to, label }: { to: string; label: string }) => (
  <Link
    to={to}
    className="-my-2 inline-flex items-center gap-2 py-2 text-sm text-gray-300 transition-colors hover:text-primary"
  >
    <ArrowLeft className="h-4 w-4" />
    {label}
  </Link>
);

export default BackLink;
