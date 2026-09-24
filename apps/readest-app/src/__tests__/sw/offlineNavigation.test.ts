import { describe, expect, test } from 'vitest';
import {
  isCacheablePageNavigation,
  offlineFallbackCandidates,
  resolveOfflineNavigation,
} from '@/utils/offlineNavigation';

const ORIGIN = 'https://books.example.org';

const cacheWith = (entries: Record<string, string>) => async (url: string) =>
  url in entries ? new Response(entries[url]) : undefined;

describe('offline navigation fallback', () => {
  test('library routes fall back to the cached library, then the offline page', () => {
    expect(offlineFallbackCandidates(`${ORIGIN}/`, ORIGIN)).toEqual([
      `${ORIGIN}/library`,
      `${ORIGIN}/`,
      `${ORIGIN}/offline`,
    ]);
    expect(offlineFallbackCandidates(`${ORIGIN}/library?group=x`, ORIGIN)[0]).toBe(
      `${ORIGIN}/library`,
    );
  });

  test('other routes never get a different page, only the offline page', () => {
    expect(offlineFallbackCandidates(`${ORIGIN}/reader?ids=abc`, ORIGIN)).toEqual([
      `${ORIGIN}/offline`,
    ]);
    expect(offlineFallbackCandidates(`${ORIGIN}/libraryx`, ORIGIN)).toEqual([`${ORIGIN}/offline`]);
  });

  test('candidates are always on the serving origin', () => {
    for (const url of offlineFallbackCandidates(`${ORIGIN}/`, ORIGIN)) {
      expect(new URL(url).origin).toBe(ORIGIN);
    }
  });

  test('serves the first cached candidate', async () => {
    const res = await resolveOfflineNavigation(
      `${ORIGIN}/`,
      ORIGIN,
      cacheWith({ [`${ORIGIN}/`]: 'root', [`${ORIGIN}/offline`]: 'offline' }),
    );
    expect(await res.text()).toBe('root');
  });

  test('falls back to an inline page when nothing is cached', async () => {
    const res = await resolveOfflineNavigation(`${ORIGIN}/reader`, ORIGIN, cacheWith({}));
    expect(res.status).toBe(200);
    expect(res.headers.get('Content-Type')).toContain('text/html');
    expect(await res.text()).toContain('You are offline');
  });

  test('only same-origin page navigations are cached', () => {
    const nav = (path: string, origin = ORIGIN) => new URL(path, origin);
    expect(isCacheablePageNavigation(nav('/library'), 'navigate', ORIGIN)).toBe(true);
    expect(isCacheablePageNavigation(nav('/'), 'navigate', ORIGIN)).toBe(true);
    expect(isCacheablePageNavigation(nav('/api/sync'), 'navigate', ORIGIN)).toBe(false);
    expect(
      isCacheablePageNavigation(nav('/.well-known/readest-client-config.json'), 'navigate', ORIGIN),
    ).toBe(false);
    expect(isCacheablePageNavigation(nav('/library'), 'cors', ORIGIN)).toBe(false);
    expect(
      isCacheablePageNavigation(nav('/library', 'https://other.example'), 'navigate', ORIGIN),
    ).toBe(false);
  });
});
