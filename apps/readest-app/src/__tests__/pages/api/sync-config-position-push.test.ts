import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { NextRequest } from 'next/server';

// End-to-end check of a book_configs push through POST /api/sync: the reading
// position is merged on progress_updated_at, independently of the row-level
// updated_at decision (see resolveConfigPositionMerge).

type Row = Record<string, unknown>;
const state = {
  serverRows: [] as Row[],
  upserts: [] as Row[][],
  bookUpdates: [] as { values: Row; filters: [string, string, unknown][] }[],
};

const fromMock = vi.fn((table: string) => {
  if (table === 'book_configs') {
    return {
      select: () => ({ or: async () => ({ data: state.serverRows, error: null }) }),
      insert: (rows: Row[]) => ({ select: async () => ({ data: rows, error: null }) }),
      upsert: (rows: Row[]) => {
        state.upserts.push(rows);
        return { select: async () => ({ data: rows, error: null }) };
      },
    };
  }
  if (table === 'books') {
    return {
      update: (values: Row) => {
        const entry = { values, filters: [] as [string, string, unknown][] };
        state.bookUpdates.push(entry);
        const chain = {
          eq: (col: string, v: unknown) => {
            entry.filters.push(['eq', col, v]);
            return chain;
          },
          lt: async (col: string, v: unknown) => {
            entry.filters.push(['lt', col, v]);
            return { error: null };
          },
        };
        return chain;
      },
    };
  }
  throw new Error(`unexpected table ${table}`);
});

vi.mock('@/utils/supabase', () => ({
  createSupabaseClient: () => ({ from: fromMock, rpc: vi.fn() }),
}));
vi.mock('@/utils/access', () => ({
  validateUserAndToken: async () => ({ user: { id: 'u1' }, token: 'tok' }),
}));

import { POST } from '@/pages/api/sync';

const post = async (body: unknown) => {
  const res = await POST(
    new Request('https://web.readest.com/api/sync', {
      method: 'POST',
      headers: { authorization: 'Bearer tok', 'content-type': 'application/json' },
      body: JSON.stringify(body),
    }) as unknown as NextRequest,
  );
  return { status: res.status, body: (await res.json()) as { configs: Row[] } };
};

const iso = (ms: number) => new Date(ms).toISOString();

// Client-side (camelCase) config as pushed by the app / KOReader plugin.
const clientConfig = (location: string, updatedAt: number, progressUpdatedAt: number) => ({
  bookHash: 'h1',
  metaHash: 'm1',
  location,
  progress: [7, 100],
  updatedAt,
  progressUpdatedAt,
});

const serverRow = (location: string, updatedAt: number, progressUpdatedAt: number) => ({
  user_id: 'u1',
  book_hash: 'h1',
  meta_hash: 'm1',
  location,
  progress: '[3,100]',
  updated_at: iso(updatedAt),
  progress_updated_at: iso(progressUpdatedAt),
});

beforeEach(() => {
  state.serverRows = [];
  state.upserts = [];
  state.bookUpdates = [];
});

describe('POST /api/sync book_configs position merge', () => {
  it('a settings-newer client row keeps the newer server position and returns it', async () => {
    state.serverRows = [serverRow('SERVER', 2000, 2000)];
    const { status, body } = await post({ configs: [clientConfig('CLIENT', 3000, 1000)] });
    expect(status).toBe(200);
    expect(state.upserts[0]![0]!['location']).toBe('SERVER');
    // The authoritative row returned to the client carries the server position,
    // which is how the client learns another device moved.
    expect(body.configs[0]!['location']).toBe('SERVER');
  });

  it('an older client row with a newer position is grafted onto the server row', async () => {
    state.serverRows = [serverRow('SERVER', 5000, 1000)];
    await post({ configs: [clientConfig('CLIENT', 4000, 2000)] });
    const written = state.upserts[0]![0]!;
    expect(written['location']).toBe('CLIENT');
    expect(written['progress_updated_at']).toBe(iso(2000));
    // updated_at advances (server clock) so peers pulling by updated_at see it.
    expect(new Date(written['updated_at'] as string).getTime()).toBeGreaterThan(5000);
  });

  it('an older client row with an older position writes nothing', async () => {
    state.serverRows = [serverRow('SERVER', 5000, 3000)];
    const { body } = await post({ configs: [clientConfig('CLIENT', 4000, 2000)] });
    expect(state.upserts).toHaveLength(0);
    expect(body.configs[0]!['location']).toBe('SERVER');
  });

  it('a push with position time 0 (never authored) cannot beat a stamped server position', async () => {
    state.serverRows = [serverRow('SERVER', 1000, 1000)];
    const { body } = await post({ configs: [clientConfig('PAGE-ONE', 9000, 0)] });
    expect(state.upserts[0]![0]!['location']).toBe('SERVER');
    expect(body.configs[0]!['location']).toBe('SERVER');
  });

  it('stamps the books row with the position authoring time, not the row time', async () => {
    state.serverRows = [serverRow('SERVER', 1000, 1000)];
    await post({ configs: [clientConfig('CLIENT', 9000, 4000)] });
    const update = state.bookUpdates[0]!;
    expect(update.values).toEqual({ progress: [7, 100], updated_at: iso(4000) });
    expect(update.filters).toContainEqual(['lt', 'updated_at', iso(4000)]);
  });
});
