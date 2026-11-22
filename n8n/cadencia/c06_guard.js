// NIOGEN | n8n/cadencia/c06_guard.js — nó "6h · Guard Chatwoot" do mari_cadencia (04/11/2026; porta 21/11/2026)
// 21/11 (fase 2, passo 4 — 0346): antes de QUALQUER envio real, pergunta ao BANCO "pode falar?" (nó 6g, RPC mari_pode_falar com
// p_para 'lembrete' e o passo), que responde pela situação do lead: pessoa ou time na conversa, não contatar, Saída → para a escada
// (mari_cadencia_parar) e não envia; aviso da venda (INSTALACAO, VESPERA, CARTAO…) sai mesmo com o time e nunca para a escada.
// Sem resposta do banco → NÃO envia: vira falha (não queima o passo). Ricardo, 21/11: "Sim, fica calada".
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
