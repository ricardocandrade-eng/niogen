/* NIOGEN | docs/sw.js | 03/11/2026
 * Cache só dos arquivos estáticos do próprio site. Supabase, ViaCEP e CDN passam direto pela rede.
 * BUMPAR o CACHE a cada publicação (niogen-DDMMAA-N).
 */
const CACHE = 'niogen-041126-16';
const ARQUIVOS = [
  './', 'index.html', 'painel.html', 'funil.html', 'instalacoes.html', 'vendas.html', 'venda.html', 'configuracoes.html', 'tabela.html', 'metaads.html', 'cobertura.html', 'mari.html',
  'assets/app.css', 'assets/app.js', 'assets/sidebar.js', 'assets/osab.js', 'assets/dfv.js', 'assets/icon.svg', 'manifest.webmanifest',
];

self.addEventListener('install', (ev) => {
  ev.waitUntil(caches.open(CACHE).then((c) => c.addAll(ARQUIVOS)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (ev) => {
  ev.waitUntil(
    caches.keys()
      .then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

// Rede primeiro (dados sempre frescos); cache só se estiver offline. config.js nunca é cacheado.
self.addEventListener('fetch', (ev) => {
  const url = new URL(ev.request.url);
  if (ev.request.method !== 'GET' || url.origin !== self.location.origin || url.pathname.endsWith('/config.js')) return;
  ev.respondWith(
    fetch(ev.request)
      .then((r) => {
        if (r.ok) { const copia = r.clone(); caches.open(CACHE).then((c) => c.put(ev.request, copia)); }
        return r;
      })
      .catch(() => caches.match(ev.request, { ignoreSearch: true })),
  );
});
