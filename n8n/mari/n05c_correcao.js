// NIOGEN | n8n/mari/n05c_correcao.js — nó "5c · Pedido de correção" do mari_principal (04/11/2026)
// O filtro de saída (nó 7) bloqueou a 1ª resposta. Reenvia a mesma conversa ao Claude com a resposta
// bloqueada e um aviso técnico do que violou. Uma tentativa só; se insistir, o nó 7r manda o fallback.
const m = $('5b · Motor').first().json;
const r = $input.first().json;
const aviso = '[AVISO INTERNO DO SISTEMA — não é mensagem do cliente] A sua última resposta não pode ser enviada porque '
  + r.violacoes.join('; ')
  + '. Reescreva a MESMA resposta para o cliente, com o mesmo conteúdo e as mesmas tags técnicas no final, corrigindo só isso. Não comente este aviso.';
return [{ json: {
  model: m.model, maxTokens: m.maxTokens, system: m.system,
  messages: [...m.messages, { role: 'assistant', content: r.textoRuim }, { role: 'user', content: aviso }],
} }];
