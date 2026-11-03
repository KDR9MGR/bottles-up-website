import { describe, expect, it, vi } from 'vitest';
import {
  LIST_PAGE, MAX_PER_RUN, REMOVE_BATCH, chunk, removeFolder, removePaths, removeProfileFolders, type StorageLike,
} from '../../supabase/functions/_shared/socialMedia.ts';

/** A bucket held in memory: folders of files, listed a page at a time, removed by full path. */
function bucket(files: string[], over: { removeFails?: (paths: string[]) => boolean; listFails?: boolean } = {}) {
  const present = new Set(files);
  const removed: string[][] = [];
  const storage: StorageLike = {
    list: vi.fn(async (folder: string, options: { limit: number; offset?: number }) => {
      if (over.listFails) return { data: null, error: { message: 'down' } };
      const names = [...present].filter((f) => f.startsWith(`${folder}/`)).map((f) => f.slice(folder.length + 1)).slice(options.offset ?? 0, (options.offset ?? 0) + options.limit);
      return { data: names.map((name) => ({ name })), error: null };
    }),
    remove: vi.fn(async (paths: string[]) => {
      if (over.removeFails?.(paths)) return { error: { message: 'refused' } };
      removed.push(paths);
      for (const p of paths) present.delete(p);
      return { error: null };
    }),
  };
  return { storage, present, removed };
}

describe('chunk', () => {
  it('cuts a list into pieces of at most the size', () => {
    expect(chunk([1, 2, 3, 4, 5], 2)).toEqual([[1, 2], [3, 4], [5]]);
    expect(chunk([], 3)).toEqual([]);
    expect(chunk([1, 2], 5)).toEqual([[1, 2]]);
  });
});

describe('removing named files', () => {
  it('removes them a batch at a time and counts them', async () => {
    const names = Array.from({ length: REMOVE_BATCH * 2 + 5 }, (_, i) => `a/${i}.jpg`);
    const { storage, removed } = bucket(names);
    expect(await removePaths(storage, names)).toBe(names.length);
    expect(removed.map((b) => b.length)).toEqual([REMOVE_BATCH, REMOVE_BATCH, 5]);
  });

  it('a batch the storage refuses is left, not counted, and the others still go', async () => {
    const names = Array.from({ length: REMOVE_BATCH + 3 }, (_, i) => `a/${i}.jpg`);
    const { storage, present } = bucket(names, { removeFails: (paths) => paths[0] === 'a/0.jpg' });
    expect(await removePaths(storage, names)).toBe(3);
    expect(present.size).toBe(REMOVE_BATCH);
  });

  it('nothing to remove is nothing asked', async () => {
    const { storage } = bucket([]);
    expect(await removePaths(storage, [])).toBe(0);
    expect(storage.remove).not.toHaveBeenCalled();
  });
});

describe('emptying a folder', () => {
  it('removes every file in it, however many pages, and nothing outside it', async () => {
    const mine = Array.from({ length: LIST_PAGE * 2 + 7 }, (_, i) => `p1/${i}.jpg`);
    const { storage, present } = bucket([...mine, 'p2/keep.jpg', 'p10/keep.jpg']);
    expect(await removeFolder(storage, 'p1')).toBe(mine.length);
    expect([...present].sort()).toEqual(['p10/keep.jpg', 'p2/keep.jpg']);
  });

  it('an empty or missing folder is zero', async () => {
    const { storage } = bucket(['p2/x.jpg']);
    expect(await removeFolder(storage, 'p1')).toBe(0);
  });

  it('stops when listing or removing fails, instead of looping', async () => {
    const down = bucket(['p1/a.jpg'], { listFails: true });
    expect(await removeFolder(down.storage, 'p1')).toBe(0);
    const refused = bucket(['p1/a.jpg', 'p1/b.jpg'], { removeFails: () => true });
    expect(await removeFolder(refused.storage, 'p1')).toBe(0);
    expect(refused.storage.remove).toHaveBeenCalledTimes(1);
  });

  it('takes no more than a run is allowed to', async () => {
    const many = Array.from({ length: LIST_PAGE * 3 }, (_, i) => `p1/${i}.jpg`);
    const { storage, present } = bucket(many);
    expect(await removeFolder(storage, 'p1', LIST_PAGE * 2)).toBe(LIST_PAGE * 2);
    expect(present.size).toBe(LIST_PAGE);
    expect(MAX_PER_RUN).toBeGreaterThanOrEqual(LIST_PAGE);
  });
});

describe('the folders of a person\'s profiles', () => {
  it('empties each, and leaves other people\'s', async () => {
    const { storage, present } = bucket(['pa/1.jpg', 'pa/2.mp4', 'pb/1.jpg', 'other/1.jpg']);
    expect(await removeProfileFolders(storage, ['pa', 'pb'])).toEqual({ removed: 3, failed: 0 });
    expect([...present]).toEqual(['other/1.jpg']);
  });

  it('a folder that throws is counted as failed and the next one still goes', async () => {
    const { storage, present } = bucket(['pb/1.jpg']);
    const list = storage.list as ReturnType<typeof vi.fn>;
    const real = list.getMockImplementation()!;
    list.mockImplementation(async (folder: string, o: { limit: number }) => {
      if (folder === 'pa') throw new Error('boom');
      return real(folder, o);
    });
    expect(await removeProfileFolders(storage, ['pa', 'pb'])).toEqual({ removed: 1, failed: 1 });
    expect(present.size).toBe(0);
  });

  it('no profiles is nothing to do', async () => {
    const { storage } = bucket(['pa/1.jpg']);
    expect(await removeProfileFolders(storage, [])).toEqual({ removed: 0, failed: 0 });
  });
});
