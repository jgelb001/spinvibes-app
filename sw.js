// Bump this token on any deploy you want to force-adopt immediately. The HTML
// path below is now {cache:'no-store'}, so even WITHOUT a bump, installed users
// fetch fresh index.html on every load (the old code honored GitHub Pages'
// max-age=600 and could serve a stale disk copy for ~10 min). The token still
// guarantees a clean cache swap when this file's bytes change.
const CACHE = 'spinvibes-app-v19'; // 2026-07-02 s53: Family resources parent page (adult Home, bottom tab)
const SHELL = ['/', '/index.html', '/confirm.html', '/manifest.json'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  if (e.request.url.includes('supabase') || e.request.url.includes('workers.dev') || e.request.url.includes('anthropic')) return;

  const url = new URL(e.request.url);
  const isShell = url.origin === location.origin &&
    (url.pathname === '/' || url.pathname.endsWith('.html'));

  if (isShell) {
    // TRUE network-first for HTML: {cache:'no-store'} bypasses the browser HTTP
    // cache so a deploy is seen on the very next load. Cache updated only as an
    // offline fallback.
    e.respondWith(
      fetch(e.request, { cache: 'no-store' }).then(res => {
        const clone = res.clone();
        caches.open(CACHE).then(c => c.put(e.request, clone));
        return res;
      }).catch(() => caches.match(e.request).then(r => r || caches.match('/index.html')))
    );
    return;
  }

  // Cache-first for static assets
  e.respondWith(caches.match(e.request).then(r => r || fetch(e.request).then(res => {
    const clone = res.clone();
    caches.open(CACHE).then(c => c.put(e.request, clone));
    return res;
  })));
});
