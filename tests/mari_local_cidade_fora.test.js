// NIOGEN | tests/mari_local_cidade_fora.test.js | 24/11/2026 — Claude Code / Opus 5.5 (conversa L-276, Nelma, #241)
// Sem API: node tests/mari_local_cidade_fora.test.js
// Confere, rodando o código do nó "5b · Motor" como o n8n roda: sem cidade resolvida pelo CEP, o estado leva a lista das
// cidades atendidas e a ordem de encerrar (fora_de_area) quando o cliente diz uma cidade fora dela — sem pedir CEP. A linha
// abertura_pediu_cidade não manda mais pedir o CEP. Com a cidade já resolvida (cluster) ou já fora da área, a lista não vai.
const fs = require('fs');
const assert = require('assert');
const MOTOR = fs.readFileSync('n8n/mari/n05b_motor.js', 'utf8').replace('__MODELO__', "'modelo-teste'").replace('__HIST_MAX__', '30');

function motor(msg, conv, db = {}) {
  const nodes = {
    '4b · Supabase contexto': Object.assign({ conversa: Object.assign({ id: 'c1', status: 'ativo', etapa: 'abertura',
      dados: { abertura: 'b3_191126', abertura_botao: 'planos', abertura_pediu_cidade: true } }, conv), planos: [] }, db),
    '4 · Preparar': { consolidado: { mensagem: msg, historico: [{ papel: 'lead', texto: 'Oi' }, { papel: 'mari', texto: 'Me diz a sua cidade' }], n_mensagens: 1 } },
    '5a · Conteúdo Mari': { promptVersao: 'mari_v7', promptBase: 'base' },
    '4c · Supabase interativo': { cartoes: [], textos: { abertura_versao: 'b3_191126', abertura_formato: 'botoes' },
      cidades: [{ cidade: 'Contagem', cluster: 'regular' }, { cidade: 'Juiz de Fora', cluster: 'regular' }, { cidade: 'Ipatinga', cluster: 'btu' }],
      planos_cidade: {} },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  return new Function('$', '$input', '$json', '$runIndex', '$getWorkflowStaticData', MOTOR)($, { first: () => ({ json: {} }) }, {}, 0, () => ({}))[0].json;
}

// 1. L-276: "Cabo Frio no pêro" depois do pedido da cidade → vai ao Claude com a lista e a ordem de encerrar, sem "peça o CEP".
const r1 = motor('Cabo Frio no pêro', {});
const e1 = String((r1.ctx || {}).estado || '');
assert.ok(!r1.fixo || !r1.fixo.texto, 'cidade fora não deve virar texto fixo');
assert.match(e1, /cidades_atendidas: Contagem, Juiz de Fora, Ipatinga/, 'lista das cidades atendidas no estado');
assert.match(e1, /NÃO peça CEP/, 'ordem de não pedir CEP');
assert.match(e1, /handoff fora_de_area com \[ELEGIBILIDADE: fora_area\]/, 'ordem de encerrar como fora_de_area');
const linhaAb = e1.split('\n').find((l) => l.startsWith('abertura_pediu_cidade')) || '';
assert.ok(linhaAb && !/peça o CEP/.test(linhaAb), `abertura_pediu_cidade ainda manda pedir o CEP: ${linhaAb}`);

// 2. Já fora da área pelo CEP → a lista não vai (o INTERNAL DATA já manda encerrar).
const e2 = String((motor('oi', { dentro_area: false, cidade: 'Cabo Frio', cep: '28900000' }).ctx || {}).estado || '');
assert.ok(!/cidades_atendidas/.test(e2), 'com dentro_area=false a lista não deve ir');

console.log('ok — mari_local_cidade_fora (2 casos)');
