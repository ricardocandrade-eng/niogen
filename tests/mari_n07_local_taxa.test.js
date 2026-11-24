// NIOGEN | tests/mari_n07_local_taxa.test.js | 23/11/2026 — Claude Code / Opus 5.5 (L-270: taxa de instalação só se perguntarem)
// Sem API: node tests/mari_n07_local_taxa.test.js n8n/mari/n07_extrair.js
// Decisão do Ricardo (23/11): a Mari não fala em taxa de instalação na sondagem; só se o cliente perguntar de fidelidade,
// multa ou de sair antes. Perguntou só da instalação → "a instalação é isenta", sem valor. O bloco [CONDICOES] continua.
const fs = require('fs');
const assert = require('assert');
const code = fs.readFileSync(process.argv[2] || 'n8n/mari/n07_extrair.js', 'utf8');
function rodar(bruto, msg, historico = []) {
  const nodes = {
    '5b · Motor': { ctx: { conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', dentroHorario: true,
      planos: [{ codigo: 'V-REG-FIB', nome: 'Nio Fibra', preco: 110, preco_cartao: 95, velocidade_mb: 600, taxa_habilitacao: 540, isencao_meses: 12, portfolio: 'varejo', variante: 'regular' }],
      conversa: { id: 'c1', etapa: 'planos', cidade: 'Contagem', cep: '32070380', numero: '2570', elegibilidade: 'ok', dados: {} } } },
    '4 · Preparar': { consolidado: { mensagem: msg, historico } },
    '2 · Entrada': { modo: 'chatwoot' },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const $input = { first: () => ({ json: { content: [{ type: 'text', text: bruto }], usage: {}, stop_reason: 'end_turn' } }) };
  return new Function('$', '$input', '$json', '$runIndex', code)($, $input, {}, 0)[0].json;
}
const taxaV = (r) => (r.violacoes || []).filter((x) => /taxa de instala|instalação é isenta|fidelidade/.test(x));
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
// 24/11 (L-287, Ricardo): todo plano TEM fidelidade (12 meses); 1ª resposta sem o R$; o valor só se pedirem.
caso('perguntou de fidelidade: explica sem o valor', rodar('Tem fidelidade de 12 meses, como em qualquer operadora: se cancelar antes, paga só a parte proporcional da taxa de instalação.\n\nFecha com o Nio Fibra?',
  'Tem fidelidade?'), false);
caso('perguntou de fidelidade: "não tem multa de fidelidade" é barrado', rodar('Não tem multa de fidelidade. A instalação fica isenta com 12 meses; se sair antes, paga só a parte proporcional.\n\nFecha com o Nio Fibra?',
  'Tem fidelidade?'), true);
caso('perguntou se cancelar antes: o R$540 na 1ª resposta é barrado', rodar('Se cancelar antes dos 12 meses, paga só a parte proporcional da taxa de instalação de R$540.\n\nFecha com o Nio Fibra?',
  'e se eu cancelar antes?'), true);
caso('L-287: "posso cancelar depois de quanto tempo" — explica sem valor', rodar('Tem fidelidade de 12 meses: se cancelar antes, paga só a parte proporcional da taxa de instalação. Depois disso, cancela quando quiser.\n\nFecha com o Nio Fibra?',
  'Se a internet estiver ruim ou fraca posso cancelar depois de quanto tempo de contratação'), false);
caso('L-287: "não é obrigatório… sem fidelidade" é barrado', rodar('Não, não é obrigatório! O valor fica fixo até janeiro de 2030, e você fica à vontade, sem fidelidade.\n\nFecha o Fibra então?',
  'E obrigatório a ficar com vcs até 2030?'), true);
caso('pediu quanto é a multa: pode dar o valor', rodar('A taxa de instalação é de R$540, isenta se você ficar os 12 meses. Saindo antes, paga só o proporcional dos meses que faltam.',
  'quanto é a multa se eu cancelar?'), false);
caso('depois de explicar a fidelidade, "quanto?" pode ter o valor', rodar('A taxa de instalação é de R$540, isenta se você ficar os 12 meses. Saindo antes, paga só o proporcional dos meses que faltam.',
  'quanto?', [{ papel: 'lead', texto: 'tem fidelidade?' }, { papel: 'mari', texto: 'Tem fidelidade de 12 meses: se cancelar antes, paga só a parte proporcional da taxa de instalação.' }]), false);
caso('cliente pediu a versão sem fidelidade: pode dizer "sem fidelidade"', rodar('Tem a versão sem fidelidade do Nio Fibra, com o mesmo preço mensal e a taxa de instalação inteira na 1ª fatura.',
  'tem como ser sem fidelidade?'), false);
caso('bloco de condições continua', rodar('Fechado, então: Nio Fibra por R$95 por mês no cartão.\n||\n[CONDICOES]\n||\nFechou? Me manda seu nome completo e CPF que eu já adianto aqui.',
  'quero o fibra'), false);
// 23/11 (Ricardo: "Tirar a linha"): o quadro de condições não fala mais de taxa nem de fidelidade.
{
  const r = rodar('Fechado, então: Nio Fibra por R$95 por mês no cartão.\n||\n[CONDICOES]\n||\nFechou? Me manda seu nome completo e CPF que eu já adianto aqui.', 'quero o fibra');
  const txt = JSON.stringify(r);
  try {
    assert.ok(/As condições do seu plano/.test(txt), 'quadro não saiu');
    assert.ok(/Preço fixo até janeiro\/2030/.test(txt) && /Roteador/.test(txt), 'quadro sem preço fixo ou roteador');
    assert.ok(!/Taxa de instala|fidelidade/i.test(txt), 'quadro ainda fala de taxa ou fidelidade');
    console.log('ok  quadro de condições sem a linha da taxa');
  } catch (e) { falhas++; console.log(`FALHOU  quadro de condições sem a linha da taxa: ${e.message}`); }
}
console.log(falhas ? `\n${falhas} FALHA(S)` : '\ntudo verde');
process.exit(falhas ? 1 : 0);
