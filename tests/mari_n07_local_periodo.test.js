// NIOGEN | tests/mari_n07_local_periodo.test.js | 21/11/2026 — Claude Code / Opus 5.5 (conversas L-236 e L-217)
// Sem API: node tests/mari_n07_local_periodo.test.js n8n/mari/n07_extrair.js
// O período (Manhã · Tarde · Tanto faz) que o cliente responde fica gravado pelo próprio código, sem depender da marca do modelo.
// L-236: a lista de unidades chegou depois do período; o modelo perguntou a unidade e não emitiu o período → o sistema colou
//        "E qual período você prefere nesse dia?" de novo. L-217: "Manhã" antes do nome → as 2 falas seguintes perguntaram o período.
const fs = require('fs');
const assert = require('assert');
const code = fs.readFileSync(process.argv[2] || 'n8n/mari/n07_extrair.js', 'utf8');
const PLANOS = [
  { codigo: 'V-REG-FIBRA', nome: 'Nio Fibra 600 Mega', portfolio: 'varejo', variante: 'regular', preco: '110.00', preco_cartao: '95', velocidade_mb: 600, taxa_habilitacao: '540', isencao_meses: 12, wifi: 'Wi-Fi 6' },
];
const BASE = { id: 'c1', etapa: 'coleta', cidade: 'Juiz de Fora', cep: '36035130', numero: '123', complemento: null, elegibilidade: 'ok', status: 'ativo',
  plano_escolhido: 'V-REG-FIBRA', forma_pagamento: 'boleto', lgpd_enviada: true,
  dados: { telefone: '32999999999', telefone_confirmado: true, nome: 'Ana Teste', cpf: '52998224725', email: 'ana@gmail.com', complemento_ok: true } };
