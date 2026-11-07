// NIOGEN | n8n/mari/n12v_interativo_resultado.js — nó "12v · Resultado interativo" do mari_principal (06/11/2026, Mari v7)
// Enviou (a Graph API devolveu o id da mensagem) → NOTA PRIVADA no Chatwoot com o que a Mari mandou ("🤖 Mari enviou …").
// Falhou (erro da Meta, imagem fora do ar…) → manda a LISTA/PERGUNTA EM TEXTO pelo Chatwoot (público) e registra em mari_erros
// (spec §1: "Carrossel falhou → lista em texto do Passo 3 + mari_erros"). Nada de token ou dado de cliente no log.
const m = $('12y · Montar interativo').first().json;
const r = $input.first().json || {};
const id = r.messages && r.messages[0] && r.messages[0].id;
const ok = !!id;
const erroMeta = ok ? null : String((r.error && (r.error.message || r.error.error_user_msg)) || r.message || JSON.stringify(r).slice(0, 300));

return [{ json: {
  ok,
  conteudo: ok ? m.nota : (m.fallbackTexto || ''),
  privada: ok,
  chatwootConversationId: m.chatwootConversationId,
  config: m.config,
  erroPayload: ok ? null : {
    conversa_id: m.conversaId, no_n8n: '12z · WABA enviar',
    mensagem: `interativo (${m.tipo}) não enviado: ${erroMeta}`,
    payload: { tipo: m.tipo, codigo: r.error && r.error.code, subcodigo: r.error && r.error.error_subcode },
  },
} }];
