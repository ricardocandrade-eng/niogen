/* NIOGEN | docs/sw.js | 03/11/2026
 * Cache só dos arquivos estáticos do próprio site. Supabase, ViaCEP e CDN passam direto pela rede.
 * BUMPAR o CACHE a cada publicação (niogen-DDMMAA-N).
 * rev. 15/11/2026 (Claude Code · NIOGEN no celular, protótipo docs/LAYOUT_conversas_mobile_151126_1304.html):
 *   · precache do shell (telas + assets + ícones do app instalável + pulso.html + movel.js);
 *   · NUNCA guarda resposta autenticada nem corpo de conversa: só GET do próprio site, sem Authorization, sem cookie de sessão
 *     e sem Cache-Control private/no-store. Supabase (outro domínio) é sempre rede — o navegador nem passa por aqui;
 *   · Web Push: mostra o aviso que o n8n mandou (título, texto, url) e o clique abre/foca o NIOGEN na linha do Live.
 */
const CACHE = 'niogen-201126-1';
const ARQUIVOS = [
  './', 'index.html', 'painel.html', 'funil.html', 'instalacoes.html', 'operacoes.html', 'vendas.html', 'venda.html', 'configuracoes.html', 'tabela.html', 'metaads.html', 'cobertura.html', 'credito.html', 'mari.html', 'embreve.html', 'adimplencia.html', 'conciliacao.html', 'parceiros.html', 'pagamentos.html', 'guia.html', 'fila.html', 'conversas.html', 'leads.html', 'pulso.html',
  'assets/app.css', 'assets/app.js', 'assets/ficha.js', 'assets/conversa.js', 'assets/novavenda.js', 'assets/sidebar.js', 'assets/pulso.js', 'assets/movel.js', 'assets/osab.js', 'assets/dfv.js', 'assets/markdown.js', 'assets/icon.svg', 'manifest.webmanifest',
  'assets/icones/niogen_192.png', 'assets/icones/niogen_512.png', 'assets/icones/niogen_maskable_192.png', 'assets/icones/niogen_maskable_512.png', 'assets/icones/niogen_apple_180.png', 'assets/icones/niogen_96.png',
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

// Pode guardar? Só arquivo estático do próprio site, pedido sem credencial e resposta pública.
function podeGuardar(req, r) {
  if (!r || !r.ok || r.type !== 'basic') return false;
  if (req.headers.has('authorization')) return false;
  const cc = (r.headers.get('cache-control') || '').toLowerCase();
  if (cc.includes('no-store') || cc.includes('private')) return false;
  const tipo = (r.headers.get('content-type') || '').toLowerCase();
  return !tipo.includes('application/json');   // nenhum JSON (dado) entra no cache — só HTML, CSS, JS, imagem e manifest
}

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
        if (podeGuardar(ev.request, r)) { const copia = r.clone(); caches.open(CACHE).then((c) => c.put(ev.request, copia)); }
        return r;
      })
      .catch(() => caches.match(ev.request, { ignoreSearch: true })),
  );
});

// ───────── Web Push (0215 · fluxo n8n push_live) ─────────
// O corpo vem cifrado para este aparelho: { titulo, corpo, url, envio, tag, gatilho }. Sem corpo legível → aviso genérico.
self.addEventListener('push', (ev) => {
  let d = {};
  try { d = ev.data ? ev.data.json() : {}; } catch (e) { d = { corpo: ev.data ? ev.data.text() : '' }; }
  const titulo = d.titulo || 'NIOGEN';
  const opcoes = {
    body: d.corpo || 'Tem coisa nova no Live.',
    icon: 'assets/icones/niogen_192.png',
    badge: 'assets/icones/niogen_96.png',
    tag: d.tag || 'niogen',
    renotify: false,
    lang: 'pt-BR',
    data: { url: d.url || 'fila.html', envio: d.envio || null },
  };
  ev.waitUntil(self.registration.showNotification(titulo, opcoes));
});

// Clique: foca uma janela do NIOGEN que já esteja aberta (e leva à linha) ou abre uma nova. O id do envio vai na url
// (?envio=) para a tela marcar a sessão como "veio do aviso" (app_sessao_registrar) — a medida do item 6.
self.addEventListener('notificationclick', (ev) => {
  ev.notification.close();
  const d = ev.notification.data || {};
  const alvo = new URL(d.url || 'fila.html', self.registration.scope);
  if (d.envio) alvo.searchParams.set('envio', d.envio);
  ev.waitUntil((async () => {
    const janelas = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const minha = janelas.find((j) => j.url.startsWith(self.registration.scope));
    if (minha) {
      try { await minha.navigate(alvo.href); } catch (e) { /* navegador sem navigate: abre outra */ return self.clients.openWindow(alvo.href); }
      return minha.focus();
    }
    return self.clients.openWindow(alvo.href);
  })());
});

// O navegador trocou a inscrição (raro): avisa as telas abertas para gravarem de novo (movel.js escuta).
self.addEventListener('pushsubscriptionchange', (ev) => {
  ev.waitUntil(self.clients.matchAll({ type: 'window' }).then((js) => js.forEach((j) => j.postMessage({ tipo: 'push-renovar' }))));
});
