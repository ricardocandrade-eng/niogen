// NIOGEN | tests/mari_local_complemento_depois.test.js | 21/11/2026 — Claude Code / Opus 5.5 (teste L-236; Ricardo: "primeiro ela olha")
// Sem API: node tests/mari_local_complemento_depois.test.js
// O complemento não se pergunta mais logo depois do endereço: o "Sim" da confirmação basta para os planos; a consulta da Nio diz a
// hora (com unidades → mostra as opções; sem lista → pergunta o complemento; não voltou → antes do resumo).
//   7 · Extrair — o "Sim" da confirmação grava dados.endereco_ok; a etapa segue aos planos sem complemento; o resumo exige o complemento.
//   5b · Motor — a linha complemento_agora (LISTA · SIM · DEPOIS) e o complemento em dados_faltando.
const fs = require('fs');
const assert = require('assert');
const MOTOR = fs.readFileSync('n8n/mari/n05b_motor.js', 'utf8').replace('__MODELO__', "'modelo-teste'").replace('__HIST_MAX__', '30');
const EXTRAIR = fs.readFileSync('n8n/mari/n07_extrair.js', 'utf8');
const PLANOS = [{ codigo: 'V-REG-FIBRA', nome: 'Nio Fibra 600 Mega', portfolio: 'varejo', variante: 'regular', preco: '110.00', preco_cartao: '95' }];

