// NIOGEN | tests/mari_n07_local_handoff_curto.test.js | 15/11/2026 — Claude Code / Opus 5.5 (handoff curto da Mari)
// Sem API: node tests/mari_n07_local_handoff_curto.test.js n8n/mari/n07_extrair.js
// Confere a nota curta do handoff: título · viabilidade · crédito · "👉 Fazer agora" · alertas · resumo, em até 7 linhas.
const fs = require('fs');
const assert = require('assert');
const code = fs.readFileSync(process.argv[2] || 'n8n/mari/n07_extrair.js', 'utf8');
function rodar(bruto, conv, hist, msg) {
  const nodes = {
    '5b · Motor': { ctx: { conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', dentroHorario: true,
      planos: [{ codigo: 'V-500-BOL', nome: 'Nio Fibra 500 Mega', preco: 99.9 }],
      conversa: Object.assign({ id: 'c1', etapa: 'resumo', cidade: 'Contagem', cep: '32000000', numero: '10', complemento: 'casa',
        elegibilidade: 'ok', plano_escolhido: 'V-500-BOL', forma_pagamento: 'boleto', instalacao_preferencia: 'manha',
        dados: { nome: 'Eli Teste da Silva', cpf: '52998224725', telefone: '31999999999', email: 'a@b.com', referencia: 'perto da padaria' } }, conv) } },
    '4 · Preparar': { consolidado: { mensagem: msg || 'Sim', historico: hist || [] } },
    '2 · Entrada': { modo: 'chatwoot' },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const $input = { first: () => ({ json: { content: [{ type: 'text', text: bruto }], usage: {}, stop_reason: 'end_turn' } }) };
  return new Function('$', '$input', '$json', '$runIndex', code)($, $input, {}, 0)[0].json;
}
const venda = (b) => 'Pronto, Eli, tudo certo por aqui!\n\nAgora o nosso time confere tudo no sistema da Nio e abre o seu pedido.\n[HANDOFF]\nmotivo_handoff: dados_completos\n'
  + `briefing_humano: "${b || 'RESUMO: Eli quer instalar no sábado de manhã; mora com a mãe.'}"\n[/HANDOFF]`;
const VIAVEL = { cobertura_decisao: 'viavel', nio_viab_resultado: 'viavel', nio_viab_velocidade: '1 Giga' };
let falhas = 0;
function caso(nome, r, checa) {
  const br = r.handoff ? r.handoff.lead.briefing : '';
  const linhas = br.split('\n');
  try {
    assert.ok(r.handoff, 'sem handoff');
    assert.ok(linhas.length <= 7, `nota com ${linhas.length} linhas`);
    assert.ok(!/1º PASSO/.test(br), 'ainda tem o 1º PASSO');
    assert.ok(/^💳 Crédito:/m.test(br) && /^(✅|⚠️|❌|❔) Viabilidade:/m.test(br), 'sem viabilidade ou crédito');
    assert.ok(/^👉 Fazer agora: /m.test(br), 'sem Fazer agora');
    checa(br);
    console.log(`ok  ${nome}`);
  } catch (e) { falhas++; console.log(`FALHOU  ${nome}: ${e.message}\n${br}\n`); }
  if (process.env.VER) console.log(br + '\n');
}
caso('venda viável + aprovado', rodar(venda(), { ...VIAVEL, credito_resultado: 'aprovado_todas', credito_endereco: 'cliente', credito_consultas: 1 }), (b) => {
  assert.match(b, /^🟢 VENDA PRONTA · Eli Teste · Nio Fibra 500 Mega · boleto/);
  assert.match(b, /VIÁVEL até 1 Giga/); assert.match(b, /APROVADO — todas as formas/);
  assert.match(b, /Fazer agora: Abrir o pedido no portal no boleto/); assert.match(b, /^Resumo: Eli quer instalar/m);
});
caso('só cartão + cliente sem cartão', rodar(venda(), { ...VIAVEL, credito_resultado: 'aprovado_cartao', credito_endereco: 'cliente', credito_consultas: 1 },
  [{ papel: 'lead', texto: 'eu não tenho cartão não' }]), (b) => {
  assert.match(b, /APROVADO SÓ NO CARTÃO/); assert.match(b, /outra pessoa da casa como titular/); assert.match(b, /não tem\/não usa cartão/);
});
caso('negado na 1ª', rodar(venda(), { ...VIAVEL, credito_resultado: 'negado', credito_consultas: 1 }), (b) => assert.match(b, /CPF do parente/));
caso('lido no endereço padrão', rodar(venda(), { ...VIAVEL, credito_resultado: 'aprovado_todas', credito_endereco: 'padrao', credito_consultas: 1 }),
  (b) => { assert.match(b, /endereço PADRÃO/); assert.match(b, /de novo no endereço do cliente/); });
caso('crédito em andamento', rodar(venda(), { ...VIAVEL, credito_em: new Date().toISOString() }), (b) => assert.match(b, /em andamento/));
caso('sem e-mail: não consultado', rodar(venda(), { ...VIAVEL, dados: { nome: 'Eli', cpf: '52998224725', referencia: 'x' } }),
  (b) => { assert.match(b, /não consultado — faltou e-mail confirmado/); assert.match(b, /pedir ao cliente o e-mail/); });
caso('pedido Nio em andamento', rodar(venda(), { ...VIAVEL, nio_pedido_aberto: 'sim', credito_resultado: 'pedido_em_andamento' }),
  (b) => assert.match(b, /NÃO abrir outro pedido/));
caso('200 m', rodar(venda(), { cobertura_decisao: 'elegivel_200m' }), (b) => { assert.match(b, /200 m/); assert.match(b, /não consultado \(a Mari só consulta depois de viável\)/); });
caso('pediu humano com sugestão', rodar('Vou te passar pro nosso time 😊\n[HANDOFF]\nmotivo_handoff: pedido_humano\n'
  + 'briefing_humano: "RESUMO: quer falar de preço com alguém. SUGESTÃO: ligar e mostrar o plano de 300 Mega da tabela. ATENÇÃO: a esposa decide junto."\n[/HANDOFF]', VIAVEL),
  (b) => { assert.match(b, /^🟡 PEDIU ATENDIMENTO · Eli Teste/); assert.match(b, /Fazer agora: Ligar e mostrar o plano de 300 Mega/); assert.match(b, /a esposa decide junto/); assert.match(b, /^Resumo: quer falar de preço/m); });
caso('briefing antigo (sem rótulos)', rodar(venda('lead completo'), VIAVEL), (b) => assert.match(b, /^Resumo: lead completo$/m));
console.log(falhas ? `\n${falhas} FALHA(S)` : '\ntudo verde');
process.exit(falhas ? 1 : 0);
