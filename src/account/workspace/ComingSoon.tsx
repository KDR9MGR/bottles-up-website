import { Hourglass } from 'lucide-react';

/** A section that is part of the plan but not built on the website yet. Says so rather than faking a screen. */
const ComingSoon = ({ title, description }: { title: string; description: string }) => (
  <div className="rounded-2xl border border-dashed border-gray-800 bg-gray-900/30 p-8 text-center">
    <Hourglass className="mx-auto mb-3 h-8 w-8 text-gray-500" />
    <h2 className="text-lg font-semibold text-white">{title}</h2>
    {description && <p className="mx-auto mt-2 max-w-md text-sm text-gray-400">{description}</p>}
    <p className="mt-4 text-xs uppercase tracking-wide text-gray-500">Not available on the website yet</p>
  </div>
);

export default ComingSoon;
