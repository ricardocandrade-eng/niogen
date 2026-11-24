// NIOGEN | tests/mari_n07_local_carrossel_cobertura.test.js | 24/11/2026 — Claude Code / Opus 5.5 (L-287, #248)
// Sem API: node tests/mari_n07_local_carrossel_cobertura.test.js n8n/mari/n07_extrair.js
// Caso real (24/11 21h15 UTC): o carrossel já tinha saído e, ao "Aqui chega fibra de vcs?", a Mari mandou de novo, dizendo
// "Chega sim! … o endereço já deu certinho aqui no nosso sistema" — com o portal ainda consultando.
const fs = require('fs');
const assert = require('assert');
const code = fs.readFileSync(process.argv[2] || 'n8n/mari/n07_extrair.js', 'utf8');
const JA_VIU = [
  { papel: 'lead', texto: 'Não' },
  { papel: 'mari', texto: 'A Nio atende Juiz de Fora 🎯 Olha as opções:\n\n[carrossel: Fibra R$110/95 · Essencial R$140/125 · Super R$170/155 · Ultra R$200/185]' },
];
function rodar(bruto, msg, historico = JA_VIU, conversa = {}) {
  const nodes = {
    '5b · Motor': { ctx: { conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', dentroHorario: true, carrossel: true,
      planos: [{ codigo: 'V-REG-FIBRA', nome: 'Nio Fibra', preco: 110, preco_cartao: 95, velocidade_mb: 600, taxa_habilitacao: 540, isencao_meses: 12, portfolio: 'varejo', variante: 'regular' }],
      conversa: { id: 'c1', etapa: 'planos', cidade: 'Juiz de Fora', cep: '36031290', numero: '53', elegibilidade: 'ok', dados: {}, ...conversa } } },
    '4 · Preparar': { consolidado: { mensagem: msg, historico } },
    '2 · Entrada': { modo: 'chatwoot' },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const $input = { first: () => ({ json: { content: [{ type: 'text', text: bruto }], usage: {}, stop_reason: 'end_turn' } }) };
  return new Function('$', '$input', '$json', '$runIndex', code)($, $input, {}, 0)[0].json;
}
let falhas = 0;
function caso(nome, r, re, barra) {
  try {
    const v = (r.violacoes || []).filter((x) => re.test(x));
    if (barra) assert.ok(r.corrigir && v.length, `devia pedir reescrita (violações: ${(r.violacoes || []).join(' | ') || 'nenhuma'})`);
    else assert.ok(!v.length, `pediu reescrita sem motivo: ${v.join(' | ')}`);
    console.log(`ok  ${nome}`);
  } catch (e) { falhas++; console.log(`FALHOU  ${nome}: ${e.message}`); }
}
const CARR = /carrossel de novo/;
const COB = /prometeu cobertura/;
const REAL = 'Chega sim! A Nio atende Juiz de Fora e, no seu caso, o endereço já deu certinho aqui no nosso sistema ✅\n\nOlha as opções que a gente tem pra você:\n\n[CARROSSEL_PLANOS]\n\n[AVALIACAO: turno_ok]';
caso('L-287 real: carrossel repetido é barrado', rodar(REAL, 'Aqui chega fibra de vcs'), CARR, true);
caso('L-287 real: "Chega sim… o endereço já deu certinho no sistema" é barrado', rodar(REAL, 'Aqui chega fibra de vcs'), COB, true);
caso('resposta certa à pergunta da cobertura passa', rodar('A Nio atende Juiz de Fora 🎯 A disponibilidade exata na sua rua o nosso time confirma no sistema da Nio antes de abrir o pedido.\n\nQual dos planos te agradou mais?',
  'Aqui chega fibra de vcs'), /carrossel de novo|prometeu cobertura/, false);
caso('1º carrossel (cliente ainda não viu) passa', rodar('A Nio atende Juiz de Fora 🎯 Olha as opções:\n\n[CARROSSEL_PLANOS]', 'Não', [{ papel: 'mari', texto: 'Tem complemento?' }]), CARR, false);
caso('cliente pediu os planos de novo: carrossel passa', rodar('Claro! Olha as opções de novo:\n\n[CARROSSEL_PLANOS]', 'me manda os planos de novo'), CARR, false);
caso('cliente disse que não viu: carrossel passa', rodar('Mando de novo:\n\n[CARROSSEL_PLANOS]', 'não apareceu nada aqui'), CARR, false);
caso('outro CEP: carrossel passa', rodar('Anotado o novo endereço. Olha as opções:\n\n[CARROSSEL_PLANOS]', 'na verdade é no cep 30140-071'), CARR, false);
caso('"sim, chega" sem pergunta de cobertura não é tratado como promessa', rodar('Chega sim, o técnico leva o roteador no dia da instalação 😊', 'o roteador chega junto?'), COB, false);
caso('portal já disse viável: "chega sim" passa', rodar('Chega sim! 🎉 Qual plano você prefere?', 'aqui chega fibra?', JA_VIU, { nio_viab_resultado: 'viavel' }), COB, false);
console.log(falhas ? `\n${falhas} FALHA(S)` : '\ntudo verde');
process.exit(falhas ? 1 : 0);
