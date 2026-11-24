// NIOGEN | tests/mari_local_abertura_b4.test.js | 24/11/2026 — Claude Code / Opus 5.5 (migration 0381, abertura B4)
// Sem API: node tests/mari_local_abertura_b4.test.js
// Confere, rodando o código do 5b · Motor como o n8n roda:
//   - 1ª mensagem com referral de conjunto mapeado → âncora do gancho (texto) + corpo com "a partir de R$ 110" (o mais barato do cluster
//     REGULAR, nunca o min() de tudo — a BTU começa em R$ 55) + botões casa/comércio/cliente + pausa;
//   - referral de conjunto fora do mapa → âncora do anúncio, corpo SEM preço; sem referral → "Oi! Tudo bem? 👋" e SEM preço;
//   - toque em "🏡 Pra minha casa" / "🏪 Pro comércio" → pede a rua e o bairro; "🏠 Sou cliente Nio" segue igual;
//   - 1ª mensagem já com CEP → sem abertura; B3 (abertura_versao antiga) → a abertura de antes;
//   - estado: preço citado na abertura e a trava da cidade; prova social no viável, com o bairro.
const fs = require('fs');
const assert = require('assert');
const MOTOR = fs.readFileSync('n8n/mari/n05b_motor.js', 'utf8').replace('__MODELO__', "'modelo-teste'").replace('__HIST_MAX__', '30');

const TEXTOS = {
  abertura_versao: 'b4_241126', abertura_formato: 'botoes', abertura_botoes: 'casa,comercio,cliente',
  abertura_botao_casa: '🏡 Pra minha casa', abertura_botao_comercio: '🏪 Pro comércio', abertura_botao_cliente: '🏠 Sou cliente Nio',
  abertura_ancora_padrao: 'Oi! Tudo bem? 👋', abertura_ancora_anuncio: 'Oi! Vi que você chegou pelo nosso anúncio 👋',
  abertura_ancora_2030: 'Oi! Vi que você chegou pelo anúncio do preço travado até 2030 👋',
  abertura_ancora_ainda: 'Oi! Vi que você chegou pelo anúncio da fibra da Nio 👋',
  abertura_ancora_mapa: 'H1=2030,HA=ainda,HB=rua,H2=pordia,H5=giga',
  abertura_corpo_b4: 'Aqui é a Mari, da Nio 😊\n\nA fibra de 600 Mega sai a partir de R$ {preco_entrada}, e o valor que você fechar agora fica travado até janeiro de 2030, sem reajuste todo ano.',
  abertura_corpo_b4_sem_preco: 'Aqui é a Mari, da Nio 😊\n\nOs planos de fibra vão de 600 Mega a 1 Giga, e o valor que você fechar agora fica travado até janeiro de 2030, sem reajuste todo ano.',
  abertura_pergunta_b4: 'Já abri aqui o mapa da Nio pra conferir seu endereço — me diz só uma coisa antes:',
  abertura_fallback_pedido: 'Me manda a rua e o bairro (ou o CEP, se souber de cabeça) que em 1 minuto eu te digo se a fibra já passa na sua porta 😉',
  abertura_preco_conjuntos: '120257957894920211=regular,120257741890120211=regular',
  abertura_pausa_s: '6',
  abertura_resp_casa: 'Perfeito, residencial então.\n\nTô com o mapa aberto aqui — me manda a rua e o bairro',
  abertura_resp_comercio: 'Perfeito, pro seu comércio então.\n\nTô com o mapa aberto aqui — me manda a rua e o bairro do comércio',
  viabilidade_prova_social: 'Boa notícia: passa fibra {no_bairro} ✅ A rede da Nio já está puxada aí, e toda semana tem instalação nova no seu bairro 🙌',
};
const PLANOS_CIDADE = {
  regular: [{ codigo: 'V-REG-FIBRA', preco: 110, preco_cartao: 95 }, { codigo: 'V-REG-ESS', preco: 140, preco_cartao: 125 }],
  btu: [{ codigo: 'V-O50-FIBRA', preco: 55, preco_cartao: null }, { codigo: 'V-O50-ESS', preco: 70, preco_cartao: null }],
};

