// Offline fallback for page navigations in the service worker (src/sw.ts).
//
// NetworkFirst has already tried the requested page's own cache entry by the
// time this runs. Fall back only to a cached page that renders the same
// screen — `/` renders the library — then to the precached /offline page.
// Never serve a different route's page: its embedded route data would render
// the wrong screen at the requested URL.

type CacheLookup = (url: string) => Promise<Response | undefined>;

export const offlineFallbackCandidates = (requestUrl: string, origin: string): string[] => {
  const { pathname } = new URL(requestUrl);
  const isLibrary = pathname === '/' || pathname === '/library' || pathname.startsWith('/library/');
  return [...(isLibrary ? [`${origin}/library`, `${origin}/`] : []), `${origin}/offline`];
};

export const OFFLINE_FALLBACK_HTML =
  '<!doctype html><meta charset=utf-8><title>Offline</title>' +
  '<style>body{font:14px system-ui;padding:2em;color:#888;text-align:center}</style>' +
  '<p>You are offline and this page has not been cached yet.</p>' +
  '<p>Reconnect and reload to make it available offline.</p>';

export const resolveOfflineNavigation = async (
  requestUrl: string,
  origin: string,
  match: CacheLookup,
): Promise<Response> => {
  for (const url of offlineFallbackCandidates(requestUrl, origin)) {
    const cached = await match(url);
    if (cached) return cached;
  }
  return new Response(OFFLINE_FALLBACK_HTML, {
    status: 200,
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  });
};

/** Same-origin page navigations the service worker may cache and rescue offline. */
export const isCacheablePageNavigation = (url: URL, mode: string, origin: string): boolean =>
  mode === 'navigate' &&
  url.origin === origin &&
  !url.pathname.startsWith('/api/') &&
  !url.pathname.startsWith('/.well-known/');
