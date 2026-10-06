import { stateInfo, type Tone, type VerificationState } from '@/lib/verification';

const TONE_CLASS: Record<Tone, string> = {
  neutral: 'border-gray-600 bg-gray-800 text-gray-200',
  info: 'border-blue-500/40 bg-blue-500/10 text-blue-300',
  warning: 'border-amber-500/40 bg-amber-500/10 text-amber-300',
  success: 'border-green-500/40 bg-green-500/10 text-green-300',
};

export const StateBadge = ({ state }: { state: VerificationState }) => {
  const info = stateInfo(state);
  return (
    <span className={`inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-medium ${TONE_CLASS[info.tone]}`}>
      {info.label}
    </span>
  );
};

export default StateBadge;
