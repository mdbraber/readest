import type { PrecacheEntry, SerwistGlobalConfig } from 'serwist';
import { NetworkFirst, CacheFirst, ExpirationPlugin, Serwist } from 'serwist';

declare global {
  interface WorkerGlobalScope extends SerwistGlobalConfig {
    __SW_MANIFEST: (PrecacheEntry | string)[] | undefined;
  }
}

declare const self: ServiceWorkerGlobalScope;

const serwist = new Serwist({
  precacheEntries: self.__SW_MANIFEST,
  skipWaiting: true,
  clientsClaim: true,
  navigationPreload: true,
  disableDevLogs: true,
  fallbacks: {
    entries: [
      {
        url: '/offline',
        matcher({ request }) {
          return request.destination === 'document';
        },
      },
    ],
  },
  runtimeCaching: [
    {
      matcher: ({ url, request }) => {
        // Catch ALL same-origin navigations (not just /library and /reader)
        // so the offline fallback chain below can rescue any URL — including
        // root `/` which the user lands on when launching the PWA offline.
        return request.mode === 'navigate' && url.origin === self.location.origin;
      },
      handler: new NetworkFirst({
        cacheName: 'client-pages',
        networkTimeoutSeconds: 3,
        matchOptions: {
          ignoreSearch: true,
        },
        plugins: [
          new ExpirationPlugin({
            maxEntries: 128,
            maxAgeSeconds: 365 * 24 * 60 * 60,
          }),
          {
            cacheKeyWillBeUsed: async ({ request }) => {
              const url = new URL(request.url);
              const basePath = url.pathname.split('/')[1];
              const cacheKey = `${url.origin}/${basePath}`;
              return cacheKey;
            },
          },
          {
            // Hard fallback chain so navigations never end up as
            // FetchEvent.respondWith no-response (the Safari "can't open the
            // page" error). Tries: any /library cache, any /reader cache,
            // any precached document, finally a synthetic Response.
            handlerDidError: async () => {
              const candidates = [
                'https://readest.nidere.com/library',
                'https://readest.nidere.com/reader',
                'https://readest.nidere.com/',
                '/offline',
              ];
              for (const url of candidates) {
                const r = await caches.match(url, { ignoreSearch: true });
                if (r) return r;
              }
              return new Response(
                '<!doctype html><meta charset=utf-8><title>Offline</title>' +
                  '<style>body{font:14px system-ui;padding:2em;color:#888;text-align:center}</style>' +
                  '<p>You are offline and this page has not been cached yet.</p>' +
                  '<p>Open Wi-Fi and reload to populate the cache.</p>',
                { status: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' } },
              );
            },
          },
        ],
      }),
    },
    // Fonts: CacheFirst strategy for maximum performance
    {
      matcher: ({ url, request }) => {
        // Match font files by extension
        const isFontFile = /\.(woff2?|ttf|otf|eot|svg)(\?.*)?$/i.test(url.pathname);
        // Match font requests by destination
        const isFontRequest = request.destination === 'font';
        // Match Google Fonts CSS and font CDNs
        const isFontCDN =
          url.hostname === 'fonts.googleapis.com' ||
          url.hostname === 'fonts.gstatic.com' ||
          url.hostname === 'cdn.jsdelivr.net' ||
          url.hostname === 'cdnjs.cloudflare.com' ||
          url.hostname === 'ik.imagekit.io' ||
          url.hostname === 'db.onlinewebfonts.com';

        return isFontFile || isFontRequest || isFontCDN;
      },
      handler: new CacheFirst({
        cacheName: 'fonts-cache',
        plugins: [
          new ExpirationPlugin({
            maxEntries: 200, // More entries for various font files
            maxAgeSeconds: 365 * 24 * 60 * 60 * 2, // 2 years - fonts rarely change
            purgeOnQuotaError: true, // Automatically purge if storage quota exceeded
          }),
        ],
      }),
    },
    // Other external resources
    {
      matcher: ({ url }) => {
        if (url.pathname.startsWith('/api/')) {
          return false;
        }
        return /^https?.*/.test(url.href);
      },
      handler: new NetworkFirst({
        cacheName: 'offline-cache',
        networkTimeoutSeconds: 3,
        plugins: [
          new ExpirationPlugin({
            maxEntries: 512,
            maxAgeSeconds: 365 * 24 * 60 * 60,
          }),
        ],
      }),
    },
  ],
});

serwist.addEventListeners();
