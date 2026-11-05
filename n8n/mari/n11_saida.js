// NIOGEN | n8n/mari/n11_saida.js — nó "11 · Saída" do mari_principal (04/11/2026)
// Ponto único de saída de todos os caminhos. Monta o corpo devolvido pela rota de teste
// (modo 'teste') ou a mensagem a enviar pelo Chatwoot (modo 'chatwoot').
const ex = (n) => { try { return $(n).isExecuted; } catch (e) { return false; } };
const j = $input.first().json || {};
const e = ex('2 · Entrada') ? ($('2 · Entrada').first().json || {}) : {};

let saida;
if (j.saida) {
  saida = j.saida;
} else if (ex('2r · Supabase registrar calado')) {
  saida = { ...(($('2h · Guard humano').first().json || {}).saida || { silencio: true }), registrado: j.ignorado === false };
} else if (ex('10b · Supabase salvar turno')) {
  const s = $('10 · Salvar turno').first().json;
  const r = s.r || {};
  const h = ex('9 · Handoff') ? $('9 · Handoff').first().json : null;
  saida = {
    resposta: r.texto,
    conversa_id: r.conversaId,
    etapa: r.handoff ? 'handoff' : (r.upd && r.upd.etapa) || null,
    handoff: r.handoff ? { motivo: r.handoff.motivo, ...(h || {}) } : null,
    tags: r.tags || {},
    upd: r.upd || {},
    modelo: r.modelo,
    tokens_in: r.tokensIn, tokens_out: r.tokensOut, latencia_ms: r.latenciaMs,
    corrigido: r.violacoesCorrigidas || null,
    erro: r.erro ? r.erro.mensagem : null,
    prompt: r.promptVersao || null,
    // Balões (v3, "||"): o envio pelo Chatwoot manda um por vez, com o atraso antes de cada um
    // (≈ 1 s a cada 60 caracteres, mínimo 2 s, máximo 6 s — proposta de tom §5).
    baloes: (Array.isArray(r.baloes) && r.baloes.length ? r.baloes : (r.texto ? [r.texto] : [])),
    emoji_ajustes: r.emojiAjustes || null,
  };
  saida.atrasos = saida.baloes.map((b) => Math.min(6, Math.max(2, Math.round(b.length / 60))));
} else if (ex('7f · Supabase abortar')) {
  saida = { abortado: true, motivo: 'mensagem nova chegou durante a resposta — a execução mais nova responde' };
} else if (j.esgotado) {
  saida = { erro: 'conversa ocupada por mais de 45 s (lock)' };
} else if (j.silencio === true && j.conversa_id) {
  saida = { silencio: true, status: j.status, conversa_id: j.conversa_id, motivo: 'conversa em handoff — o humano conduz' };
} else if (j.resultado) {
  saida = { resultado: j.resultado, status: j.status || null };
} else {
  saida = { erro: 'saída não identificada' };
}

// Quem decide o caminho de saída é o GATILHO, não o modo: execução da rota de teste sempre responde
// pelo 12t (inclusive os comandos admin com o modo em 'chatwoot'); execução do Chatwoot envia pelo 12c.
return [{ json: {
  modo: ex('1 · Webhook Mari teste') ? 'teste' : 'chatwoot',
  saida,
  resposta: saida.resposta || '',
  baloes: saida.baloes || (saida.resposta ? [saida.resposta] : []),
  atrasos: saida.atrasos || (saida.resposta ? [2] : []),
  chatwootConversationId: e.chatwootConversationId || null,
  config: e.config || {},
} }];
