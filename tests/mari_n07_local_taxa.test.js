// NIOGEN | tests/mari_n07_local_taxa.test.js | 23/11/2026 — Claude Code / Opus 5.5 (L-270: taxa de instalação só se perguntarem)
// Sem API: node tests/mari_n07_local_taxa.test.js n8n/mari/n07_extrair.js
// Decisão do Ricardo (23/11): a Mari não fala em taxa de instalação na sondagem; só se o cliente perguntar de fidelidade,
// multa ou de sair antes. Perguntou só da instalação → "a instalação é isenta", sem valor. O bloco [CONDICOES] continua.
const fs = require('fs');
const assert = require('assert');
const code = fs.readFileSync(process.argv[2] || 'n8n/mari/n07_extrair.js', 'utf8');
function rodar(bruto, msg) {
  const nodes = {
    '5b · Motor': { ctx: { conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', dentroHorario: true,
      planos: [{ codigo: 'V-REG-FIB', nome: 'Nio Fibra', preco: 110, preco_cartao: 95, velocidade_mb: 600, taxa_habilitacao: 540, isencao_meses: 12, portfolio: 'varejo', variante: 'regular' }],
      conversa: { id: 'c1', etapa: 'planos', cidade: 'Contagem', cep: '32070380', numero: '2570', elegibilidade: 'ok', dados: {} } } },
    '4 · Preparar': { consolidado: { mensagem: msg, historico: [] } },
    '2 · Entrada': { modo: 'chatwoot' },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const $input = { first: () => ({ json: { content: [{ type: 'text', text: bruto }], usage: {}, stop_reason: 'end_turn' } }) };
  return new Function('$', '$input', '$json', '$runIndex', code)($, $input, {}, 0)[0].json;
}
const taxaV = (r) => (r.violacoes || []).filter((x) => /taxa de instala|instalação é isenta/.test(x));
let falhas = 0;
function caso(nome, r, barra) {
  try {
    const v = taxaV(r);
    if (barra) assert.ok(r.corrigir && v.length, 'devia pedir reescrita pela taxa');
    else assert.ok(!v.length, `pediu reescrita sem motivo: ${v.join(' | ')}`);
    console.log(`ok  ${nome}`);
  } catch (e) { falhas++; console.log(`FALHOU  ${nome}: ${e.message}`); }
}
// As duas falas reais do L-270 (#235, 23/11 19h12 e 19h13).
caso('L-270: puxou a taxa no "é só 95?"', rodar('Isso, R$95 por mês no cartão (ou R$110 no boleto), com esse valor fixo até janeiro de 2030.\n\nTem só a taxa de instalação, que te explico certinho quando a gente fechar — ela pode ficar isenta dependendo do tempo de contrato.\n\nFecha com esse plano?',
  'Então é só o valor de 95,00 ?'), true);
caso('L-270: deu o valor quando perguntaram da instalação', rodar('A taxa de instalação é de R$540, mas ela fica isenta se você ficar os 12 meses com a gente.\n\nFecha com o Nio Fibra então?',
  'Quanto é a taxa de instalação?'), true);
caso('resposta certa ao "é só 95?"', rodar('Isso, só os R$95 por mês no cartão, fixo até janeiro de 2030, e o roteador já vem incluso.\n\nFecha com o Nio Fibra?',
  'Então é só o valor de 95,00 ?'), false);
caso('resposta certa à pergunta da instalação', rodar('A instalação é isenta 😊\n\nFecha com o Nio Fibra?', 'Quanto é a taxa de instalação?'), false);
caso('perguntou de fidelidade: pode explicar', rodar('Não tem multa de fidelidade. A taxa de instalação, de R$540, fica isenta com 12 meses; se sair antes, paga só a parte proporcional.\n\nFecha com o Nio Fibra?',
  'Tem fidelidade?'), false);
caso('perguntou se cancelar antes: pode explicar', rodar('Se cancelar antes dos 12 meses, paga só a parte proporcional da taxa de instalação de R$540.\n\nFecha com o Nio Fibra?',
  'e se eu cancelar antes?'), false);
caso('bloco de condições continua', rodar('Fechado, então: Nio Fibra por R$95 por mês no cartão.\n||\n[CONDICOES]\n||\nFechou? Me manda seu nome completo e CPF que eu já adianto aqui.',
  'quero o fibra'), false);
console.log(falhas ? `\n${falhas} FALHA(S)` : '\ntudo verde');
process.exit(falhas ? 1 : 0);