function motor(msg, conv) {
  const nodes = {
    '4b · Supabase contexto': { conversa: Object.assign({ id: 'c1', status: 'ativo', etapa: 'planos', cidade: 'Juiz de Fora', dentro_area: true,
      cep: '36035130', numero: '123', dados: { abertura: 'b3_191126', endereco_ok: true } }, conv), planos: [] },
    '4 · Preparar': { consolidado: { mensagem: msg, historico: [{ papel: 'lead', texto: 'Oi' }, { papel: 'mari', texto: 'Oi, tudo bem?' }], n_mensagens: 1 } },
    '5a · Conteúdo Mari': { promptVersao: 'mari_v7', promptBase: 'base' },
    '4c · Supabase interativo': { cartoes: [], textos: {}, cidades: [{ cidade: 'Juiz de Fora', cluster: 'regular' }], planos_cidade: {} },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const r = new Function('$', '$input', '$json', '$runIndex', '$getWorkflowStaticData', MOTOR)($, { first: () => ({ json: {} }) }, {}, 0, () => ({}))[0].json;
  return String((r.ctx || {}).estado || '');
}
function extrair(bruto, conv, hist, msg) {
  const nodes = {
    '5b · Motor': { ctx: { conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', dentroHorario: true, planos: PLANOS, segmento: 'varejo',
      dentroArea: true, conversa: Object.assign({ id: 'c1', etapa: 'endereco', cidade: 'Juiz de Fora', cep: '36035130', numero: '123', status: 'ativo',
        dados: { telefone: '32999999999' } }, conv) } },
    '4 · Preparar': { consolidado: { mensagem: msg, historico: hist || [] } },
    '2 · Entrada': { modo: 'teste' },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const $input = { first: () => ({ json: { content: [{ type: 'text', text: bruto }], usage: {}, stop_reason: 'end_turn' } }) };
  return new Function('$', '$input', '$json', '$runIndex', EXTRAIR)($, $input, {}, 0)[0].json;
}
let falhas = 0;
function caso(nome, f) { try { f(); console.log(`ok  ${nome}`); } catch (e) { falhas++; console.log(`FALHOU  ${nome}: ${e.message}`); } }
const H_END = [{ papel: 'mari', texto: 'Seu endereço é Rua dos Artistas, Morro da Glória, nº 123?\n\n[botões: Sim / Não]' }];
const LISTA = ['Apartamento 101', 'Apartamento 102'];

caso('7: o "Sim" da confirmação do endereço grava endereco_ok e a etapa vai aos planos sem complemento', () => {
  const r = extrair('Boa! A Nio atende Juiz de Fora 🎯\n[ELEGIBILIDADE: ok]\n[CARROSSEL_PLANOS]', {}, H_END, 'Sim');
  assert.strictEqual(((r.upd || {}).dados || {}).endereco_ok, true, `sem endereco_ok: ${JSON.stringify((r.upd || {}).dados)}`);
  assert.strictEqual((r.upd || {}).etapa, 'planos', `etapa ${(r.upd || {}).etapa}`);
});
caso('7: "Sim" a outra pergunta (não a do endereço) não grava endereco_ok', () => {
  const r = extrair('Ótimo!', {}, [{ papel: 'mari', texto: 'Quer que eu te mostre os planos?' }], 'Sim');
  assert.ok(!((r.upd || {}).dados || {}).endereco_ok);
  assert.strictEqual((r.upd || {}).etapa, 'endereco');
});
caso('7: sem complemento, com todos os dados, a etapa fica em coleta (o resumo espera o complemento)', () => {
  const r = extrair('Anotado!', { etapa: 'coleta', elegibilidade: 'ok', plano_escolhido: 'V-REG-FIBRA', forma_pagamento: 'boleto', instalacao_preferencia: 'Seg, 23/11, manhã',
    dados: { endereco_ok: true, nome: 'Ana Teste', cpf: '52998224725', telefone: '32999999999', email: 'a@b.com', referencia: 'nenhuma' } }, [], 'ok');
  assert.strictEqual((r.upd || {}).etapa, 'coleta');
});
caso('7: com o complemento ("nenhum"), a etapa vai ao resumo', () => {
  const r = extrair('Anotado!\n[ENDERECO: complemento=nenhum]', { etapa: 'coleta', elegibilidade: 'ok', plano_escolhido: 'V-REG-FIBRA', forma_pagamento: 'boleto',
    instalacao_preferencia: 'Seg, 23/11, manhã', dados: { endereco_ok: true, nome: 'Ana Teste', cpf: '52998224725', telefone: '32999999999', email: 'a@b.com', referencia: 'nenhuma' } }, [], 'Não tem');
  assert.strictEqual((r.upd || {}).etapa, 'resumo');
});
caso('5b: consulta não voltou → complemento_agora: DEPOIS, e complemento em dados_faltando', () => {
  const e = motor('Quero o Fibra', {});
  assert.match(e, /complemento_agora: DEPOIS/);
  assert.match(e, /dados_faltando: [^\n]*complemento/);
});
caso('5b: consulta voltou sem lista → complemento_agora: SIM', () => {
  const e = motor('Quero o Fibra', { nio_viab_resultado: 'viavel', nio_viab_em: new Date().toISOString(), cobertura_decisao: 'viavel', cobertura_detalhe: { portal: 'viavel' } });
  assert.match(e, /complemento_agora: SIM/);
});
caso('5b: consulta voltou com a lista → complemento_agora: LISTA e as unidades no estado', () => {
  const e = motor('Quero o Fibra', { nio_viab_resultado: 'viavel', nio_viab_em: new Date().toISOString(), cobertura_decisao: 'viavel',
    cobertura_detalhe: { portal: 'viavel', unidade_a_confirmar: true, unidades: LISTA },
    unidade_conferir: { motivo: 'escolher', lista: LISTA }, unidade_conferir_em: new Date().toISOString() });
  assert.match(e, /complemento_agora: LISTA/);
  assert.match(e, /Apartamento 101/);
});
caso('5b: complemento já respondido → sem a linha complemento_agora', () => {
  const e = motor('Quero o Fibra', { complemento: 'Casa B' });
  assert.ok(!/complemento_agora/.test(e));
  assert.ok(!/dados_faltando: [^\n]*complemento/.test(e));
});
caso('5b: endereço ainda não confirmado → sem a linha complemento_agora', () => {
  const e = motor('123', { dados: { abertura: 'b3_191126' } });
  assert.ok(!/complemento_agora/.test(e));
});
const UNIDC = { nio_viab_resultado: 'viavel', nio_viab_em: new Date().toISOString(), cobertura_detalhe: { portal: 'viavel', unidade_a_confirmar: true, unidades: LISTA },
  unidade_conferir: { motivo: 'escolher', lista: LISTA }, unidade_conferir_em: new Date().toISOString() };
const PLANOS2 = [{ codigo: 'V-REG-FIBRA', nome: 'Nio Fibra 600 Mega', portfolio: 'varejo', variante: 'regular', preco: '110.00', preco_cartao: '95' },
  { codigo: 'V-REG-ESS', nome: 'Nio Essencial 800 Mega + 10 GB', portfolio: 'varejo', variante: 'regular', preco: '140.00', preco_cartao: '125' }];
PLANOS.push(PLANOS2[1]);
caso('7: escolheu o plano com upsell e a lista chegou → a pergunta da unidade vai sozinha (sem "fica ou troca" colado)', () => {
  const r = extrair('Boa escolha! Antes de seguir: no cadastro da Nio o seu endereço aparece com unidades — qual destas é a sua? Apartamento 101 ou Apartamento 102\n[PLANO_ESCOLHIDO: V-REG-FIBRA]\n[UPSELL_OFERECIDO]',
    Object.assign({ etapa: 'planos', elegibilidade: 'ok', dados: { telefone: '32999999999', endereco_ok: true } }, UNIDC), [{ papel: 'mari', texto: 'Olha as opções' }], 'Quero o plano Nio Fibra');
  const t = [r.texto || '', (r.interativo || {}).corpo || ''].join('\n');
  assert.ok(!/fica no|prefere o/i.test(t), `upsell colado na pergunta da unidade: «${t.slice(-200)}»`);
  assert.ok(!r.interativo || r.interativo.chave !== 'upsell', 'botões do upsell colados');
  assert.ok(/Apartamento 101/.test(t), 'a pergunta da unidade sumiu');
});
caso('7: upsell sem resposta e a fala pergunta o complemento → sem "fica ou troca" e sem pedir CPF colado', () => {
  const r = extrair('Anotado! E tem complemento, tipo Casa A ou B, apto ou bloco?', { etapa: 'coleta', elegibilidade: 'ok', plano_escolhido: 'V-REG-FIBRA', upsell_oferecido: true,
    nio_viab_resultado: 'viavel', nio_viab_em: new Date().toISOString(), dados: { telefone: '32999999999', endereco_ok: true } }, [{ papel: 'mari', texto: 'Fica no Fibra ou prefere o Essencial?' }], 'hmm');
  const t = r.texto || '';
  assert.ok(!/fica no|prefere o|nome completo|\bcpf\b/i.test(t), `outra pergunta colada no complemento: «${t.slice(-200)}»`);
});
console.log(falhas ? `\n${falhas} falha(s)` : '\ntudo ok');
process.exit(falhas ? 1 : 0);
