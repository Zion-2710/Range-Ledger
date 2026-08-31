// Range Ledger service worker — caches the app shell (this HTML file plus
// the three CDN libraries it depends on) so the app can still open when
// there's no connection, not just keep working data-wise once it's open
// (that part is handled separately, by the in-app offline queue).
//
// Deliberately does NOT cache anything under supabase.co — data must
// always be live, never served stale from a cache.
const CACHE_NAME = 'range-ledger-shell-v1';
const SHELL_URLS = [
  './',
  './index.html',
  'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js',
  'https://cdn.jsdelivr.net/npm/qrcode@1.5.3/build/qrcode.min.js',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(SHELL_URLS))
      .catch(() => {}) // a CDN being briefly unreachable at install time shouldn't break the service worker
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) => Promise.all(
      names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n))
    ))
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const url = event.request.url;

  // Never intercept Supabase API/auth/storage/realtime traffic — this must
  // always hit the network, never be served from cache.
  if (url.includes('supabase.co')) return;

  // The HTML shell itself: try the network first (so a logged-in user
  // always gets the latest version when online), falling back to the
  // cached copy only when the network fails.
  if (event.request.mode === 'navigate' || url.endsWith('/') || url.endsWith('index.html')) {
    event.respondWith(
      fetch(event.request)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
          return res;
        })
        .catch(() => caches.match(event.request).then((cached) => cached || caches.match('./index.html')))
    );
    return;
  }

  // Static CDN libraries: cache-first, since these are pinned versions
  // that don't change — no need to hit the network for them every time.
  event.respondWith(
    caches.match(event.request).then((cached) => cached || fetch(event.request).then((res) => {
      const copy = res.clone();
      caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
      return res;
    }))
  );
});
