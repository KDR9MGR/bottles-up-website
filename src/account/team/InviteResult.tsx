import { useRef, useState } from 'react';
import { Check, Copy, Mail, X } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { emailOutcomeMessage, mailtoLink, type EmailOutcome } from '@/lib/team';

export interface IssuedInvite {
  email: string;
  roleLabel: string;
  businessName: string;
  link: string;
  outcome: EmailOutcome;
}

/**
 * Shown right after an invitation or a new link is created. The link is displayed here and nowhere else: the
 * database keeps only a hash of it, so once this closes it cannot be shown again (send a new link instead).
 */
const InviteResult = ({ invite, onClose }: { invite: IssuedInvite; onClose: () => void }) => {
  const message = emailOutcomeMessage(invite.outcome, invite.email);
  const input = useRef<HTMLInputElement>(null);
  const [copied, setCopied] = useState(false);

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(invite.link);
    } catch {
      // Clipboard blocked (older browser, insecure page): select the text so Ctrl/Cmd+C works.
      input.current?.select();
      return;
    }
    setCopied(true);
    window.setTimeout(() => setCopied(false), 2000);
  };

  return (
    <section aria-label="Invitation link" className="mb-6 rounded-xl border border-gray-800 bg-gray-900/60 p-4 sm:p-5">
      <div className="flex items-start justify-between gap-3">
        <p className={`text-sm font-medium ${message.tone === 'success' ? 'text-green-300' : 'text-amber-300'}`}>{message.text}</p>
        <button type="button" onClick={onClose} aria-label="Close" className="rounded-full p-1 text-gray-500 hover:bg-white/10 hover:text-white">
          <X className="h-4 w-4" />
        </button>
      </div>
      <div className="mt-3 flex gap-2">
        <Input ref={input} readOnly value={invite.link} aria-label="Invitation link" onFocus={(e) => e.currentTarget.select()} />
        <Button type="button" variant="outline" onClick={() => void copy()} className="shrink-0 border-gray-700 text-white hover:bg-gray-900">
          {copied ? <Check className="mr-2 h-4 w-4 text-green-400" /> : <Copy className="mr-2 h-4 w-4" />}
          {copied ? 'Copied' : 'Copy'}
        </Button>
      </div>
      <p className="mt-2 text-xs text-gray-500">
        This link is personal to {invite.email} and is shown only now. If you lose it, send a new link from the list.
      </p>
      {!invite.outcome.sent && (
        <a
          href={mailtoLink(invite.email, invite.businessName, invite.roleLabel, invite.link)}
          className="mt-3 inline-flex items-center gap-2 text-sm font-medium text-primary hover:underline"
        >
          <Mail className="h-4 w-4" /> Open in your email app
        </a>
      )}
    </section>
  );
};

export default InviteResult;
