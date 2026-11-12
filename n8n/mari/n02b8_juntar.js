// NIOGEN | n8n/mari/n02b8_juntar.js — nó "2b8 · Juntar mídia" do mari_principal (12/11/2026, 0145)
// docs/Prompt_midia_transcricao_121126_0230.md. Junta o que a cadeia 2b fez (subida no bucket, link curto para o Claude,
// transcrição) numa entrada só, que segue o fluxo normal (2z → … → 3a / 2r gravam a lista em mari_turnos.midia).
//   · Áudio transcrito: a marca [MIDIA:audio] vira "🎤 (áudio) <transcrição>" e o turno passa pela IA (sai do soMidia).
//   · Sem transcrição (credencial desligada, erro, vazio): a marca fica → 2c responde a frase fixa e grava o erro.
//   · Foto: o texto segue "[Imagem enviada pelo cliente]"; o link url_ia (15 min) leva a foto ao Claude no 5b.
// Nada aqui derruba a entrada: qualquer falha vira "erro" no item da mídia e a mensagem segue.
const e = $('2 · Entrada').first().json;
const pega = (n) => { try { return $(n).isExecuted ? $(n).all() : []; } catch (x) { return []; } };
const itens = pega('2b · Anexos').map((i) => i.json);
const subidas = pega('2b2 · Subir mídia').map((i) => i.json || {});
const links = pega('2b3 · Link IA').map((i) => i.json || {});
const trans = pega('2b7 · Transcrever').map((i) => i.json || {});
const SB = 'https://zlrfwbkblytnokuexjti.supabase.co';
const agora = new Date();
const errDe = (j) => (j && j.error ? String(j.error.message || j.error.description || j.error).slice(0, 200) : null);

const porN = {};
itens.forEach((it, i) => {
  const up = subidas[i] || {};
  const lk = links[i] || {};
  const okUp = !errDe(up) && !!(up.Key || up.Id || up.key || up.id);
  const r = { caminho: okUp ? it.caminho : null, erro: okUp ? null : `não subiu: ${errDe(up) || 'sem resposta'}` };
  if (okUp && it.tipo === 'imagem' && lk.signedURL) {
    r.url_ia = `${SB}/storage/v1${lk.signedURL}`;
    r.url_ia_ate = new Date(agora.getTime() + 14 * 60000).toISOString();
  }
  porN[it.n] = r;
});
// Transcrições: na ordem dos áudios marcados para transcrever (o filtro 2b5 mantém a ordem).
const aTrans = itens.filter((it) => it.transcrever);
aTrans.forEach((it, i) => {
  const t = trans[i];
  const r = porN[it.n];
  // Nó 2b7 desligado (sem a credencial) passa o item adiante sem "text": conta como desligada, não como vazia.
  if (!t || (!errDe(t) && !Object.prototype.hasOwnProperty.call(t, 'text'))) { r.erro = r.erro || 'transcrição desligada (sem a credencial "Transcrição Nio")'; return; }
  const txt = String(t.text || '').trim();
  if (errDe(t)) r.erro = `transcrição falhou: ${errDe(t)}`;
  else if (!txt) r.erro = 'transcrição vazia';
  else { r.transcricao = txt.slice(0, 4000); r.transcrito_em = agora.toISOString(); r.transcrito_por = 'openai'; }
});

const midia = (e.anexos || []).map((a) => {
  const r = porN[a.n] || {};
  const m = { tipo: a.tipo, mime: a.mime, ext: a.ext, tamanho: a.tamanho, caminho: r.caminho || null };
  if (a.tipo === 'audio') {
    if (a.cw_transcricao) { m.transcricao = a.cw_transcricao.slice(0, 4000); m.transcrito_em = agora.toISOString(); m.transcrito_por = 'chatwoot'; }
    else if (r.transcricao) { m.transcricao = r.transcricao; m.transcrito_em = r.transcrito_em; m.transcrito_por = r.transcrito_por; }
  }
  if (r.url_ia) { m.url_ia = r.url_ia; m.url_ia_ate = r.url_ia_ate; }
  if (r.erro) m.erro = r.erro;
  else if (!a.baixar && ['audio', 'imagem'].includes(a.tipo)) m.erro = 'não baixado (maior que 16 MB ou sem link)';
  return Object.fromEntries(Object.entries(m).filter(([, v]) => v !== null && v !== undefined));
});

// Texto do turno: cada áudio transcrito no lugar da marca (ou numa linha a mais, se o cliente também escreveu).
let texto = String(e.texto || '');
for (const m of midia.filter((x) => x.tipo === 'audio' && x.transcricao)) {
  const linha = `🎤 (áudio) ${m.transcricao}`;
  if (/\[MIDIA:(audio|voice)\]/i.test(texto)) texto = texto.replace(/\[MIDIA:(audio|voice)\]/i, linha);
  else texto = [texto, linha].filter(Boolean).join('\n');
}

const { anexos, ...resto } = e;
return [{ json: { ...resto, texto, midia: midia.length ? midia : null } }];
