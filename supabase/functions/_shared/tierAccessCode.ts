import { createClient } from 'npm:@supabase/supabase-js@2';
import bcrypt from 'npm:bcryptjs@2.4.3';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type SupabaseClient = ReturnType<typeof createClient<any>>;

// Single source of truth for "does this code unlock this gated tier" - used
// both by the public preview endpoint (validate-tier-access-code) and,
// re-run from scratch, at actual checkout-session creation. A client never
// gets to just claim it already validated a code.
export async function validateTierAccessCode(
  supabase: SupabaseClient,
  tierId: string,
  code: string | null | undefined,
): Promise<{ valid: boolean; message: string }> {
  if (!code || !code.trim()) {
    return { valid: false, message: 'Enter the access code' };
  }

  const { data: row } = await supabase
    .from('ticket_tier_access_codes')
    .select('code_hash')
    .eq('tier_id', tierId)
    .maybeSingle();

  if (!row) {
    return { valid: false, message: 'This ticket type has no access code configured' };
  }

  return bcrypt.compareSync(code.trim(), row.code_hash)
    ? { valid: true, message: 'Access code accepted' }
    : { valid: false, message: 'Incorrect access code' };
}
