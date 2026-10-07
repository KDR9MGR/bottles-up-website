// The password rule the partner sign-up already enforces, shared so personal and business
// sign-up cannot drift apart. Returns a sentence for the person, or null when the password is fine.
export function passwordProblem(password: string): string | null {
  if (password.length < 8 || !/[A-Z]/.test(password) || !/[0-9]/.test(password) || !/[^A-Za-z0-9]/.test(password)) {
    return 'Use at least 8 characters, including one uppercase letter, one number, and one symbol.';
  }
  return null;
}

export const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function isValidEmail(email: string): boolean {
  return EMAIL_PATTERN.test(email.trim());
}
