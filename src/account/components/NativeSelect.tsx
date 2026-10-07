import { forwardRef, type SelectHTMLAttributes } from 'react';

const CLASS =
  'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-base ring-offset-background ' +
  'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 ' +
  'disabled:cursor-not-allowed disabled:opacity-50 md:text-sm';

/** A plain browser select styled like the other inputs: reliable on phones and with screen readers. */
const NativeSelect = forwardRef<HTMLSelectElement, SelectHTMLAttributes<HTMLSelectElement>>(({ className = '', ...props }, ref) => (
  <select ref={ref} className={`${CLASS} ${className}`} {...props} />
));
NativeSelect.displayName = 'NativeSelect';

export default NativeSelect;
