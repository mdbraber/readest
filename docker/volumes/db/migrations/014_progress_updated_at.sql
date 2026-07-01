-- Migration 014: per-field timestamp for reading position fields.
-- Lets the server merge (progress, location, xpointer, rsvp_position)
-- independently from the row-level updated_at, so changing view_settings
-- on device B doesn't overwrite the position that device A just pushed.
ALTER TABLE public.book_configs
  ADD COLUMN IF NOT EXISTS progress_updated_at timestamptz;
UPDATE public.book_configs
  SET progress_updated_at = updated_at
  WHERE progress_updated_at IS NULL;
