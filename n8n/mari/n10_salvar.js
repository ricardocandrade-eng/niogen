// NIOGEN | n8n/mari/n10_salvar.js — nó "10 · Salvar turno" do mari_principal (04/11/2026)
// Monta o corpo do mari_salvar_turno (fala da Mari em mari_turnos + atualizações em mari_conversas +
// erro em mari_erros + libera o lock). O handoff (nó 9) roda DEPOIS, para ler os dados já gravados.
const r = $input.first().json;
const body = {
  p_conversa: r.conversaId,
  p_texto: r.texto || '',
  p_tags: r.tags || null,
  p_modelo: r.modelo || null,
  p_tokens_in: r.tokensIn ?? null,
  p_tokens_out: r.tokensOut ?? null,
  p_latencia_ms: r.latenciaMs ?? null,
  p_upd: r.upd || {},
  p_papel: 'mari',
  p_erro: r.erro || null,
};
return [{ json: { body, r, temHandoff: Boolean(r.handoff) } }];
