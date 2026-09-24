import { BookConfig } from '@/types/book';

// Reading-position watermark: `config.progressUpdatedAt` is the time the
// CURRENT reading position was authored — by a page turn on this device, or by
// the device whose position was adopted through sync. Sync compares these
// times across devices ("the most recently authored position wins"), so it
// must never advance for anything but a real move made here:
//
// - Opening a book, changing settings or annotations, or re-saving an
//   unchanged position keeps the existing time.
// - A position adopted from another device keeps THAT device's time (see
//   markProgressAdoption). Stamping it "now" would let this device later
//   overwrite a newer move made elsewhere in the meantime.
//
// Position changes are detected against the last position known to be on
// disk. The caller mutates the store before calling saveConfig, so comparing
// store-vs-store would always look unchanged; instead we remember a signature
// of the persisted position per book, seeded when the book is loaded.
const persistedProgressSig = new Map<string, string>();

// How long a pending adoption waits for the view to settle on the adopted
// position. Book loading can delay the relocate after goTo by a few seconds.
const ADOPTION_WINDOW_MS = 15_000;
const pendingAdoptions = new Map<string, { progressUpdatedAt: number; expiresAt: number }>();

const computeProgressSig = (c: Partial<BookConfig>): string =>
  JSON.stringify({
    progress: c.progress,
    location: c.location,
    xpointer: c.xpointer,
    rsvpPosition: c.rsvpPosition,
  });

/**
 * Record the position a book was just loaded with from disk. saveConfig treats
 * only a departure from this (or from a later persisted position) as a move.
 */
export const seedPersistedProgress = (id: string, config: Partial<BookConfig>) => {
  persistedProgressSig.set(id, computeProgressSig(config));
  pendingAdoptions.delete(id);
};

/**
 * Resolve the progressUpdatedAt to persist for `config`, and update the
 * persisted-position signature. Exported for tests.
 */
export const resolveProgressUpdatedAt = (
  id: string,
  config: Partial<BookConfig>,
  now: number,
): number | undefined => {
  const sig = computeProgressSig(config);
  const lastSig = persistedProgressSig.get(id);
  if (lastSig === undefined) {
    // Never seeded (a save before any load, e.g. from the library): nothing to
    // compare against, so don't claim a move.
    persistedProgressSig.set(id, sig);
    return config.progressUpdatedAt;
  }
  if (lastSig === sig) return config.progressUpdatedAt;
  persistedProgressSig.set(id, sig);
  const adoption = pendingAdoptions.get(id);
  if (adoption) {
    pendingAdoptions.delete(id);
    // The first position persisted after an adoption is where the view
    // landed on the adopted position; it keeps the adopted time. If the user
    // turned a page inside the window this under-dates their move, which only
    // makes it lose ties — it can never overwrite a newer remote position.
    if (adoption.expiresAt >= now) return adoption.progressUpdatedAt;
  }
  return now;
};

/**
 * Mark that the view is about to move to a position adopted from another
 * device, authored at `progressUpdatedAt`. The next persisted position keeps
 * that time instead of "now".
 */
export const markProgressAdoption = (id: string, progressUpdatedAt: number, now = Date.now()) => {
  pendingAdoptions.set(id, { progressUpdatedAt, expiresAt: now + ADOPTION_WINDOW_MS });
};
