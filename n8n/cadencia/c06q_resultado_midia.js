// NIOGEN | n8n/cadencia/c06q_resultado_midia.js — nó "6q · Resultado mídia" do mari_cadencia (12/11/2026, 0146)
// A mídia saiu → item no formato que o 7r espera (id + status), a cutucada conta como enviada. Não saiu → volta o item da cutucada
// para o "7 · Chatwoot enviar" (texto, como sempre). O erro já foi gravado pelo mari_midia_envio.
const m = $('6m · Mídia?').first().json;
const r = $input.first().json || {};
if (r.ok) return [{ json: { id: r.wamid || 'whatsapp', status: 'sent', midiaOk: true } }];
const { pedidoMidia, ...resto } = m;
return [{ json: { ...resto, midiaOk: false } }];