function rodar(bruto, conv, hist, msg) {
  const c = Object.assign({}, BASE, conv || {}, { dados: Object.assign({}, BASE.dados, (conv || {}).dados || {}) });
  const nodes = {
    '5b · Motor': { ctx: { conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', dentroHorario: true,
      planos: PLANOS, segmento: 'varejo', condicoesEnviadas: true, conversa: c } },
    '4 · Preparar': { consolidado: { mensagem: msg, historico: hist || [] } },
    '2 · Entrada': { modo: 'teste' },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const $input = { first: () => ({ json: { content: [{ type: 'text', text: bruto }], usage: {}, stop_reason: 'end_turn' } }) };
  return new Function('$', '$input', '$json', '$runIndex', code)($, $input, {}, 0)[0].json;
}
const tudo = (r) => [r.texto || '', ...((r.baloes) || []), (r.interativo || {}).corpo || ''].join('\n');
const PERG_PER = /qual per[ií]odo|per[ií]odo voc[eê] prefere/i;
const pref = (r) => String((r.upd || {}).instalacao_preferencia || '');
let falhas = 0;
function caso(nome, f) {
  try { f(); console.log(`ok  ${nome}`); } catch (e) { falhas++; console.log(`FALHOU  ${nome}: ${e.message}`); }
}
const DATA = { dados: { instalacao_data: 'Seg, 23/11' } };
const H_TURNO = [{ papel: 'mari', texto: 'E qual período você prefere nesse dia?\n\n[botões: Manhã / Tarde / Tanto faz]' }];
const LISTA = ['Apartamento 101', 'Apartamento 102', 'Apartamento 201'];
const UNID = { cobertura_detalhe: { portal: 'viavel', unidade_a_confirmar: true, unidades: LISTA },
  unidade_conferir: { motivo: 'escolher', lista: LISTA }, unidade_conferir_em: new Date().toISOString(), nio_viab_resultado: 'viavel' };
const FALA_UNID = 'Ah, e no cadastro da Nio o seu endereço aparece com algumas unidades diferentes — qual destas é a sua?\n\n'
  + 'Apartamento 101, 102 ou 201\n\nSe não for nenhuma dessas, me fala também 😊';

caso('L-236: "Manhã" e a lista de unidades na mesma fala → período gravado, sem a pergunta do período de novo', () => {
  const r = rodar(FALA_UNID, Object.assign({}, DATA, UNID), H_TURNO, 'Manhã');
  const t = tudo(r);
  assert.ok(/manh/i.test(pref(r)), `período não gravado: ${pref(r)}`);
  assert.ok(/23\/11/.test(pref(r)), `a data escolhida não foi junto: ${pref(r)}`);
  assert.ok(!PERG_PER.test(t), `perguntou o período de novo: «${t.slice(-200)}»`);
  assert.ok(!r.interativo || r.interativo.chave !== 'turno', 'botões de período de novo');
  assert.ok(/Apartamento 101/.test(t), 'a pergunta da unidade sumiu');
});
caso('L-217: "Manhã" antes do nome (a Mari pediu o nome) → período gravado, a fala do nome não pergunta o período', () => {
  const hist = [{ papel: 'mari', texto: 'Só falta o seu nome completo, pode me mandar?' }];
  const r = rodar('Anotado! E o seu nome completo, pode me mandar?', Object.assign({}, DATA, { dados: { instalacao_data: 'Seg, 23/11', nome: null } }), hist, 'Manhã');
  assert.ok(/manh/i.test(pref(r)), `período não gravado: ${pref(r)}`);
  assert.ok(!r.interativo || r.interativo.chave !== 'turno', 'botões de período');
});
caso('"Tanto faz" logo depois da pergunta do período → grava "tanto faz"', () => {
  const r = rodar('Combinado!', DATA, H_TURNO, 'Tanto faz');
  assert.ok(/tanto faz/i.test(pref(r)), `período não gravado: ${pref(r)}`);
});
caso('"Tanto faz" depois da pergunta da DATA não é período', () => {
  const h = [{ papel: 'mari', texto: 'Qual destas datas você prefere para a instalação?\n\n[botões: Seg, 23/11 / Ter, 24/11 / Qua, 25/11]' }];
  const r = rodar('Combinado, qualquer dia então.', {}, h, 'Tanto faz');
  assert.ok(!/tanto faz/i.test(pref(r)), `gravou "tanto faz" como período: ${pref(r)}`);
});
caso('"Manhã" sem data e sem a pergunta do período → não grava (a Mari ainda pergunta a data)', () => {
  const r = rodar('Anotado!', {}, [{ papel: 'mari', texto: 'Como você quer pagar?' }], 'Manhã');
  assert.ok(!pref(r), `gravou período sem data: ${pref(r)}`);
});
caso('o modelo emitiu o período → vale o do modelo', () => {
  const r = rodar('Perfeito, de tarde então!\n[DADOS_COLETADOS: instalacao=tarde]', DATA, H_TURNO, 'Tarde');
  assert.ok(/tarde/i.test(pref(r)) && /23\/11/.test(pref(r)), `período: ${pref(r)}`);
});
caso('"de manhã, por favor" depois da pergunta do período → grava manhã', () => {
  const r = rodar('Fechado!', DATA, H_TURNO, 'De manhã, por favor');
  assert.ok(/manh/i.test(pref(r)), `período não gravado: ${pref(r)}`);
});
caso('a pergunta da unidade não ganha os botões de data/período colados (período ainda não respondido)', () => {
  const r = rodar(FALA_UNID, UNID, [{ papel: 'mari', texto: 'Fechado, boleto então.' }], 'Ok');
  const t = tudo(r);
  assert.ok(!r.interativo || !['turno', 'data'].includes(r.interativo.chave), `botões ${r.interativo && r.interativo.chave} colados na pergunta da unidade`);
  assert.ok(!PERG_PER.test(t) && !/qual destas datas/i.test(t), `pergunta de data/período colada: «${t.slice(-200)}»`);
});
console.log(falhas ? `\n${falhas} falha(s)` : '\ntudo ok');
process.exit(falhas ? 1 : 0);
