// NIOGEN | tests/mari_local_abertura_credito.test.js | 19/11/2026 — Claude Code / Opus 5.5 (migrations 0327/0328)
// Sem API: node tests/mari_local_abertura_credito.test.js
// Confere, rodando o código dos nós como o n8n roda:
//   5b · Motor — "💰 Ver os planos" antes do CEP pergunta a CIDADE; a resposta com uma cidade atendida mostra os planos com o preço
//               dela (regular → carrossel, BTU → lista com preço único) e pede o CEP; cidade não reconhecida → o Claude segue;
//               "📍 Ver minha rua" antigo e "📍 Tem na minha rua?" novo são reconhecidos; com a cidade conhecida o toque vai ao Claude.
//   7 · Extrair — crédito NEGADO já avisado pelo NIOGEN (0327): na fala seguinte do cliente a Mari passa ao time, sem repetir o aviso;
//               uma vez só.
const fs = require('fs');
const assert = require('assert');
const MOTOR = fs.readFileSync('n8n/mari/n05b_motor.js', 'utf8').replace('__MODELO__', "'modelo-teste'").replace('__HIST_MAX__', '30');
const EXTRAIR = fs.readFileSync('n8n/mari/n07_extrair.js', 'utf8');

const card = (cod, nome, p, pc, fam) => ({ plano_codigo: cod, nome, nome_curto: nome, preco: p, preco_cartao: pc, imagem_url: `https://exemplo.test/${fam}.png`,
  texto_card: `Plano ${nome}\n\nPor R$ ${p},00 ou R$ ${pc},00 no cartão`, texto_detalhes: `Detalhes do ${nome}`,
  titulo_quero: `Quero o ${fam}`, titulo_detalhes: `Detalhes ${fam}` });
const CARTOES = [card('V-REG-FIBRA', 'Nio Fibra 600 Mega', 110, 95, 'Fibra'), card('V-REG-ESS', 'Nio Essencial 800 Mega', 140, 125, 'Essencial'),
  card('V-REG-SUP', 'Nio Super 1 Giga', 170, 155, 'Super'), card('V-REG-ULT', 'Nio Ultra 1 Giga', 200, 185, 'Ultra')];
const TEXTOS = { abertura_versao: 'b3_191126', abertura_formato: 'botoes', abertura_botoes: 'rua,planos,cliente',
  abertura_botao_rua: '📍 Tem na minha rua?', abertura_botao_planos: '💰 Ver os planos', abertura_botao_cliente: '🏠 Sou cliente Nio',
  abertura_resp_rua: 'Me manda o CEP', abertura_resp_planos: 'O valor muda de cidade pra cidade. Me manda seu CEP' };

