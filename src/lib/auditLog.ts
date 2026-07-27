import { supabase } from '@/lib/supabase';

export async function logAudit(entry: {
  action: string;
  entityType: string;
  entityId?: string | null;
  details?: Record<string, unknown>;
}) {
  const { data } = await supabase.auth.getSession();
  const user = data.session?.user;

  const { error } = await supabase.from('audit_log').insert({
    actor_id: user?.id ?? null,
    actor_email: user?.email ?? 'unknown',
    action: entry.action,
    entity_type: entry.entityType,
    entity_id: entry.entityId ?? null,
    details: entry.details ?? null,
  });

  if (error) console.error('audit log insert failed:', error);
}
