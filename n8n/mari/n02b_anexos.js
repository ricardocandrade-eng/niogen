// NIOGEN | n8n/mari/n02b_anexos.js — nó "2b · Anexos" do mari_principal (12/11/2026, 0145)
// docs/Prompt_midia_transcricao_121126_0230.md. Um item por anexo que vai para o bucket privado midia_conversas
// (áudio e imagem até 16 MB). Caminho: mari/<conversa do Chatwoot>/<mensagem>_<n>.<ext>. Sem segredo, sem texto de negócio.
// transcrever = áudio sem a transcrição do próprio Chatwoot (essa vem de graça e é usada no 2b8).
const e = $('2 · Entrada').first().json;
const PADRAO = { audio: 'ogg', imagem: 'jpg' };
const MIME = { ogg: 'audio/ogg', oga: 'audio/ogg', opus: 'audio/ogg', mp3: 'audio/mpeg', m4a: 'audio/mp4', mp4: 'audio/mp4', aac: 'audio/aac',
  amr: 'audio/amr', wav: 'audio/wav', jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', webp: 'image/webp' };
const conv = String(e.chatwootConversationId || 'sem-conversa').replace(/[^0-9A-Za-z_-]/g, '');
const msg = String(e.msgId || Date.now()).replace(/[^0-9A-Za-z_-]/g, '');
const out = [];
for (const a of e.anexos || []) {
  if (!a.baixar) continue;
  const ext = a.ext && MIME[a.ext] ? a.ext : PADRAO[a.tipo];
  // tipo base sem parâmetros ("audio/ogg; codecs=opus" → "audio/ogg"): o bucket só aceita a lista da 0145.
  const base = String(a.mime || '').split(';')[0].trim().toLowerCase();
  const mime = Object.values(MIME).includes(base) ? base : MIME[ext];
  out.push({ json: { n: a.n, tipo: a.tipo, url: a.url, ext, mime, tamanho: a.tamanho,
    caminho: `mari/${conv}/${msg}_${a.n}.${ext}`, transcrever: a.tipo === 'audio' && !a.cw_transcricao } });
}
return out;
