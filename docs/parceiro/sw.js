/* NIOGEN | docs/parceiro/sw.js | 10/11/2026 — Claude Code
 * Service worker do Pocket do Parceiro (escopo /parceiro/). Cache só dos arquivos estáticos do Pocket.
 * Supabase, ViaCEP e CDN passam direto pela rede. BUMPAR o CACHE a cada publicação (pocket-DDMMAA-N).
 */
const CACHE = 'pocket-101126-3';
const ARQUIVOS = ['./', 'index.html', 'pocket.css', 'pocket.js', 'manifest.webmanifest', '../assets/markdown.js', '../assets/icon.svg'];

self.addEventListener('install', (ev) => {
  ev.waitUntil(caches.open(CACHE).then((c) => c.addAll(ARQUIVOS)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (ev) => {
  ev.waitUntil(caches.keys()
    .then((ks) => Promise.all(ks.filter((k) => k.startsWith('pocket-') && k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});
// Rede primeiro (dados e telas sempre frescos); cache só se estiver offline. config.js nunca é cacheado.
self.addEventListener('fetch', (ev) => {
  const url = new URL(ev.request.url);
  if (ev.request.method !== 'GET' || url.origin !== self.location.origin || url.pathname.endsWith('/config.js')) return;
  ev.respondWith(
    fetch(ev.request)
      .then((r) => { if (r.ok) { const copia = r.clone(); caches.open(CACHE).then((c) => c.put(ev.request, copia)); } return r; })
      .catch(() => caches.match(ev.request, { ignoreSearch: true })),
  );
});
