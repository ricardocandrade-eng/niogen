// NIOGEN | n8n/cadencia/c06_guard.js — nó "6h · Guard Chatwoot" do mari_cadencia (04/11/2026)
// Antes de QUALQUER envio real, relê a conversa no Chatwoot (padrão noF1 da Renata):
// humano atribuído, time atribuído, conversa resolvida ou etiqueta nao-contatar → para a escada (mari_cadencia_parar) e não envia.
// Sem resposta do Chatwoot (nó 6g desligado ou erro) → NÃO envia: vira falha (não queima o passo).
const m = $('5 · Montar envio').first().json;
const cw = $input.first().json || {};
const temDados = cw && (cw.id !== undefined || cw.status !== undefined) && !cw.conversaId;

if (!temDados) {
  return [{ json: { ...m, parar: false, enviar: false, ok: false, erro: 'guard do Chatwoot sem resposta (nó desligado ou erro) — não enviado' } }];
}
const humano = !!(cw.meta && cw.meta.assignee) || !!cw.assignee_id;
const time = !!cw.team_id || !!(cw.meta && cw.meta.team);
const resolvida = cw.status === 'resolved';
const naoContatar = Array.isArray(cw.labels) && cw.labels.includes('nao-contatar');   // adendo 2 (05/11): não tocar
const parar = humano || time || resolvida || naoContatar;
return [{ json: { ...m, parar, enviar: !parar, humano, time, resolvida, naoContatar } }];
