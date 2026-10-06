import { useCallback, useEffect, useState } from 'react';
import { AccountError, doorEvents } from '@/lib/account';
import { defaultEvent, type DoorEvent } from '@/lib/doorScan';

// Door counts change as other people scan, so refresh them while the screen is open.
const REFRESH_MS = 30_000;

const storageKey = (membershipId: string) => `bu_door_event_${membershipId}`;

function readChoice(membershipId: string): string | null {
  try {
    return window.sessionStorage.getItem(storageKey(membershipId));
  } catch {
    return null;
  }
}

/**
 * The events one door workspace can work, which one is selected, and fresh guest counts. The selected event is
 * remembered for the session; it is only a convenience, since every scan is checked against the database again.
 */
export function useDoorEvents(membershipId: string) {
  const [loading, setLoading] = useState(true);
  const [events, setEvents] = useState<DoorEvent[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [choice, setChoice] = useState<string | null>(() => readChoice(membershipId));

  const refresh = useCallback(async () => {
    try {
      setEvents(await doorEvents(membershipId));
      setError(null);
    } catch (err) {
      setError(err instanceof AccountError ? err.message : 'Could not load your events.');
    } finally {
      setLoading(false);
    }
  }, [membershipId]);

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => { if (document.visibilityState === 'visible') void refresh(); }, REFRESH_MS);
    return () => window.clearInterval(timer);
  }, [refresh]);

  const selected = events.find((e) => e.eventId === choice) ?? defaultEvent(events);

  const select = useCallback((eventId: string) => {
    setChoice(eventId);
    try {
      window.sessionStorage.setItem(storageKey(membershipId), eventId);
    } catch {
      /* storage blocked: the choice lasts until the page reloads */
    }
  }, [membershipId]);

  return { loading, events, selected, error, select, refresh };
}
