// NIOGEN | n8n/rascunhos/passo4_191126/conferir_local.test.js | 19/11/2026 — Claude Code (Opus 5.5), tarefa niogen-passo4-madrugada
// Sem API, sem n8n, sem banco:  node n8n/rascunhos/passo4_191126/conferir_local.test.js
// (rode antes: python n8n/rascunhos/passo4_191126/montar_rascunho.py)
// Confere (1) os guards novos com respostas do banco de mentira — mesma decisão dos guards de hoje e "sem resposta, não fala";
// (2) nos fluxos-rascunho, nenhum nó muda etiqueta, dono, time ou aberta/resolvida direto no Chatwoot; (3) toda ligação aponta
// para um nó que existe; (4) só os nós do passo 4 mudaram.
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const AQUI = __dirname;
const REPO = path.resolve(AQUI, '..', '..', '..');
let falhas = 0;
function caso(nome, f) {
  try { f(); console.log(`ok  ${nome}`); } catch (e) { falhas++; console.log(`FALHOU  ${nome}: ${e.message}`); }
}
function rodar(arquivo, nodes, entrada) {
  const code = fs.readFileSync(path.join(AQUI, arquivo), 'utf8');
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], itemMatching: () => ({ json: nodes[n] || {} }) });
  const $input = { first: () => ({ json: entrada }), all: () => [{ json: entrada }] };
  return new Function('$', '$input', '$json', code)($, $input, entrada)[0].json;
}

// ── (1a) Mari: 2h ──
const E = { '2 · Entrada': { modo: 'chatwoot', telefone: '5531900000000' } };
caso('2h: banco diz que pode → segue para o 3a', () => {
  const r = rodar('n02h_guard_porta.js', E, { pode: true, motivo: 'situação mari_atendendo', situacao: 'mari_atendendo' });
  assert.strictEqual(r.humano, false);
});
caso('2h: humano atribuído → Mari calada com o motivo', () => {
  const r = rodar('n02h_guard_porta.js', E, { pode: false, motivo: 'humano atribuído' });
  assert.strictEqual(r.humano, true); assert.strictEqual(r.saida.silencio, true); assert.strictEqual(r.saida.motivo, 'humano atribuído');
});
caso('2h: banco sem resposta (erro do nó) → Mari calada', () => {
  const r = rodar('n02h_guard_porta.js', E, { error: { message: 'timeout' } });
  assert.strictEqual(r.humano, true); assert.match(r.saida.motivo, /sem resposta/);
});
caso('2h: modo teste → sem humano, nem pergunta', () => {
  const r = rodar('n02h_guard_porta.js', { '2 · Entrada': { modo: 'teste' } }, {});
  assert.strictEqual(r.humano, false);
});

// ── (1b) cadência: 6h ──
const M = (passo) => ({ '5 · Montar envio': { conversaId: 'c1', passo } });
caso('6h: escada em Mari atendendo → envia', () => {
  const r = rodar('c06_guard_porta.js', M('D3'), { pode: true, parar: false, pessoa: false, time: false, nao_contatar: false });
  assert.strictEqual(r.enviar, true); assert.strictEqual(r.parar, false);
});
caso('6h: escada com pessoa do time → para a escada e não envia', () => {
  const r = rodar('c06_guard_porta.js', M('D3'), { pode: false, parar: true, pessoa: true, time: false, nao_contatar: false });
  assert.strictEqual(r.enviar, false); assert.strictEqual(r.parar, true); assert.strictEqual(r.humano, true);
});
caso('6h: aviso da venda com o time na conversa → envia e nunca para a escada', () => {
  const r = rodar('c06_guard_porta.js', M('VESPERA'), { pode: true, parar: false, pessoa: true, time: true, nao_contatar: false });
  assert.strictEqual(r.enviar, true); assert.strictEqual(r.parar, false);
});
caso('6h: aviso da venda com Não contatar → não envia, não para, vira falha', () => {
  const r = rodar('c06_guard_porta.js', M('VESPERA'), { pode: false, parar: false, nao_contatar: true, motivo: 'não contatar' });
  assert.strictEqual(r.enviar, false); assert.strictEqual(r.parar, false); assert.strictEqual(r.ok, false);
});
caso('6h: banco sem resposta → não envia (falha, não queima o passo)', () => {
  const r = rodar('c06_guard_porta.js', M('D3'), {});
  assert.strictEqual(r.enviar, false); assert.strictEqual(r.parar, false); assert.strictEqual(r.ok, false);
});

// ── (2)(3)(4) os fluxos-rascunho ──
const MUDA_ESTADO = /\/(labels|toggle_status|assignments)\b|"team_id"|"assignee_id"/;
for (const [rasc, orig, mudam] of [
  ['mari_principal_passo4.json', 'mari_principal.json', ['2g', '2h', '2p', '2u', '9e', '9f', '9g', '9h', '9d', '9j', '9k']],
  ['mari_cadencia_passo4.json', 'mari_cadencia.json', ['6g', '6h', '9b', '9c', '9d', '9e', '9f', '9g', '9h']],
]) {
  const w = JSON.parse(fs.readFileSync(path.join(AQUI, rasc), 'utf8'));
  const o = JSON.parse(fs.readFileSync(path.join(REPO, 'n8n', orig), 'utf8'));
  caso(`${rasc}: nenhum nó muda etiqueta, dono, time ou aberta/resolvida no Chatwoot`, () => {
    const ruins = w.nodes.filter((n) => /chatwoot\.com/.test(String(n.parameters?.url || '')) && MUDA_ESTADO.test(JSON.stringify(n.parameters)))
      .map((n) => n.name);
    assert.deepStrictEqual(ruins, []);
  });
  caso(`${rasc}: nenhum guard lê a conversa no Chatwoot (GET)`, () => {
    const ruins = w.nodes.filter((n) => /chatwoot\.com/.test(String(n.parameters?.url || '')) && (n.parameters.method || 'GET') === 'GET'
      && /conversations\/\{\{[^}]*\}\}\s*$/.test(String(n.parameters.url).replace(/["']/g, ''))).map((n) => n.name);
    assert.deepStrictEqual(ruins, []);
  });
  caso(`${rasc}: toda ligação aponta para um nó que existe`, () => {
    const nomes = new Set(w.nodes.map((n) => n.name));
    const quebradas = [];
    for (const [de, v] of Object.entries(w.connections)) {
      if (!nomes.has(de)) quebradas.push(`origem ${de}`);
      for (const s of v.main || []) for (const x of s || []) if (!nomes.has(x.node)) quebradas.push(`${de} → ${x.node}`);
    }
    assert.deepStrictEqual(quebradas, []);
  });
  caso(`${rasc}: só os nós do passo 4 mudaram`, () => {
    const porId = Object.fromEntries(o.nodes.map((n) => [n.id, n]));
    const outros = w.nodes.filter((n) => porId[n.id] && !mudam.includes(n.name.split(' ')[0])
      && JSON.stringify(n.parameters) !== JSON.stringify(porId[n.id].parameters)).map((n) => n.name);
    assert.deepStrictEqual(outros, []);
  });
}
console.log(falhas ? `\n${falhas} FALHARAM` : '\ntudo ok');
process.exit(falhas ? 1 : 0);
