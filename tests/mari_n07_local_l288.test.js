// NIOGEN | tests/mari_n07_local_l288.test.js | 24/11/2026 — Claude Code / Opus 5.5 (bateria do Ricardo, L-288, #1)
// Sem API: node tests/mari_n07_local_l288.test.js n8n/mari/n07_extrair.js
// Falas reais do teste de 24/11 (19h01–19h30) + o texto da Nio sobre a internet móvel 5G (01/10/2026).
const fs = require('fs');
const assert = require('assert');
const code = fs.readFileSync(process.argv[2] || 'n8n/mari/n07_extrair.js', 'utf8');
function rodar(bruto, msg, historico = []) {
  const nodes = {
    '5b · Motor': { ctx: { conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', dentroHorario: true,
      planos: [{ codigo: 'V-REG-ESS', nome: 'Nio Essencial', preco: 140, preco_cartao: 125, velocidade_mb: 800, taxa_habilitacao: 540, isencao_meses: 12, portfolio: 'varejo', variante: 'regular' }],
      conversa: { id: 'c1', etapa: 'endereco', cidade: 'Juiz de Fora', cep: '36035130', numero: '123', elegibilidade: null, dados: {} } } },
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
const COMP = 'Me confirma: sua casa tem complemento (tipo Casa A, B, apto, bloco) ou não tem?';
const H1 = [{ papel: 'mari', texto: 'Tem complemento, tipo Casa A ou B, apto, bloco ou loja? Se não tiver, pode falar que não tem' }, { papel: 'lead', texto: 'A Nio é confiável?' }];
const H3 = [{ papel: 'mari', texto: `Pode confiar!\n\n${COMP}` }, { papel: 'mari', texto: 'A Nio não compara com outras operadoras.' }, { papel: 'mari', texto: 'Tem fidelidade de 12 meses.' }];

// chip / 5G
caso('L-288: "o técnico já leva o chip junto com o roteador" é barrado', rodar('O chip é combinado com você direto na instalação — nessa hora o técnico já leva certinho, junto com o roteador.', 'E como recebo o chip?'), /chip vem na instalação/, true);
caso('resposta certa: pede pelo App Nio depois da instalação', rodar('Depois da instalação da fibra, você pede o chip pelo App Nio: chip físico, entregue no seu endereço, ou eSIM, se o celular for compatível.', 'E como recebo o chip?'), /chip vem na instalação/, false);
caso('L-288: "5G da Nio" é barrado', rodar('É da própria Nio! O chip que vem incluso em alguns planos é 5G da Nio, com chamadas ilimitadas.', 'O plano com chip é de qual operadora?'), /palavra proibida/, true);
caso('L-288: "internet e chamadas ilimitadas" no chip é barrado', rodar('O chip que vem no plano é de internet móvel 5G, com internet e chamadas ilimitadas.', 'O plano com chip é de qual operadora?'), /ilimitada/, true);
caso('franquia + ligações ilimitadas passa', rodar('O Essencial já vem com 1 chip de 10 GB de internet móvel 5G, com ligações e mensagens ilimitadas.', 'e o chip?'), /ilimitada|palavra proibida/, false);
caso('rede da TIM pela Surf passa', rodar('A linha móvel usa a rede da TIM, por uma parceria da Nio com a Surf Telecom.', 'Mas é rede da TIm, Claro ou Vivo?'), /rede própria|palavra proibida/, false);
caso('"rede própria" é barrado', rodar('A Nio tem rede própria de celular em todo o Brasil.', 'Mas a Nio tem rede de celular no Brasil?'), /rede própria/, true);
// complemento repetido
caso('L-288: complemento perguntado na resposta anterior → não pergunta de novo', rodar(`Pode confiar! A Nio tem mais de 3 milhões de clientes.\n\n${COMP}`, 'A Nio é confiável?', H1), /complemento/, true);
caso('sem repetir o complemento passa', rodar('Pode confiar! A Nio tem mais de 3 milhões de clientes, em quase 300 cidades.', 'A Nio é confiável?', H1), /complemento/, false);
caso('3 respostas depois, pode perguntar de novo (com outras palavras)', rodar('Pra eu te mostrar os planos com o preço da sua casa, só falta saber: tem complemento, tipo Casa A, apto ou bloco?', 'E como eu pago?', H3.slice(1).concat([{ papel: 'mari', texto: 'Você escolhe: cartão, boleto ou débito.' }])), /complemento/, false);
caso('cliente respondeu do complemento: pode confirmar', rodar('Casa B, anotado. Tem mais algum complemento, tipo bloco?', 'é casa B', H1), /complemento/, false);
console.log(falhas ? `\n${falhas} FALHA(S)` : '\ntudo verde');
process.exit(falhas ? 1 : 0);
