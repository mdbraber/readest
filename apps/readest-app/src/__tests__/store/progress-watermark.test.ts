import { describe, expect, test } from 'vitest';
import {
  markProgressAdoption,
  resolveProgressUpdatedAt,
  seedPersistedProgress,
} from '@/store/progressWatermark';
import type { BookConfig } from '@/types/book';

// Each test uses its own book id: the watermark state is module-level.
let n = 0;
const nextId = () => `book-${++n}`;

const at = (location: string, progressUpdatedAt?: number): Partial<BookConfig> => ({
  location,
  progress: [1, 10],
  ...(progressUpdatedAt !== undefined ? { progressUpdatedAt } : {}),
});

describe('reading-position watermark (progressUpdatedAt)', () => {
  test('re-saving the position loaded from disk keeps its time', () => {
    const id = nextId();
    seedPersistedProgress(id, at('A', 100));
    expect(resolveProgressUpdatedAt(id, at('A', 100), 5000)).toBe(100);
  });

  test('a real move is stamped with the save time', () => {
    const id = nextId();
    seedPersistedProgress(id, at('A', 100));
    expect(resolveProgressUpdatedAt(id, at('B', 100), 5000)).toBe(5000);
    // …and the new position becomes the baseline.
    expect(resolveProgressUpdatedAt(id, at('B', 5000), 6000)).toBe(5000);
  });

  test('a settings-only save does not claim a move', () => {
    const id = nextId();
    seedPersistedProgress(id, at('A', 100));
    const withSettings = { ...at('A', 100), viewSettings: {} } as Partial<BookConfig>;
    expect(resolveProgressUpdatedAt(id, withSettings, 5000)).toBe(100);
  });

  test('a book never read here stays unclaimed until the reader moves', () => {
    const id = nextId();
    seedPersistedProgress(id, at('A'));
    expect(resolveProgressUpdatedAt(id, at('A'), 5000)).toBeUndefined();
    expect(resolveProgressUpdatedAt(id, at('B'), 6000)).toBe(6000);
  });

  test('a save without a prior load never claims a move', () => {
    const id = nextId();
    expect(resolveProgressUpdatedAt(id, at('A', 100), 5000)).toBe(100);
  });

  test('the position landed on after an adoption keeps the remote time', () => {
    const id = nextId();
    seedPersistedProgress(id, at('A', 100));
    markProgressAdoption(id, 3000, 4000);
    expect(resolveProgressUpdatedAt(id, at('REMOTE', 100), 4500)).toBe(3000);
    // Only the first move belongs to the adoption; the next is the reader's own.
    expect(resolveProgressUpdatedAt(id, at('NEXT', 3000), 9000)).toBe(9000);
  });

  test('an adoption that never lands expires', () => {
    const id = nextId();
    seedPersistedProgress(id, at('A', 100));
    markProgressAdoption(id, 3000, 4000);
    expect(resolveProgressUpdatedAt(id, at('B', 100), 4000 + 60_000)).toBe(64_000);
  });

  test('reloading a book clears a pending adoption', () => {
    const id = nextId();
    seedPersistedProgress(id, at('A', 100));
    markProgressAdoption(id, 3000, 4000);
    seedPersistedProgress(id, at('A', 100));
    expect(resolveProgressUpdatedAt(id, at('B', 100), 4500)).toBe(4500);
  });
});
