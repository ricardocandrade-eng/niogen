// NIOGEN | n8n/mari/nE1_log_erro.js — nó "E1 · Log erro" do mari_principal (04/11/2026)
// Error Trigger do próprio workflow → mari_erros (espelho do "Log Erro" da Renata).
// O lock da conversa expira sozinho (TTL 45 s).
const e = $input.first().json || {};
const exec = e.execution || {};
return [{ json: { erroPayload: {
  no_n8n: exec.lastNodeExecuted || 'desconhecido',
  mensagem: String(exec.error?.message || 'erro sem mensagem').slice(0, 2000),
  payload: { execution_id: exec.id || null, workflow: e.workflow?.name || null, modo: exec.mode || null },
} } }];
