/* NIOGEN | push/servidor.js | 15/11/2026 13:50 — Claude Code (Opus 5.5)
 * Serviço mínimo de Web Push do NIOGEN. Roda na VPS do n8n (45.32.161.130) como container "niogen-push", só na rede docker
 * renata_web, SEM porta publicada: só o n8n (fluxo push_live) chega nele, em http://niogen-push:8096.
 * Por que um serviço e não o nó Code do n8n: o n8n é dividido com a Vero e não libera require() nos nós (sem
 * NODE_FUNCTION_ALLOW_*); a cifra do Web Push (RFC 8291) e a assinatura VAPID precisam do crypto do Node.
 * Chaves VAPID: VAPID_PUBLICA / VAPID_PRIVADA só em /opt/niogen/push/.env (chmod 600), geradas na VPS pelo instalar.sh —
 * nunca em arquivo versionado, Drive ou chat (regra 5). A pública não é segredo: vai para config_regras.push pelo push_live.
 * Rotas: GET /saude · GET /chave (só a pública) · POST /enviar { itens: [{ id, endpoint, keys: {p256dh, auth}, payload }] }
 *        → { itens: [{ id, status, erro }] }  (status = HTTP do serviço de push: 201 ok · 404/410 aparelho saiu).
 * Trava: só manda para os serviços de push conhecidos (Google, Mozilla, Apple, Microsoft) — nunca para outro endereço.
 */
'use strict';
const http = require('http');
const webpush = require('web-push');

const PORTA = Number(process.env.PORTA || 8096);
const { VAPID_PUBLICA, VAPID_PRIVADA } = process.env;
const ASSUNTO = process.env.VAPID_ASSUNTO || 'https://niogen.dharmatelecom.com.br';
if (!VAPID_PUBLICA || !VAPID_PRIVADA) { console.error('VAPID_PUBLICA/VAPID_PRIVADA ausentes no .env'); process.exit(1); }
webpush.setVapidDetails(ASSUNTO, VAPID_PUBLICA, VAPID_PRIVADA);

const HOSTS = [/(^|\.)fcm\.googleapis\.com$/, /(^|\.)push\.services\.mozilla\.com$/, /(^|\.)push\.apple\.com$/, /(^|\.)notify\.windows\.com$/];
const permitido = (endpoint) => {
  try { const u = new URL(endpoint); return u.protocol === 'https:' && HOSTS.some((r) => r.test(u.hostname)); } catch (e) { return false; }
};

async function enviarUm(it) {
  if (!it || !it.endpoint || !it.keys || !it.keys.p256dh || !it.keys.auth) return { id: it && it.id, status: 0, erro: 'inscrição incompleta' };
  if (!permitido(it.endpoint)) return { id: it.id, status: 0, erro: 'endpoint fora dos serviços de push conhecidos' };
  const corpo = JSON.stringify(it.payload || {}).slice(0, 3000);
  try {
    const r = await webpush.sendNotification({ endpoint: it.endpoint, keys: it.keys }, corpo, { TTL: 4 * 3600, urgency: 'high', timeout: 15000 });
    return { id: it.id, status: r.statusCode, erro: null };
  } catch (e) {
    return { id: it.id, status: e.statusCode || 0, erro: String(e.body || e.message || e).slice(0, 300) };
  }
}

function ler(req) {
  return new Promise((ok, falha) => {
    let s = '';
    req.on('data', (c) => { s += c; if (s.length > 2e6) { falha(new Error('corpo grande demais')); req.destroy(); } });
    req.on('end', () => { try { ok(s ? JSON.parse(s) : {}); } catch (e) { falha(e); } });
  });
}
const responder = (res, cod, obj) => { res.writeHead(cod, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };

http.createServer(async (req, res) => {
  try {
    if (req.method === 'GET' && req.url === '/saude') return responder(res, 200, { ok: true });
    if (req.method === 'GET' && req.url === '/chave') return responder(res, 200, { publica: VAPID_PUBLICA });
    if (req.method === 'POST' && req.url === '/enviar') {
      const b = await ler(req);
      const itens = Array.isArray(b.itens) ? b.itens.slice(0, 200) : [];
      const saida = [];
      for (let i = 0; i < itens.length; i += 10) saida.push(...(await Promise.all(itens.slice(i, i + 10).map(enviarUm))));
      const ok = saida.filter((x) => x.status >= 200 && x.status < 300).length;
      console.log(`${new Date().toISOString()} enviar: ${saida.length} itens, ${ok} ok`);
      return responder(res, 200, { itens: saida });
    }
    responder(res, 404, { erro: 'rota' });
  } catch (e) { responder(res, 400, { erro: String(e.message || e) }); }
}).listen(PORTA, () => console.log(`niogen-push na porta ${PORTA}`));
