import { useCallback, useEffect, useRef, useState } from 'react';
import { AccountError } from '@/lib/account';

/** Loads something on mount (and when `key` changes) and lets the editor reload it after a change. */
export function useLoad<T>(load: () => Promise<T>, key: string) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const loadRef = useRef(load);
  loadRef.current = load;

  const reload = useCallback(async () => {
    try {
      setData(await loadRef.current());
      setError(null);
    } catch (err) {
      setError(err instanceof AccountError ? err.message : 'This could not be loaded. Try again.');
    }
  }, []);

  useEffect(() => {
    setData(null);
    void reload();
  }, [key, reload]);

  return { data, error, reload };
}

/** The sentence to show for a failed save or delete: the database's own plain wording when there is one. */
export function errorMessage(err: unknown): string {
  return err instanceof AccountError || err instanceof Error ? err.message : 'Please try again.';
}
