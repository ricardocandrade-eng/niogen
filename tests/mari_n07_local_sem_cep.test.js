// NIOGEN | tests/mari_n07_local_sem_cep.test.js | 23/11/2026 — Claude Code (cliente que não sabe o CEP, P48)
// Sem API: node tests/mari_n07_local_sem_cep.test.js
// Caso real L-259 (23/11): a rua não foi achada pelo nome, o cliente disse "eu não sei o CEP" e a Mari seguiu para nome, CPF,
// e-mail e pagamento sem endereço, sem cobertura e sem plano — e passou ao time como "VENDA PRONTA".
// Agora: rua não achada + "não sei o CEP" → a Mari passa NA HORA ao consultor, que localiza o endereço (determinístico).
const fs = require('fs');
const assert = require('assert');
const n07 = fs.readFileSync('n8n/mari/n07_extrair.js', 'utf8');
const n04 = fs.readFileSync('n8n/mari/n04_preparar.js', 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

async function preparar(msg, conv, historico) {
  const ctx = { helpers: { httpRequest: async () => [] } };   // ViaCEP não acha nada
  const $input = { first: () => ({ json: { mensagem: msg, historico: historico || [],
    conversa: Object.assign({ id: 'c1', etapa: 'endereco', origem: 'meta_ads', cidade: 'Ubá', dados: {} }, conv) } }) };
  return (await new AsyncFunction('$input', n04).call(ctx, $input))[0].json;
}
function extrair(bruto, conv, prep, msg, dentroHorario) {
  const nodes = {
    '5b · Motor': { ctx: { conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', dentroHorario: dentroHorario !== false, planos: [],
      conversa: Object.assign({ id: 'c1', etapa: 'endereco', cidade: 'Ubá', nome_contato: 'Ana', nome_confiavel: true, dados: {} }, conv) } },
    '4 · Preparar': Object.assign({ consolidado: { mensagem: msg || 'Eu não sei o cep', historico: [] } }, prep),
    '2 · Entrada': { modo: 'chatwoot' },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const $input = { first: () => ({ json: { content: [{ type: 'text', text: bruto }], usage: {}, stop_reason: 'end_turn' } }) };
  return new Function('$', '$input', '$json', '$runIndex', n07)($, $input, {}, 0)[0].json;
}
let falhas = 0;
async function caso(nome, f) {
  try { await f(); console.log(`ok  ${nome}`); } catch (e) { falhas++; console.log(`FALHOU  ${nome}: ${e.message}`); }
}
const MARI_IMPROVISA = 'Com só o nome da rua eu não consigo confirmar o CEP por aqui. Pra eu seguir, me manda seu nome completo e CPF?';
const RUA = 'Rua Zebulon Xavier Quaresma';

(async () => {
  await caso('4 · Preparar: "Eu não sei  cep" (e o áudio "Eu não sei o CEP…") marca naoSabeCep', async () => {
    for (const m of ['Eu não sei  cep', '🎤 (áudio) Eu não sei o CEP. Se procurar aí o nome da rua, se consegue achar o CEP.', 'nao lembro o cep', 'To sem o cep aqui']) {
      const o = await preparar(m, {});
      assert.ok(o.naoSabeCep, `não marcou em «${m}»`);
    }
  });
  await caso('4 · Preparar: quem manda o CEP ou só fala do CEP não é "não sei"', async () => {
    for (const m of ['Meu cep é 36500-001', 'Qual cep?', 'Não sei se chega aqui']) {
      const o = await preparar(m, {});
      assert.ok(!o.naoSabeCep, `marcou em «${m}»`);
    }
    const o = await preparar('não sei o cep', { cep: '36500001' });
    assert.ok(!o.naoSabeCep, 'marcou com o CEP já gravado');
  });

  await caso('rua não achada + "não sei o CEP" → passa ao consultor na hora, sem pedir CPF', async () => {
    const r = extrair(MARI_IMPROVISA, {}, { naoSabeCep: true, ruaNaoAchada: RUA });
    assert.ok(r.handoff, 'sem handoff');
    assert.strictEqual(r.handoff.motivo, 'pedido_humano');
    assert.ok(!/cpf|nome completo|nao consigo|não consigo/i.test(r.texto || ''), `fala: «${r.texto}»`);
    assert.match(r.texto, /localizar o seu endereço/);
    assert.match(r.texto, /em até 2 horas/);
    const b = r.handoff.lead.briefing;
    assert.ok(!/VENDA PRONTA/.test(b), 'título de venda pronta');
    assert.match(b, /não sabe o CEP/); assert.match(b, /Zebulon/); assert.match(b, /Fazer agora: Achar o CEP/);
  });
  await caso('fora do horário a promessa é "no próximo horário de atendimento"', async () => {
    const r = extrair(MARI_IMPROVISA, {}, { naoSabeCep: true, ruaNaoAchada: RUA }, null, false);
    assert.match(r.texto, /no próximo horário de atendimento/);
  });
  await caso('a rua não achada num turno anterior (guardada na conversa) também vale', async () => {
    const r = extrair(MARI_IMPROVISA, { dados: { rua_nao_achada: RUA } }, { naoSabeCep: true });
    assert.ok(r.handoff && r.handoff.motivo === 'pedido_humano', 'sem handoff');
  });
  await caso('"não sei o CEP" sem rua nenhuma → a Mari segue (pede a rua e o bairro), sem handoff', async () => {
    const r = extrair('Sem problema! Me manda o nome da rua e o bairro que eu localizo.', {}, { naoSabeCep: true });
    assert.ok(!r.handoff, 'passou ao time sem ter tentado a rua');
    assert.match(r.texto, /nome da rua/);
  });
  await caso('com opções de rua na mesa, não passa ao time', async () => {
    const r = extrair('Achei estas, qual é a sua?', {}, { naoSabeCep: true, ruaNaoAchada: null, opcoesRua: [{ logradouro: 'Rua A', bairro: 'B', cep: '36500-001' }] });
    assert.ok(!r.handoff, 'passou ao time com opções para o cliente escolher');
  });
  await caso('com CEP gravado nada muda', async () => {
    const r = extrair('E o número da casa?', { cep: '36500001' }, { naoSabeCep: true, ruaNaoAchada: RUA });
    assert.ok(!r.handoff, 'passou ao time com o CEP já gravado');
  });
  await caso('a rua não achada fica guardada na conversa', async () => {
    const r = extrair('Não achei essa rua. Me passa o CEP?', {}, { ruaNaoAchada: RUA }, 'Rua Zebulon Xavier Quaresma, 10');
    assert.ok(JSON.stringify(r).includes('rua_nao_achada'), 'rua_nao_achada não foi gravada');
  });

  console.log(falhas ? `\n${falhas} falha(s)` : '\ntudo verde');
  process.exit(falhas ? 1 : 0);
})();
