import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { ArrowLeft } from 'lucide-react';

interface Props {
  title: string;
  subtitle?: ReactNode;
  children: ReactNode;
  /** Wider card for forms with several columns. */
  wide?: boolean;
  /** Where the "back" link goes. Defaults to the public site. */
  backTo?: string;
  backLabel?: string;
}

/** The centred dark card every account page sits in, matching the partner pages. */
const AccountShell = ({ title, subtitle, children, wide = false, backTo = '/', backLabel = 'Back to website' }: Props) => (
  <div className="flex min-h-screen flex-col items-center bg-black px-4 py-10 sm:py-14">
    <Link to={backTo} className="mb-6 inline-flex items-center gap-2 text-sm text-gray-400 transition-colors hover:text-primary">
      <ArrowLeft className="h-4 w-4" />
      {backLabel}
    </Link>
    <div className={`w-full ${wide ? 'max-w-2xl' : 'max-w-md'} rounded-2xl border border-gray-800 bg-gray-900/50 p-6 sm:p-8`}>
      <h1 className="mb-1 text-2xl font-bold text-white">{title}</h1>
      {subtitle && <div className="mb-6 text-sm text-gray-400">{subtitle}</div>}
      {!subtitle && <div className="mb-6" />}
      {children}
    </div>
  </div>
);

export default AccountShell;