function motor(msg, conv, opts = {}) {
  const nodes = {
    '4b · Supabase contexto': { conversa: Object.assign({ id: 'c1', status: 'ativo', etapa: 'abertura', dados: {} }, conv), planos: [],
      anuncio: opts.anuncio || null },
    '4 · Preparar': { consolidado: { mensagem: msg, historico: opts.historico || [{ papel: 'lead', texto: msg }], n_mensagens: 1 } },
    '5a · Conteúdo Mari': { promptVersao: 'mari_v7', promptBase: 'base' },
    '4c · Supabase interativo': { cartoes: [], textos: Object.assign({}, TEXTOS, opts.textos || {}), cidades: [], planos_cidade: PLANOS_CIDADE },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  return new Function('$', '$input', '$json', '$runIndex', '$getWorkflowStaticData', MOTOR)($, { first: () => ({ json: {} }) }, {}, 0, () => ({}))[0].json;
}

let falhas = 0;
function caso(nome, fn) {
  try { fn(); console.log(`ok  ${nome}`); } catch (e) { falhas++; console.log(`FALHOU  ${nome}: ${e.message}`); }
}
const AN_C3_H1 = { ad_id: '120257959344360211', ad_nome: 'AD_C3_H1_sobe', adset_id: '120257957894920211', titulo: '600 Mega por R$ 95/mês até 2030' };

caso('referral do CJ_C3_MG (H1) → âncora do 2030 + "a partir de R$ 110" + 3 botões + pausa', () => {
  const r = motor('Vi o anúncio e quero saber mais', { origem: 'meta_ads' }, { anuncio: AN_C3_H1 });
  const fx = r.fixo; const it = fx && fx.interativo;
  assert.ok(fx && it, JSON.stringify(fx));
  assert.strictEqual(fx.texto, 'Oi! Vi que você chegou pelo anúncio do preço travado até 2030 👋');
  assert.match(it.corpo, /a partir de R\$ 110,/);
  assert.doesNotMatch(it.corpo, /R\$ 55|R\$ 95/);
  assert.match(it.corpo, /me diz só uma coisa antes:$/);
  assert.deepStrictEqual(it.botoes.map((b) => b.title), ['🏡 Pra minha casa', '🏪 Pro comércio', '🏠 Sou cliente Nio']);
  assert.strictEqual(it.pausaS, 6);
  assert.match(it.fallbackTexto, /a partir de R\$ 110[\s\S]*Me manda a rua e o bairro/);
  assert.strictEqual(fx.upd.dados.abertura, 'b4_241126');
  assert.strictEqual(fx.upd.dados.abertura_preco, 110);
  assert.strictEqual(fx.tags.ancora, '2030');
});
caso('referral de conjunto fora do mapa → âncora do anúncio pelo gancho, corpo SEM preço', () => {
  const r = motor('Oi', {}, { anuncio: { ad_id: '9', ad_nome: 'AD_X_HA_aindaNaoTem', adset_id: '555' } });
  assert.strictEqual(r.fixo.texto, 'Oi! Vi que você chegou pelo anúncio da fibra da Nio 👋');
  assert.doesNotMatch(r.fixo.interativo.corpo, /R\$/);
  assert.strictEqual(r.fixo.upd.dados.abertura_preco, undefined);
});
caso('gancho sem frase própria → "Vi que você chegou pelo nosso anúncio"', () => {
  const r = motor('Oi', {}, { anuncio: { ad_id: '9', ad_nome: 'AD_C3_HZ_novo', adset_id: '120257957894920211' } });
  assert.strictEqual(r.fixo.texto, 'Oi! Vi que você chegou pelo nosso anúncio 👋');
  assert.match(r.fixo.interativo.corpo, /a partir de R\$ 110,/);
});
caso('sem referral (orgânico, Fila Vero) → "Oi! Tudo bem? 👋" e nenhum preço', () => {
  const r = motor('Oi, quero internet', {});
  assert.strictEqual(r.fixo.texto, 'Oi! Tudo bem? 👋');
  assert.doesNotMatch(r.fixo.interativo.corpo, /R\$/);
  assert.match(r.fixo.interativo.corpo, /600 Mega a 1 Giga/);
});
caso('conjunto mapeado para BTU → "a partir de R$ 55" (o preço do cluster do conjunto, nunca fixo)', () => {
  const r = motor('Oi', {}, { anuncio: AN_C3_H1, textos: { abertura_preco_conjuntos: '120257957894920211=btu' } });
  assert.match(r.fixo.interativo.corpo, /a partir de R\$ 55,/);
});
caso('1ª mensagem já com CEP → sem abertura (segue o fluxo do CEP)', () => {
  const r = motor('Meu CEP é 36010-000', {}, { anuncio: AN_C3_H1 });
  assert.ok(!r.fixo, JSON.stringify(r.fixo));
});
caso('abertura_versao b3 → a abertura de antes (uma mensagem, sem preço)', () => {
  const r = motor('Oi', {}, { anuncio: AN_C3_H1, textos: { abertura_versao: 'b3_191126', abertura_corpo: 'Oi, {nome}, tudo bem? 💚\n\nCorpo B3', abertura_botoes: 'rua,planos,cliente' } });
  assert.strictEqual(r.fixo.texto, null);
  assert.match(r.fixo.interativo.corpo, /Corpo B3/);
  assert.strictEqual(r.fixo.interativo.pausaS, undefined);
});
caso('toque "🏡 Pra minha casa" → pede rua e bairro, grava casa', () => {
  const r = motor('🏡 Pra minha casa', { dados: { abertura: 'b4_241126' } }, { historico: [{ papel: 'lead', texto: 'Oi' }, { papel: 'mari', texto: 'Oi!' }] });
  assert.match(r.fixo.texto, /^Perfeito, residencial então/);
  assert.strictEqual(r.fixo.upd.dados.abertura_botao, 'casa');
});
caso('toque "Pro comércio" (sem emoji) → pede o endereço do comércio, grava comercio', () => {
  const r = motor('Pro comércio', { dados: { abertura: 'b4_241126' } }, { historico: [{ papel: 'lead', texto: 'Oi' }, { papel: 'mari', texto: 'Oi!' }] });
  assert.match(r.fixo.texto, /comércio/);
  assert.strictEqual(r.fixo.upd.dados.abertura_botao, 'comercio');
});
caso('toque "🏠 Sou cliente Nio" → a resposta fixa de sempre', () => {
  const r = motor('🏠 Sou cliente Nio', { dados: { abertura: 'b4_241126' } }, { historico: [{ papel: 'lead', texto: 'Oi' }, { papel: 'mari', texto: 'Oi!' }] });
  assert.strictEqual(r.fixo.upd.dados.abertura_botao, 'cliente');
});
caso('estado: preço citado na abertura vai com a trava da cidade', () => {
  const r = motor('moro em Ipatinga', { dados: { abertura: 'b4_241126', abertura_preco: 110 } },
    { historico: [{ papel: 'lead', texto: 'Oi' }, { papel: 'mari', texto: 'Oi!' }] });
  const sys = String(r.ctx.estado);
  assert.match(sys, /abertura_preco_citado: a 1ª mensagem disse "a partir de R\$ 110"/);
  assert.match(sys, /SEMPRE o da cidade do cliente/);
});
caso('viável com bairro → prova social com o bairro, sem número de instalações', () => {
  const r = motor('Isso', { cep: '30110000', numero: '10', cidade: 'Belo Horizonte', cluster: 'regular', dentro_area: true, etapa: 'planos',
    cobertura_decisao: 'viavel', nio_viab_resultado: 'viavel', endereco_cep: { bairro: 'Savassi' } },
    { historico: [{ papel: 'lead', texto: 'Oi' }, { papel: 'mari', texto: 'Oi!' }] });
  const sys = String(r.ctx.estado);
  assert.match(sys, /prova_social_viavel: .*Boa notícia: passa fibra no Savassi ✅/);
});

console.log(falhas ? `\n${falhas} FALHA(S)` : '\ntudo verde');
process.exit(falhas ? 1 : 0);
