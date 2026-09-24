-- Fork migration: per-field timestamp for the reading position of a book config.
--
-- progress_updated_at records when the reading position (progress, location,
-- xpointer, rsvp_position) was authored, independently of the row-level
-- updated_at. The sync API merges the position on this clock, so a settings
-- change on one device can't overwrite a newer position pushed by another.
--
-- Numbered 900 so it sorts after every upstream migration and can never share
-- a number with one again. It first shipped as `014_progress_updated_at.sql`,
-- which collided with upstream's `014_add_reading_stats.sql`. The migration ledger
-- (readest_meta.migrations) is keyed by file name, so databases that already
-- applied the old name run this file once more: every statement is idempotent.
ALTER TABLE public.book_configs
  ADD COLUMN IF NOT EXISTS progress_updated_at timestamp with time zone;

-- Backfill rows written before the column existed (or by clients that never
-- sent it) with the best available estimate of when their position was set.
UPDATE public.book_configs
  SET progress_updated_at = updated_at
  WHERE progress_updated_at IS NULL;