function motor(msg, conv, opts = {}) {
  const nodes = {
    '4b · Supabase contexto': { conversa: Object.assign({ id: 'c1', status: 'ativo', etapa: 'abertura', dados: { abertura: 'b3_191126' } }, conv), planos: [] },
    '4 · Preparar': { consolidado: { mensagem: msg, historico: opts.historico || [{ papel: 'lead', texto: 'Oi' }, { papel: 'mari', texto: 'Oi, tudo bem?' }], n_mensagens: 1 } },
    '5a · Conteúdo Mari': { promptVersao: 'mari_v7', promptBase: 'base' },
    '4c · Supabase interativo': { cartoes: opts.cartoes || CARTOES, textos: Object.assign({}, TEXTOS, opts.textos || {}),
      cidades: [{ cidade: 'Contagem', cluster: 'regular' }, { cidade: 'Juiz de Fora', cluster: 'regular' }, { cidade: 'Ipatinga', cluster: 'btu' },
        { cidade: 'São Lourenço', cluster: 'regular' }],
      planos_cidade: { btu: [{ codigo: 'V-O50-FIBRA', nome: 'Nio Fibra 600 Mega (BTU)', preco: 55, preco_cartao: null },
        { codigo: 'V-O50-ESS', nome: 'Nio Essencial 800 Mega + 10 GB (BTU)', preco: 70, preco_cartao: null }] } },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const estatico = {};
  return new Function('$', '$input', '$json', '$runIndex', '$getWorkflowStaticData', MOTOR)($, { first: () => ({ json: {} }) }, {}, 0, () => estatico)[0].json;
}

function extrair(bruto, conv, msg) {
  const nodes = {
    '5b · Motor': { ctx: { conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', dentroHorario: true, planos: [],
      conversa: Object.assign({ id: 'c1', etapa: 'coleta', cidade: 'Contagem', cep: '32000000', numero: '10', plano_escolhido: 'V-REG-FIBRA',
        forma_pagamento: 'boleto', funil_destino: 'em_andamento', dados: { nome: 'Eli Teste', cpf: '52998224725', email: 'a@b.com' } }, conv) } },
    '4 · Preparar': { consolidado: { mensagem: msg || 'ok', historico: [] } },
    '2 · Entrada': { modo: 'chatwoot' },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const $input = { first: () => ({ json: { content: [{ type: 'text', text: bruto }], usage: {}, stop_reason: 'end_turn' } }) };
  return new Function('$', '$input', '$json', '$runIndex', EXTRAIR)($, $input, {}, 0)[0].json;
}

let falhas = 0;
function caso(nome, fn) {
  try { fn(); console.log(`ok  ${nome}`); } catch (e) { falhas++; console.log(`FALHOU  ${nome}: ${e.message}`); }
}

const PEDIU = { abertura: 'b3_191126', abertura_botao: 'planos', abertura_pediu_cidade: true };
caso('Ver os planos antes do CEP → pergunta a cidade', () => {
  const r = motor('💰 Ver os planos', {});
  assert.ok(r.fixo && /sua cidade/.test(r.fixo.texto) && !r.fixo.interativo, JSON.stringify(r.fixo));
  assert.strictEqual(r.fixo.upd.dados.abertura_pediu_cidade, true);
});
caso('responde "Contagem" (regular) → carrossel com o preço da cidade e o pedido do CEP', () => {
  const r = motor('Contagem', { dados: PEDIU });
  const it = r.fixo && r.fixo.interativo;
  assert.ok(it && it.tipo === 'carrossel' && it.cartoes.length === 4, JSON.stringify(r.fixo));
  assert.match(it.corpo, /^Em Contagem são estes/); assert.match(it.corpo, /CEP/);
  assert.match(it.resumo, /^carrossel: /);
  assert.match(it.fallbackTexto, /1\) Nio Fibra 600 Mega — R\$110 por mês \(R\$95 no cartão\)/);
  assert.strictEqual(r.fixo.upd.dados.planos_cidade, 'Contagem');
});
caso('responde "moro em são lourenço mg" → reconhece a cidade', () => {
  const r = motor('moro em são lourenço mg', { dados: PEDIU });
  assert.ok(r.fixo && r.fixo.interativo && /^Em São Lourenço/.test(r.fixo.interativo.corpo), JSON.stringify(r.fixo));
});
caso('responde "Ipatinga" (BTU) → lista com o preço único da cidade, sem cartão, e o CEP', () => {
  const r = motor('Ipatinga', { dados: PEDIU });
  assert.ok(r.fixo && !r.fixo.interativo, JSON.stringify(r.fixo));
  assert.match(r.fixo.texto, /^Em Ipatinga os planos são:/);
  assert.match(r.fixo.texto, /1\) Nio Fibra 600 Mega — R\$55 por mês\n/);
  assert.ok(!/cartão/.test(r.fixo.texto), 'falou de cartão em BTU');
  assert.match(r.fixo.texto, /CEP/);
});
caso('cidade não atendida ("Uberlândia") → segue para o Claude, com a linha de estado', () => {
  const r = motor('Uberlândia', { dados: PEDIU });
  assert.ok(!r.fixo, JSON.stringify(r.fixo));
  assert.match(String((r.ctx || {}).estado || ''), /abertura_pediu_cidade/);
});
caso('preço do cartão divergente da tabela → a lista em texto não sai pelo carrossel', () => {
  const ruins = CARTOES.map((k, i) => (i === 1 ? Object.assign({}, k, { preco: 150 }) : k));
  const r = motor('Contagem', { dados: PEDIU }, { cartoes: ruins });
  assert.ok(!r.fixo || !r.fixo.interativo, JSON.stringify(r.fixo));
});
caso('pela cidade desligado por config → pede o CEP como antes', () => {
  const r = motor('💰 Ver os planos', {}, { textos: { abertura_planos_cidade: 'nao' } });
  assert.ok(r.fixo && !r.fixo.interativo && /CEP/.test(r.fixo.texto), JSON.stringify(r.fixo));
});
caso('empresas antes do CEP → pede o CEP como antes', () => {
  const r = motor('💰 Ver os planos', { segmento: 'empresas' });
  assert.ok(r.fixo && !r.fixo.interativo && /CEP/.test(r.fixo.texto), JSON.stringify(r.fixo));
});
caso('cidade já conhecida → o toque vai para o Claude', () => {
  const r = motor('💰 Ver os planos', { cluster: 'regular', cidade: 'Contagem' });
  assert.ok(!r.fixo, JSON.stringify(r.fixo));
});
caso('"📍 Tem na minha rua?" (novo) é reconhecido', () => {
  const r = motor('📍 Tem na minha rua?', {});
  assert.ok(r.fixo && r.fixo.texto === 'Me manda o CEP' && r.fixo.tags.abertura_botao === 'rua', JSON.stringify(r.fixo));
});
caso('"📍 Ver minha rua" (menu antigo na tela) segue reconhecido', () => {
  const r = motor('Ver minha rua', {});
  assert.ok(r.fixo && r.fixo.texto === 'Me manda o CEP' && r.fixo.tags.abertura_botao === 'rua', JSON.stringify(r.fixo));
});
caso('o menu da abertura usa o título novo', () => {
  const r = motor('Oi, vi o anúncio', {}, { historico: [] });
  const tit = ((r.fixo || {}).interativo || {}).botoes || [];
  assert.deepStrictEqual(tit.map((b) => b.title), ['📍 Tem na minha rua?', '💰 Ver os planos', '🏠 Sou cliente Nio']);
});
caso('depois dos planos pela cidade, o Claude sabe que o cliente já viu (e pede o CEP)', () => {
  const r = motor('quero o fibra', { dados: Object.assign({}, PEDIU, { planos_cidade: 'Contagem' }) });
  assert.match(String((r.ctx || {}).estado || ''), /planos_pela_cidade: o cliente JÁ VIU os planos de Contagem/);
  assert.ok(!r.fixo, JSON.stringify(r.fixo));
});

