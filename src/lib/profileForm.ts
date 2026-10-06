// Username rules for the profile form. The database enforces the same rule (and uniqueness); this
// only gives the person immediate feedback before anything is sent.

export const USERNAME_HELP = '3 to 30 characters: lowercase letters, numbers, dots and underscores.';

export function normalizeUsername(raw: string): string {
  return raw.trim().toLowerCase();
}

const RESERVED = ['admin', 'administrator', 'support', 'help', 'staff', 'bottlesup', 'official', 'root', 'system', 'moderator'];

/** A sentence describing what is wrong with the username's shape, or null if it is acceptable. */
export function validateUsernameShape(username: string): string | null {
  if (username.length < 3) return 'Usernames need at least 3 characters.';
  if (username.length > 30) return 'Usernames can be at most 30 characters.';
  if (!/^[a-z0-9._]+$/.test(username)) return 'Use only lowercase letters, numbers, dots and underscores.';
  if (RESERVED.includes(username)) return 'That username is reserved.';
  return null;
}
