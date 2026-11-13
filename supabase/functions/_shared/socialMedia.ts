// Removing files from the private `social-media` bucket. The database cannot delete a file (deleting a row of storage.objects would leave the file behind), so two places do it
// through the storage API: delete-account (everything in the folders of the profiles of the person leaving) and sweep-social-media (files no post uses). Both are best effort and
// say how many went; the sweep is the safety net for anything the first one missed.

/** The part of the storage client these helpers use. */
export interface StorageLike {
  list(path: string, options: { limit: number; offset?: number }): Promise<{ data: { name: string }[] | null; error: unknown }>;
  remove(paths: string[]): Promise<{ data?: unknown; error: unknown }>;
}

export const REMOVE_BATCH = 100;
export const LIST_PAGE = 100;
/** The most files taken out of one folder, or in one sweep, in one run: a runaway folder is finished by the next run, not by one very long one. */
export const MAX_PER_RUN = 2000;

export function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

/** Removes these full paths, a batch at a time. Answers how many were removed; a batch the storage refuses is left (and not counted). */
export async function removePaths(storage: StorageLike, paths: string[]): Promise<number> {
  let removed = 0;
  for (const batch of chunk(paths, REMOVE_BATCH)) {
    const { error } = await storage.remove(batch);
    if (!error) removed += batch.length;
  }
  return removed;
}

/** Removes every file directly inside a folder (its pages are listed again from the start after each removal, so nothing is skipped). */
export async function removeFolder(storage: StorageLike, folder: string, max = MAX_PER_RUN): Promise<number> {
  let removed = 0;
  while (removed < max) {
    const { data, error } = await storage.list(folder, { limit: LIST_PAGE });
    if (error || !data || data.length === 0) break;
    const batch = data.map((f) => `${folder}/${f.name}`);
    const { error: removeError } = await storage.remove(batch);
    if (removeError) break;
    removed += batch.length;
  }
  return removed;
}

/** The folders of these profiles. A folder that cannot be emptied is counted as failed and the others carry on. */
export async function removeProfileFolders(storage: StorageLike, profileIds: string[]): Promise<{ removed: number; failed: number }> {
  let removed = 0;
  let failed = 0;
  for (const id of profileIds) {
    try {
      removed += await removeFolder(storage, id);
    } catch {
      failed++;
    }
  }
  return { removed, failed };
}
