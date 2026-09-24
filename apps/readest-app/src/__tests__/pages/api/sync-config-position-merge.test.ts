import { describe, expect, it } from 'vitest';
import { resolveConfigPositionMerge } from '@/pages/api/sync';
import type { DBBookConfig } from '@/types/records';

const iso = (ms: number) => new Date(ms).toISOString();
const NOW = iso(99_000);

const row = (
  position: string,
  updatedAt: number,
  progressUpdatedAt: number | null,
  extra: Partial<DBBookConfig> = {},
): DBBookConfig => ({
  user_id: 'u1',
  book_hash: 'h1',
  location: position,
  xpointer: `/x/${position}`,
  progress: '[1,10]',
  view_settings: `{"from":"${position}"}`,
  updated_at: iso(updatedAt),
  progress_updated_at: progressUpdatedAt === null ? null : iso(progressUpdatedAt),
  ...extra,
});

describe('resolveConfigPositionMerge', () => {
  it('client row and position both newer → client row as-is', () => {
    const client = row('C', 2000, 2000);
    expect(resolveConfigPositionMerge(client, row('S', 1000, 1000), true, NOW)).toBe(client);
  });

  it('client row newer but server position newer → keep the server position', () => {
    // Device B changed a setting (newer row) after device A moved (newer position).
    const merged = resolveConfigPositionMerge(
      row('C', 3000, 1000),
      row('S', 2000, 2000),
      true,
      NOW,
    )!;
    expect(merged.location).toBe('S');
    expect(merged.xpointer).toBe('/x/S');
    expect(merged.progress_updated_at).toBe(iso(2000));
    // The rest of the row is the client's.
    expect(merged.view_settings).toBe('{"from":"C"}');
    expect(merged.updated_at).toBe(iso(3000));
  });

  it('server row newer but client position newer → graft the client position', () => {
    // An offline device comes back: its row is older, but it moved after the
    // server's position was authored.
    const merged = resolveConfigPositionMerge(
      row('C', 1500, 1500),
      row('S', 2000, 1000),
      false,
      NOW,
    )!;
    expect(merged.location).toBe('C');
    expect(merged.progress_updated_at).toBe(iso(1500));
    // The server keeps the rest of its row, and updated_at advances so peers
    // pulling by updated_at see the change.
    expect(merged.view_settings).toBe('{"from":"S"}');
    expect(merged.updated_at).toBe(NOW);
  });

  it('server row and position both newer → no write', () => {
    expect(resolveConfigPositionMerge(row('C', 1000, 1000), row('S', 2000, 2000), false, NOW)).toBe(
      null,
    );
  });

  it('client position newer but identical → no write', () => {
    expect(resolveConfigPositionMerge(row('S', 1000, 1500), row('S', 2000, 1000), false, NOW)).toBe(
      null,
    );
  });

  it('position ties go to the client', () => {
    const merged = resolveConfigPositionMerge(
      row('C', 1000, 1000),
      row('S', 2000, 1000),
      false,
      NOW,
    )!;
    expect(merged.location).toBe('C');
  });

  it('legacy rows without progress_updated_at fall back to updated_at', () => {
    const merged = resolveConfigPositionMerge(
      row('C', 3000, null),
      row('S', 2000, 2500),
      true,
      NOW,
    )!;
    expect(merged.location).toBe('C');
  });

  it('copies missing position fields as nulls instead of keeping stale ones', () => {
    const client = row('C', 1500, 1500, { xpointer: undefined });
    const merged = resolveConfigPositionMerge(client, row('S', 2000, 1000), false, NOW)!;
    expect(merged.xpointer).toBeNull();
  });
});
