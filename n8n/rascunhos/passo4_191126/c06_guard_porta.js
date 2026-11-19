// NIOGEN | n8n/rascunhos/passo4_191126/c06_guard_porta.js — RASCUNHO do nó "6h · Guard Chatwoot" do mari_cadencia (19/11/2026)
// Fase 2, passo 4: antes de qualquer envio real a cadência pergunta ao BANCO "pode falar?" (RPC mari_pode_falar com
// p_para = 'lembrete' e o passo), em vez de reler a conversa no Chatwoot (nó 6g). O banco já aplica as regras de hoje
// (n8n/cadencia/c06_guard.js): aviso da venda sai sempre (só Não contatar e Saída barram) e nunca para a escada; o resto só em
// "Mari atendendo" sem dono. Sem resposta do banco → não envia (vira falha, não queima o passo), como hoje sem o Chatwoot.
// Saída igual à de hoje: { parar, enviar, humano, time, resolvida, naoContatar, daVenda } (o 6p · Supabase parar lê esses campos).
const m = $('5 · Montar envio').first().json;
const r = $input.first().json || {};
const PASSOS_VENDA = ['INSTALACAO', 'VESPERA', 'CARTAO', 'CARTAO2', 'BIO1', 'BIOVOLTA'];
const daVenda = PASSOS_VENDA.includes(String(m.passo || ''));
if (typeof r.pode !== 'boolean') {
  return [{ json: { ...m, parar: false, enviar: false, ok: false, erro: 'banco sem resposta (pode falar?) — não enviado' } }];
}
const naoContatar = !!r.nao_contatar;
const humano = !!r.pessoa;
const time = !!r.time;
const parar = daVenda ? false : !!r.parar;
const resolvida = parar && !humano && !time && !naoContatar;   // "parou pela situação" (Saída, instalada…): o 6p registra como hoje
if (!r.pode && !parar) {
  return [{ json: { ...m, parar: false, enviar: false, ok: false, humano, time, resolvida, naoContatar, daVenda, situacao: r.situacao || null,
    erro: 'não enviado: ' + (r.motivo || 'banco') } }];
}
return [{ json: { ...m, parar, enviar: !!r.pode && !parar, humano, time, resolvida, naoContatar, daVenda, situacao: r.situacao || null,
  motivo: r.motivo || null } }];
