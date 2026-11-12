// NIOGEN | tests/mari_n07_local_fallback.test.js | 12/11/2026 — Claude Code (achado 4 da auditoria). Sem API: node tests/mari_n07_local_fallback.test.js n8n/mari/n07_extrair.js
// Teste local do nó 7r · Extrair (correção): 2ª tentativa ainda com violação → fallback + handoff pedido_humano.
const fs = require('fs');
const code = fs.readFileSync(process.argv[2], 'utf8');
function rodar(bruto, conversaExtra, ehSegunda) {
  const nodes = {
    '5b · Motor': { ctx: { conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', planos: [], dentroHorario: true,
      conversa: Object.assign({ id: 'c1', etapa: 'planos', cidade: 'Betim', cep: '32677165', numero: '530', complemento: 'nenhum',
        elegibilidade: 'ok', dados: { referencia: 'colegio' } }, conversaExtra || {}), historico: [] } },
    '4 · Preparar': { consolidado: { mensagem: 'Vi no anuncio. 800 Mb com chip, por 85 reais.' } },
    '6 · Claude': { usage: {} }, '7 · Extrair': { violacoes: ['usou a palavra proibida "pacote"'] },
    '2 · Entrada': { modo: 'chatwoot' },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: n === '6r · Claude (correção)' ? ehSegunda : !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const $input = { first: () => ({ json: { content: [{ type: 'text', text: bruto }], usage: { input_tokens: 10, output_tokens: 5 }, stop_reason: 'end_turn' } }) };
  const f = new Function('$', '$input', '$json', '$runIndex', 'Date', code);
  return f($, $input, {}, 0, Date)[0].json;
}
const ruim = 'Entendo, Cristiano! Esse pacote de R$85 não bate com o que temos aqui pra sua região. [OBJECAO: preco]';
const a = rodar(ruim, {}, true);
console.log('2a tentativa → texto:', a.texto, '\n  handoff:', a.handoff && a.handoff.motivo, '\n  briefing:', a.handoff && a.handoff.lead.briefing.split('\n').slice(-1)[0], '\n  erro:', a.erro && a.erro.mensagem);
const b = rodar(ruim, {}, false);
console.log('1a tentativa → corrigir:', b.corrigir, b.violacoes);
const ok = rodar('Entendo, Cristiano! Os valores são tabelados pela Nio 😊 Quer que eu te mostre o Fibra?', {}, true);
console.log('2a sem violação → handoff:', ok.handoff, 'texto:', ok.texto.slice(0, 60));
// 12/11 (portão, cenário a): só um parágrafo ruim (upsell sem velocidades) → o resto sai, sem texto de emergência e sem handoff
const resg = rodar('Fechado, Cristiano.\n\nSó pra você saber: por mais R$30 tem o Essencial, bem melhor.\n\nMe manda seu nome completo e CPF?', {}, true);
console.log('resgate → handoff:', resg.handoff, '| emergência:', /só um instante/i.test(resg.texto), '| tag:', (resg.tags || {}).filtro_resgate ? 'sim' : 'não', '| texto:', resg.texto.replace(/\n/g, ' ').slice(0, 90));
