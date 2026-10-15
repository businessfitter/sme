// Orzio service worker: makes the app installable and opens instantly from the home screen.
// Pages and code come from the network first (so updates show straight away) with a cached copy
// for when the phone is offline. Data, sign-in and files are never cached.
const CACHE = 'orzio-v4';
const SHELL = ['/app', '/claude-shim.js', '/vendor/supabase-2.45.4.js', '/brand/app-icon.svg', '/brand/icon-192.png', '/brand/icon-512.png', '/site.webmanifest'];
self.addEventListener('install', (e) => { e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).catch(() => {})); self.skipWaiting(); });
self.addEventListener('activate', (e) => { e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k))))); self.clients.claim(); });
self.addEventListener('fetch', (e) => {
  const req = e.request; const u = new URL(req.url);
  if (req.method !== 'GET' || u.origin !== location.origin) return;
  if (u.pathname.startsWith('/api/') || u.pathname.startsWith('/_blob/') || u.pathname.startsWith('/admin')) return;
  const isPage = req.mode === 'navigate';
  e.respondWith(fetch(req).then((res) => {
    if (res.ok && (isPage || /\.(js|css|svg|png|webmanifest)$/.test(u.pathname))) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(isPage ? '/app' : req, copy)); }
    return res;
  }).catch(() => caches.match(isPage ? '/app' : req).then((r) => r || new Response('Offline. Reconnect to use Orzio.', { status: 503, headers: { 'content-type': 'text/plain' } }))));
});