const RESP = 'Que bom! Me conta o nome completo e o CPF do seu irmão que eu sigo 😊';
caso('negado já avisado pelo NIOGEN → na fala seguinte a Mari passa ao time, sem repetir o aviso', () => {
  const r = extrair(RESP, { credito_resultado: 'negado', credito_consultas: 1,
    dados: { nome: 'Eli Teste', cpf: '52998224725', credito_negado_avisado: true, credito_negado_sistema: true } },
  'é o meu irmão, João da Silva, cpf 111.444.777-35');
  assert.ok(r.handoff, 'sem handoff');
  assert.match(String(r.texto), /passei pro nosso time/);
  assert.ok(!/não aprovou/.test(String(r.texto)), 'repetiu o aviso');
  assert.strictEqual((r.upd.dados || {}).credito_negado_passado, true);
});
caso('negado já passado ao time → não passa de novo', () => {
  const r = extrair(RESP, { credito_resultado: 'negado', credito_consultas: 1,
    dados: { nome: 'Eli Teste', cpf: '52998224725', credito_negado_avisado: true, credito_negado_sistema: true, credito_negado_passado: true } });
  assert.ok(!/passei pro nosso time/.test(String(r.texto)), String(r.texto));
});
caso('negado sem o aviso do sistema → o roteiro antigo da Mari (avisa e oferece o parente)', () => {
  const r = extrair(RESP, { credito_resultado: 'negado', credito_consultas: 1, dados: { nome: 'Eli Teste', cpf: '52998224725' } });
  assert.match(String(r.texto), /não aprovou/);
});

console.log(falhas ? `\n${falhas} FALHA(S)` : '\ntudo verde');
process.exit(falhas ? 1 : 0);
