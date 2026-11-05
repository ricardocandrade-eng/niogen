// NIOGEN | n8n/mari/n12a_baloes.js — nó "12a · Balões" do mari_principal (04/11/2026, prompt v3)
// Um item por balão (a Mari separa com "||"; o 7 · Extrair corta em até 3). O laço 12b → 12w → 12c manda um
// por vez, com o atraso antes de cada um (≈ 1 s a cada 60 caracteres, mínimo 2 s, máximo 6 s — proposta de tom §5).
// Resposta sem "||" (v2, mídia, despedida de segurança) = um balão só, como antes.
const j = $input.first().json;
const baloes = Array.isArray(j.baloes) && j.baloes.length ? j.baloes : (j.resposta ? [j.resposta] : []);
const atrasos = Array.isArray(j.atrasos) ? j.atrasos : [];
return baloes.map((conteudo, i) => ({ json: {
  conteudo,
  atraso: atrasos[i] || Math.min(6, Math.max(2, Math.round(conteudo.length / 60))),
  ordem: i + 1,
  total: baloes.length,
  chatwootConversationId: j.chatwootConversationId,
  config: j.config,
} }));
