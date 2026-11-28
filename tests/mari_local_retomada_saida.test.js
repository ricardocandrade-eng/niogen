// NIOGEN | tests/mari_local_retomada_saida.test.js | 28/11/2026 — Claude Code / Fable 5.2 (casos L-132 e L-82)
// Sem API: node tests/mari_local_retomada_saida.test.js
// Ricardo, 28/11: "acho que ela poderia retomar a conversa, lendo todo o contexto e seguindo com o atendimento normal novamente e
// encaminhar para o time quando encerrado a parte dela". Em Saída definitiva de venda que não saiu (crédito negado, biometria
// reprovada) a Mari volta a responder (migration 0443). Confere, rodando o código dos nós como o n8n roda:
//  - "5b · Motor": o estado leva o RESUMO DO CASO (motivo, data, o que travou) e as três proibições; nas outras Saídas nada muda;
//  - "7 · Extrair": prometer abrir/reabrir pedido ou mandar [CONDICOES] nessa situação vira correção (trava do código, não do prompt).
const fs = require('fs');
const assert = require('assert');
const MOTOR = fs.readFileSync('n8n/mari/n05b_motor.js', 'utf8').replace('__MODELO__', "'modelo-teste'").replace('__HIST_MAX__', '30');
const EXTRAIR = fs.readFileSync('n8n/mari/n07_extrair.js', 'utf8');
const BASE = { id: 'c1', status: 'ativo', etapa: 'retomada', cidade: 'Juiz de Fora', uf: 'MG', cep: '36051400', numero: '811', cluster: 'regular',
  dentro_area: true, elegibilidade: 'ok', plano_escolhido: 'V-800', cobertura_decisao: 'viavel',
  dados: { nome: 'Ligia Teste', cpf: '52998224725', email: 'a@b.com' } };
const HIST = [{ papel: 'lead', texto: 'Não tenho cartão de crédito não' }, { papel: 'humano', texto: 'Não aprovou na Nio com boleto' }];

function motor(msg, conv) {
  const nodes = {
    '4b · Supabase contexto': { conversa: Object.assign({}, BASE, conv), planos: [] },
    '4 · Preparar': { consolidado: { mensagem: msg, historico: HIST, n_mensagens: 1 } },
    '5a · Conteúdo Mari': { promptVersao: 'mari_v7', promptBase: 'base' },
    '4c · Supabase interativo': { cartoes: [], textos: {}, cidades: [{ cidade: 'Juiz de Fora', cluster: 'regular' }], planos_cidade: {} },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const r = new Function('$', '$input', '$json', '$runIndex', '$getWorkflowStaticData', MOTOR)($, { first: () => ({ json: {} }) }, {}, 0, () => ({}))[0].json;
  return String((r.ctx || {}).estado || '');
}
function extrair(bruto, conv, msg) {
  const nodes = {
    '5b · Motor': { ctx: { conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', dentroHorario: true, planos: [],
      conversa: Object.assign({}, BASE, conv) } },
    '4 · Preparar': { consolidado: { mensagem: msg || 'esse plano da nio o chip é da tim?', historico: HIST } },
    '2 · Entrada': { modo: 'chatwoot' },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const $input = { first: () => ({ json: { content: [{ type: 'text', text: bruto }], usage: {}, stop_reason: 'end_turn' } }) };
  return new Function('$', '$input', '$json', '$runIndex', EXTRAIR)($, $input, {}, 0)[0].json;
}
const NEGADO = { funil_destino: 'credito_negado', saida_motivo: 'credito_negado', saida_em: '2026-11-17T01:02:37Z', credito_resultado: 'aprovado_cartao', credito_formas: ['cartao'] };
let falhas = 0;
function caso(nome, f) { try { f(); console.log(`ok  ${nome}`); } catch (e) { falhas++; console.log(`FALHOU  ${nome}: ${e.message}`); } }
const minha = (r) => (r.violacoes || []).filter((x) => /retomada/.test(x));

caso('motor: crédito negado leva o resumo do caso e as proibições', () => {
  const e = motor('esse plano da nio o chip é da tim?', NEGADO);
  const l = e.split('\n').find((x) => x.startsWith('retomada_saida')) || '';
  assert.ok(l, 'sem a linha retomada_saida no estado');
  assert.match(l, /Crédito negado/); assert.match(l, /16\/11/, 'data da Saída em hora de Brasília');
  assert.match(l, /só (aprovou )?no cartão/i, 'o que travou');
  assert.match(l, /NÃO diga que vai abrir/); assert.match(l, /NÃO aceite como fato/); assert.match(l, /\[CONDICOES\]/);
  assert.match(l, /responda/i); assert.match(l, /\[HANDOFF\] pedido_humano/);
  assert.ok(!/situacao_lead/.test(e), 'a instrução antiga (resposta curta) não deve ir junto');
});
caso('motor: biometria reprovada também retoma', () => {
  const e = motor('oi', { funil_destino: 'reprovado_biometria', saida_motivo: 'reprovado_biometria', saida_em: '2026-11-20T15:00:00Z' });
  assert.match(e, /^retomada_saida.*biometria/im);
});
caso('motor: outras Saídas seguem com a instrução de antes', () => {
  const e = motor('qual o valor', { funil_destino: 'recusou', saida_motivo: 'recusou' });
  assert.match(e, /situacao_lead/); assert.ok(!/retomada_saida/.test(e));
});
caso('extrair: "vou tentar abrir o seu pedido agora" vira correção', () => {
  const r = extrair('Entendi, Ligia! Vou tentar abrir o seu pedido agora.', NEGADO, 'o outro foi dado baixa');
  assert.ok(r.corrigir, 'não pediu correção'); assert.ok(minha(r).length, `violações: ${JSON.stringify(r.violacoes)}`);
});
caso('extrair: "já reabro seu pedido" vira correção', () => {
  const r = extrair('Que bom! Já reabro seu pedido por aqui.', NEGADO);
  assert.ok(r.corrigir && minha(r).length, `violações: ${JSON.stringify(r.violacoes)}`);
});
caso('extrair: [CONDICOES] na retomada vira correção', () => {
  const r = extrair('Olha as condições do seu plano:\n[CONDICOES]', NEGADO);
  assert.ok(r.corrigir && minha(r).length, `violações: ${JSON.stringify(r.violacoes)}`);
});
caso('extrair: resposta de produto passa', () => {
  const r = extrair('A linha de celular do combo usa a rede da TIM, Ligia 😊 Ficou alguma dúvida?', NEGADO);
  assert.ok(!minha(r).length, `violações: ${JSON.stringify(r.violacoes)}`);
});
caso('extrair: passar ao time passa', () => {
  const r = extrair('Vou chamar o nosso time pra conferir isso com você 💚\n[HANDOFF]\nmotivo_handoff: pedido_humano\nbriefing_humano: "RESUMO: cliente diz que o outro pedido foi baixado. SUGESTÃO: conferir no portal."\n[/HANDOFF]', NEGADO, 'o outro foi dado baixa');
  assert.ok(!minha(r).length, `violações: ${JSON.stringify(r.violacoes)}`);
});
caso('extrair: fora da retomada a trava não vale', () => {
  const r = extrair('Vou tentar abrir o seu pedido agora.', { funil_destino: 'em_andamento' });
  assert.ok(!minha(r).length, `violações: ${JSON.stringify(r.violacoes)}`);
});
if (falhas) { console.log(`\n${falhas} falha(s)`); process.exit(1); }
console.log('ok — mari_local_retomada_saida (9 casos)');
