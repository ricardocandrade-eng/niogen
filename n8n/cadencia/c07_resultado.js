// NIOGEN | n8n/cadencia/c07_resultado.js — nó "7r · Resultado" do mari_cadencia (04/11/2026)
// Lê a resposta do POST no Chatwoot: ok só com id da mensagem e status ≠ 'failed' (a Meta recusou).
// Nó 7 desligado → chega o próprio item montado (sem id) → falha registrada, passo não queima.
const g = $('6h · Guard Chatwoot').first().json;
const r = $input.first().json || {};
const ok = !!r.id && r.status !== 'failed' && !r.conversaId;
return [{ json: { ...g, ok, erro: ok ? null : (r.error || r.message || `chatwoot sem id (status=${r.status || 'nenhum'})`) } }];
