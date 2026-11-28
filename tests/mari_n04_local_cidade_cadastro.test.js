// NIOGEN | tests/mari_n04_local_cidade_cadastro.test.js | 27/11/2026 — Claude Code (cidade do cadastro da Fila Vero na busca de rua)
// Sem API e sem internet: node tests/mari_n04_local_cidade_cadastro.test.js n8n/mari/n04_preparar.js
// Caso real L-456 (27/11): lead da Fila Vero (cadastro: Juiz de Fora) respondeu "Rua das perolas ,Marilândia" ao pedido de rua e
// bairro. Sem cidade na conversa e com origem fila_vero, a busca de rua não rodava (só anúncio tinha cidade de partida): a Mari
// recebeu "rua sem cidade", tomou o bairro por município ("é em Marilândia mesmo, aí perto de Vitória/ES?") e o cliente sumiu.
// O ViaCEP é simulado: só responde o que o serviço real respondeu em 27/11 para a consulta.
const fs = require('fs');
const assert = require('assert');
const code = fs.readFileSync(process.argv[2] || 'n8n/mari/n04_preparar.js', 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const semAcento = (s) => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');

const BASE = {
  'juiz de fora': [
    { cep: '36039-380', logradouro: 'Rua das Pérolas', complemento: '', bairro: 'Marilândia', localidade: 'Juiz de Fora', uf: 'MG' },
    { cep: '36010-020', logradouro: 'Rua Halfeld', complemento: '', bairro: 'Centro', localidade: 'Juiz de Fora', uf: 'MG' },
  ],
  barbacena: [
    { cep: '36200-100', logradouro: 'Rua das Pérolas', complemento: '', bairro: 'Santa Tereza', localidade: 'Barbacena', uf: 'MG' },
  ],
};
function viacep(url, chamadas) {
  chamadas.push(url);
  const m = decodeURIComponent(url).match(/\/ws\/MG\/([^/]+)\/([^/]+)\/json/);
  if (!m) {
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
async function rodar(msg, conv, extra) {
  const chamadas = [];
  const ctx = { helpers: { httpRequest: async ({ url }) => viacep(url, chamadas) } };
  const $input = { first: () => ({ json: Object.assign({ mensagem: msg, historico: [],
    conversa: Object.assign({ id: 'c1', etapa: 'endereco', origem: 'fila_vero', dados: {} }, conv) }, extra || {}) }) };
  const out = (await new AsyncFunction('$input', code).call(ctx, $input))[0].json;
  out._chamadas = chamadas;
  return out;
}
let falhas = 0;
async function caso(nome, f) {
  try { await f(); console.log(`ok  ${nome}`); } catch (e) { falhas++; console.log(`FALHOU  ${nome}: ${e.message}`); }
}
const buscas = (o) => o._chamadas.filter((u) => /\/MG\//.test(u)).map(decodeURIComponent);

(async () => {
  const FALA = 'Rua das perolas ,Marilândia';

  await caso('L-456: lead da Fila Vero sem cidade na conversa busca a rua na cidade do cadastro e acha o CEP', async () => {
    const o = await rodar(FALA, { cidade: null }, { cidade_cadastro: 'Juiz de Fora' });
    assert.ok(!o.ruaSemCidade, `ficou "rua sem cidade": «${o.ruaSemCidade}»`);
    assert.strictEqual(o.p_cep, '36039380', `p_cep=${o.p_cep} não achada=${o.ruaNaoAchada} buscas=${buscas(o).join(' | ')}`);
    assert.strictEqual((o.cepDaBusca || {}).bairro, 'Marilândia', 'o bairro da busca não veio para a Mari confirmar');
  });

  await caso('a cidade do cadastro é a do lead, não Juiz de Fora fixo (cadastro de Barbacena busca em Barbacena)', async () => {
    const o = await rodar(FALA, { cidade: null }, { cidade_cadastro: 'Barbacena' });
    assert.ok(buscas(o).length && buscas(o).every((u) => /\/MG\/Barbacena\//i.test(u)), `buscou em outra cidade: ${buscas(o).join(' | ')}`);
    assert.strictEqual(o.p_cep, '36200100', `p_cep=${o.p_cep}`);
  });

  await caso('a cidade que a conversa já tem vale antes do cadastro', async () => {
    const o = await rodar(FALA, { cidade: 'Barbacena' }, { cidade_cadastro: 'Juiz de Fora' });
    assert.ok(buscas(o).every((u) => /\/MG\/Barbacena\//i.test(u)), `buscou em outra cidade: ${buscas(o).join(' | ')}`);
  });

  await caso('a cidade que o cliente disse para ver os planos vale antes do cadastro', async () => {
    const o = await rodar(FALA, { cidade: null, dados: { planos_cidade: 'Barbacena' } }, { cidade_cadastro: 'Juiz de Fora' });
    assert.ok(buscas(o).every((u) => /\/MG\/Barbacena\//i.test(u)), `buscou em outra cidade: ${buscas(o).join(' | ')}`);
  });

  await caso('sem cidade no cadastro continua "rua sem cidade" (a Mari pergunta, não chuta)', async () => {
    const o = await rodar(FALA, { cidade: null }, {});
    assert.ok(o.ruaSemCidade, 'não avisou que falta a cidade');
    assert.strictEqual(buscas(o).length, 0, `buscou sem cidade: ${buscas(o).join(' | ')}`);
  });

  await caso('rua que não existe na cidade do cadastro vira "não achada" (a Mari pede o CEP, não inventa cidade)', async () => {
    const o = await rodar('Rua Zebulon Xavier, 10', { cidade: null }, { cidade_cadastro: 'Juiz de Fora' });
    assert.ok(!o.p_cep && !o.opcoesRua && o.ruaNaoAchada, `p_cep=${o.p_cep} naoAchada=${o.ruaNaoAchada}`);
  });

  console.log(falhas ? `\n${falhas} falha(s)` : '\ntudo verde');
  process.exit(falhas ? 1 : 0);
})();
