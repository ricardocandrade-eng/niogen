/* NIOGEN | docs/sw.js | 03/11/2026
 * Cache só dos arquivos estáticos do próprio site. Supabase, ViaCEP e CDN passam direto pela rede.
 * BUMPAR o CACHE a cada publicação (niogen-DDMMAA-N).
 */
const CACHE = 'niogen-141126-14';
const ARQUIVOS = [
  './', 'index.html', 'painel.html', 'funil.html', 'instalacoes.html', 'operacoes.html', 'vendas.html', 'venda.html', 'configuracoes.html', 'tabela.html', 'metaads.html', 'cobertura.html', 'credito.html', 'mari.html', 'embreve.html', 'adimplencia.html', 'conciliacao.html', 'parceiros.html', 'pagamentos.html', 'guia.html', 'fila.html', 'conversas.html', 'leads.html',
  'assets/app.css', 'assets/app.js', 'assets/ficha.js', 'assets/conversa.js', 'assets/novavenda.js', 'assets/sidebar.js', 'assets/pulso.js', 'assets/osab.js', 'assets/dfv.js', 'assets/markdown.js', 'assets/icon.svg', 'manifest.webmanifest',
];

self.addEventListener('install', (ev) => {
  ev.waitUntil(caches.open(CACHE).then((c) => c.addAll(ARQUIVOS.map((u) => new Request(u, { cache: 'reload' })))).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (ev) => {
  ev.waitUntil(
    caches.keys()
      .then((ks) => Promise.all(ks.filter((k) => k.startsWith('niogen-') && k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

// Rede primeiro (dados sempre frescos); cache só se estiver offline. config.js nunca é cacheado.
self.addEventListener('fetch', (ev) => {
  const url = new URL(ev.request.url);
  if (ev.request.method !== 'GET' || url.origin !== self.location.origin || url.pathname.endsWith('/config.js')) return;
  // 14/11: página (HTML) sempre conferida no servidor — o GitHub Pages manda guardar 10 min e a publicação nova demorava a
  // aparecer (e o cache novo podia nascer com a página velha). Assets vêm com ?v= e seguem o cache normal do navegador.
  const pagina = ev.request.mode === 'navigate' || url.pathname.endsWith('.html') || url.pathname.endsWith('/');
  ev.respondWith(
    (pagina ? fetch(url.href, { cache: 'no-cache', credentials: 'same-origin' }) : fetch(ev.request))
      .then((r) => {
        if (r.ok) { const copia = r.clone(); caches.open(CACHE).then((c) => c.put(ev.request, copia)); }
        return r;
      })
      .catch(() => caches.match(ev.request, { ignoreSearch: true })),
  );
});
