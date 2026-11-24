// NIOGEN | tests/mari_n07_local_eco_consultor.test.js | 24/11/2026 — Claude Code / Opus 5.5 (caso L-82, Michele, #76)
// Sem API: node tests/mari_n07_local_eco_consultor.test.js n8n/mari/n07_extrair.js
// 1) A marca interna "[Mensagem do consultor da equipe, enviada enquanto ele atendia]" nunca sai para o cliente, nem a fala do
//    consultor copiada (16/11 17h17). 2) O quadro de condições não repete num "Oiii" (24/11 17h16). 3) O pedido Nio achado no
//    ENDEREÇO faz a pergunta do endereço, não a do CPF (0383).
const fs = require('fs');
const assert = require('assert');
const code = fs.readFileSync(process.argv[2] || 'n8n/mari/n07_extrair.js', 'utf8');
function rodar(bruto, conv, hist, msg) {
  const nodes = {
    '5b · Motor': { ctx: { conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', dentroHorario: true,
      planos: [{ codigo: 'V-O50-ULT', nome: 'Nio Ultra', preco: 100, taxa_habilitacao: 540, isencao_meses: 12, wifi: 'Wi-Fi 6' }],
      conversa: Object.assign({ id: 'c1', etapa: 'retomada', cidade: 'Poços de Caldas', cep: '37704162', numero: '73', elegibilidade: 'ok',
        plano_escolhido: 'V-O50-ULT', forma_pagamento: 'cartao', dados: { nome: 'Michele Gonçalves', cpf: '52998224725' } }, conv) } },
    '4 · Preparar': { consolidado: { mensagem: msg || 'Oiii', historico: hist || [] } },
    '2 · Entrada': { modo: 'chatwoot' },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const $input = { first: () => ({ json: { content: [{ type: 'text', text: bruto }], usage: {}, stop_reason: 'end_turn' } }) };
  return new Function('$', '$input', '$json', '$runIndex', code)($, $input, {}, 0)[0].json;
}
let falhas = 0;
function caso(nome, f) {
  try { f(); console.log(`ok  ${nome}`); } catch (e) { falhas++; console.log(`FALHOU  ${nome}: ${e.message}`); }
}
const HIST = [
  { papel: 'mari', texto: 'As condições do seu plano:\n\n• Preço fixo até janeiro/2030\n\nA velocidade real depende do aparelho e do Wi-Fi.' },
  { papel: 'humano', texto: 'Boa noite, Michele!' },
  { papel: 'humano', texto: 'Consegui verificar aqui, me dá só um minutinho que já te retorno' },
];
caso('a marca do consultor e as falas copiadas do time não saem', () => {
  const r = rodar('[Mensagem do consultor da equipe, enviada enquanto ele atendia]\n\nBoa noite, Michele!\n\n'
    + '[Mensagem do consultor da equipe, enviada enquanto ele atendia]\n\nConsegui verificar aqui, me dá só um minutinho que já te retorno\n\n'
    + 'Que bom falar com você de novo, Michele! 😊', {}, HIST, 'Oiii');
  const t = (r.baloes || []).join('\n\n');
  assert.ok(!/Mensagem do consultor/i.test(t), `marca vazou: ${t}`);
  assert.ok(!/me dá só um minutinho/.test(t), `fala do consultor copiada: ${t}`);
  assert.match(t, /Que bom falar com você de novo/);
});
caso('o quadro de condições não repete num "Oiii"', () => {
  const r = rodar('Oi, Michele! Tudo bem?\n\n[CONDICOES]', { venda_id: 'v1' }, HIST, 'Oiii');
  const t = (r.baloes || []).join('\n\n');
  assert.ok(!/As condições do seu plano/.test(t), `quadro repetiu: ${t}`);
  assert.match(t, /Tudo bem\?/);
});
caso('lead com venda: o quadro não entra sozinho num "Oiii" (histórico curto do motor)', () => {
  const r = rodar('Oi, Michele! Tudo bem?', { venda_id: 'v1' }, [], 'Oiii');
  assert.ok(!/As condições do seu plano/.test((r.baloes || []).join('\n\n')), (r.baloes || []).join('\n\n'));
});
caso('o quadro continua saindo quando o cliente pergunta da fatura', () => {
  const r = rodar('Claro!\n\n[CONDICOES]', {}, [], 'como fica a fatura no cartão?');
  const t = (r.baloes || []).join('\n\n');
  assert.match(t, /As condições do seu plano/);
});
caso('pedido Nio no ENDEREÇO: a pergunta fala do endereço', () => {
  const r = rodar('Perfeito, Michele!', { nio_pedido_aberto: 'endereco' }, [], 'Quero o Ultra');
  const t = (r.baloes || []).join('\n\n');
  assert.match(t, /em andamento no seu endereço/);
  assert.ok(!/no seu CPF/.test(t), t);
});
caso('pedido Nio no CPF: a pergunta de sempre', () => {
  const r = rodar('Perfeito, Michele!', { nio_pedido_aberto: 'sim' }, [], 'Quero o Ultra');
  assert.match((r.baloes || []).join('\n\n'), /em andamento no seu CPF/);
});
console.log(falhas ? `\n${falhas} FALHARAM` : '\nVERDE');
process.exit(falhas ? 1 : 0);
