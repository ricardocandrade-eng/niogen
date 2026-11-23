// NIOGEN | tests/mari_n04_local_busca_rua.test.js | 23/11/2026 — Claude Code (busca de rua tolerante a erro de digitação)
// Sem API e sem internet: node tests/mari_n04_local_busca_rua.test.js n8n/mari/n04_preparar.js
// Caso real L-259 (23/11): a cliente escreveu "Travessa gorasiu de Castro Brandão" (o cadastro é "Rua Gorasil de
// Castro Brandão"), não sabia o CEP, e a busca voltou vazia — a Mari pediu o CEP 3 vezes e seguiu sem endereço. Além disso a
// cidade dita ao ver os planos (dados.planos_cidade) não entrava na busca: lead de anúncio caía em Juiz de Fora.
// O ViaCEP é simulado: só responde o que o serviço real respondeu em 23/11 para cada consulta.
const fs = require('fs');
const assert = require('assert');
const code = fs.readFileSync(process.argv[2] || 'n8n/mari/n04_preparar.js', 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const semAcento = (s) => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');

// Ruas do cadastro (ViaCEP, 23/11/2026). A busca do serviço é "contém as palavras, na ordem".
const BASE = {
  uba: [
    { cep: '36506-149', logradouro: 'Rua Gorasil de Castro Brandão', complemento: 'até 99997/99998', bairro: 'Oséas Maranhão', localidade: 'Ubá', uf: 'MG' },
    { cep: '36506-150', logradouro: 'Rua Gorasil de Castro Brandão', complemento: 'de 01/2 ao fim', bairro: 'Antônio Maranhão', localidade: 'Ubá', uf: 'MG' },
    { cep: '36506-058', logradouro: 'Rua Engenheiro Carlos de Oliveira Castro Brandão', complemento: '', bairro: 'Santana', localidade: 'Ubá', uf: 'MG' },
    { cep: '36506-040', logradouro: 'Rua Altivo Brandão', complemento: '', bairro: 'Santana', localidade: 'Ubá', uf: 'MG' },
    { cep: '36500-001', logradouro: 'Rua São José', complemento: '', bairro: 'Centro', localidade: 'Ubá', uf: 'MG' },
  ],
  'juiz de fora': [
    { cep: '36035-130', logradouro: 'Rua dos Artistas', complemento: '', bairro: 'Morro da Glória', localidade: 'Juiz de Fora', uf: 'MG' },
    { cep: '36010-020', logradouro: 'Rua Halfeld', complemento: '', bairro: 'Centro', localidade: 'Juiz de Fora', uf: 'MG' },
  ],
};
function viacep(url, chamadas) {
  chamadas.push(url);
  const m = decodeURIComponent(url).match(/\/ws\/MG\/([^/]+)\/([^/]+)\/json/);
  if (!m) {   // consulta por CEP
    const c = (url.match(/\/ws\/(\d{8})\/json/) || [])[1];
    const x = Object.values(BASE).flat().find((r) => r.cep.replace('-', '') === c);
    return x || { erro: true };
  }
  const lista = BASE[semAcento(m[1])] || [];
  const termos = semAcento(m[2]).split(/\s+/).filter(Boolean);
  return lista.filter((r) => {
    const nome = semAcento(r.logradouro); let pos = 0;
    return termos.every((t) => { const i = nome.indexOf(t, pos); if (i < 0) return false; pos = i + t.length; return true; });
  });
}
async function rodar(msg, conv, historico) {
  const chamadas = [];
  const ctx = { helpers: { httpRequest: async ({ url }) => viacep(url, chamadas) } };
  const $input = { first: () => ({ json: { mensagem: msg, historico: historico || [],
    conversa: Object.assign({ id: 'c1', etapa: 'endereco', origem: 'meta_ads', dados: {} }, conv) } }) };
  const out = (await new AsyncFunction('$input', code).call(ctx, $input))[0].json;
  out._chamadas = chamadas;
  return out;
}
let falhas = 0;
async function caso(nome, f) {
  try { await f(); console.log(`ok  ${nome}`); } catch (e) { falhas++; console.log(`FALHOU  ${nome}: ${e.message}`); }
}
const ceps = (o) => (o.opcoesRua || []).map((x) => x.cep);

(async () => {
  const RUA_ERRADA = 'Travessa gorasiu de Castro Brandão número 120 bairro centro';

  await caso('L-259: nome com erro de digitação acha a rua (2 CEPs da mesma rua, por bairro)', async () => {
    const o = await rodar(RUA_ERRADA, { cidade: 'Ubá' });
    assert.ok(!o.ruaNaoAchada, `disse que não achou «${o.ruaNaoAchada}»`);
    assert.ok(o.p_cep === '36506150' || ceps(o).includes('36506-150'), `o CEP 36506-150 não veio: p_cep=${o.p_cep} opções=${JSON.stringify(ceps(o))}`);
    assert.ok(!ceps(o).includes('36506-058'), 'ofereceu a rua do Engenheiro Carlos, que não é a do cliente');
  });

  await caso('L-259: a cidade dita ao ver os planos entra na busca (lead de anúncio não cai em Juiz de Fora)', async () => {
    const o = await rodar(RUA_ERRADA, { cidade: null, dados: { planos_cidade: 'Ubá' } });
    assert.ok(o._chamadas.length && o._chamadas.every((u) => /\/MG\/Ub/i.test(decodeURIComponent(u))), `buscou em outra cidade: ${o._chamadas.map(decodeURIComponent).join(' | ')}`);
    assert.ok(o.p_cep === '36506150' || ceps(o).includes('36506-150'), `o CEP 36506-150 não veio: p_cep=${o.p_cep} opções=${JSON.stringify(ceps(o))}`);
  });

  await caso('nome certo continua como antes (sem busca a mais)', async () => {
    const o = await rodar('Moro na Rua dos Artistas, 123', { cidade: 'Juiz de Fora' });
    assert.strictEqual(o.p_cep, '36035130');
    assert.strictEqual(o._chamadas.filter((u) => /\/MG\//.test(u)).length, 1, 'fez mais de uma busca por nome para uma rua exata');
  });

  await caso('uma palavra só com erro ("Rua Halfed") acha a Rua Halfeld', async () => {
    const o = await rodar('Rua Halfed, 500', { cidade: 'Juiz de Fora' });
    assert.strictEqual(o.p_cep, '36010020', `p_cep=${o.p_cep} não achada=${o.ruaNaoAchada}`);
  });

  await caso('rua que não existe continua "não achada" (nunca chuta outra rua)', async () => {
    const o = await rodar('Rua Zebulon Xavier Brandão, 10', { cidade: 'Ubá' });
    assert.ok(!o.p_cep && !o.opcoesRua, `chutou: p_cep=${o.p_cep} opções=${JSON.stringify(ceps(o))}`);
    assert.ok(o.ruaNaoAchada, 'não avisou que não achou');
  });

  await caso('palavra trocada não é erro de digitação ("Gorasil de Castro Pereira" não vira "…Brandão")', async () => {
    const o = await rodar('Rua Gorasil de Castro Pereira, 120', { cidade: 'Ubá' });
    assert.ok(!o.p_cep && !o.opcoesRua, `chutou: p_cep=${o.p_cep} opções=${JSON.stringify(ceps(o))}`);
  });

  console.log(falhas ? `\n${falhas} falha(s)` : '\ntudo verde');
  process.exit(falhas ? 1 : 0);
})();
