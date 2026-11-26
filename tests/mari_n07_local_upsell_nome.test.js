// NIOGEN | tests/mari_n07_local_upsell_nome.test.js | 21/11/2026 — Claude Code / Opus 5.5 (conversa L-222, #202; e L-40)
// Sem API: node tests/mari_n07_local_upsell_nome.test.js n8n/mari/n07_extrair.js
// (1) Upsell: a resposta da sugestão termina na pergunta "fica ou troca" (com botões) — nunca pede nome/CPF junto. Enquanto o
//     cliente não responde, nenhuma fala pede os dados; respondeu → o pedido de nome e CPF vem na hora.
// (2) Nome: frase do cliente ("Am n entende", "Moro acima do bar") nunca vira nome; nome ruim já gravado é trocado pelo certo.
const fs = require('fs');
const assert = require('assert');
const code = fs.readFileSync(process.argv[2] || 'n8n/mari/n07_extrair.js', 'utf8');
const PLANOS = [
  { codigo: 'V-REG-FIBRA', nome: 'Nio Fibra 600 Mega', portfolio: 'varejo', variante: 'regular', preco: '110.00', preco_cartao: '95', velocidade_mb: 600, taxa_habilitacao: '540', isencao_meses: 12, wifi: 'Wi-Fi 6' },
  { codigo: 'V-REG-ESS', nome: 'Nio Essencial 800 Mega + 10 GB', portfolio: 'varejo', variante: 'regular', preco: '140.00', preco_cartao: '125', velocidade_mb: 800, taxa_habilitacao: '540', isencao_meses: 12, wifi: 'Wi-Fi 6' },
  { codigo: 'V-REG-SUP', nome: 'Nio Super 1 Giga + 20 GB', portfolio: 'varejo', variante: 'regular', preco: '170.00', preco_cartao: '155', velocidade_mb: 1000, taxa_habilitacao: '540', isencao_meses: 12, wifi: 'Wi-Fi 6' },
  { codigo: 'V-REG-ULT', nome: 'Nio Ultra 1 Giga + Mesh + 2×20 GB', portfolio: 'varejo', variante: 'regular', preco: '200.00', preco_cartao: '185', velocidade_mb: 1000, taxa_habilitacao: '540', isencao_meses: 12, wifi: 'Wi-Fi 6' },
];
function rodar(bruto, conv, hist, msg, extraCtx) {
  const nodes = {
    '5b · Motor': { ctx: Object.assign({ conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', dentroHorario: true,
      planos: PLANOS, segmento: 'varejo',
      conversa: Object.assign({ id: 'c1', etapa: 'planos', cidade: 'Contagem', cep: '32050080', numero: '861', complemento: 'Casa A',
        elegibilidade: 'ok', status: 'ativo', dados: { telefone: '31999999999', telefone_confirmado: true } }, conv) }, extraCtx || {}) },
    '4 · Preparar': { consolidado: { mensagem: msg, historico: hist || [] } },
    '2 · Entrada': { modo: 'teste' },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const $input = { first: () => ({ json: { content: [{ type: 'text', text: bruto }], usage: {}, stop_reason: 'end_turn' } }) };
  return new Function('$', '$input', '$json', '$runIndex', code)($, $input, {}, 0)[0].json;
}
const tudo = (r) => [r.texto || '', ...((r.baloes) || []), (r.interativo || {}).corpo || ''].join('\n');
const pedeDados = (t) => /nome completo|\bcpf\b/i.test(t);
let falhas = 0;
function caso(nome, f) {
  try { f(); console.log(`ok  ${nome}`); } catch (e) { falhas++; console.log(`FALHOU  ${nome}: ${e.message}`); }
}

// ───── (1) upsell ─────
const UPSELL_1 = 'Fechado, então: Essencial por R$140 por mês (R$125 no cartão).\n\nSe quiser, por mais R$30 o Super vai de 800 Mega pra 1 Giga e já vem com 20 GB de 5G, chamadas ilimitadas e Globoplay por 12 meses. Mas o Essencial já atende super bem.'
  + '\n||\n[CONDICOES]\n||\nFechou? Me manda seu nome completo e CPF que eu já adianto aqui.\n[PLANO_ESCOLHIDO: V-REG-ESS]\n[UPSELL_OFERECIDO]';
caso('upsell: a resposta da sugestão não pede nome/CPF e termina com os botões fica/troca', () => {
  const r = rodar(UPSELL_1, {}, [{ papel: 'mari', texto: 'Aqui estão as opções pra você' }], 'Quero o plano Nio Essencial');
  const t = tudo(r);
  assert.ok(/as condi[cç][oõ]es do seu plano/i.test(t), 'sem as condições');
  assert.ok(!pedeDados(t), `pediu nome/CPF junto com a sugestão: «${t.slice(-200)}»`);
  assert.ok(r.interativo && r.interativo.chave === 'upsell', `sem os botões do upsell: ${JSON.stringify(r.interativo)}`);
  const tit = r.interativo.botoes.map((b) => b.title);
  assert.deepStrictEqual(tit, ['Fico no Essencial', 'Quero o Super']);
  assert.ok(tit.every((x) => x.length <= 20), 'título de botão com mais de 20 caracteres');
  assert.ok(/essencial[^?]*super[^?]*\?/i.test(r.interativo.corpo), `pergunta fica/troca ausente: «${r.interativo.corpo}»`);
});
const PEND = { plano_escolhido: 'V-REG-ESS', upsell_oferecido: true, lgpd_enviada: false, etapa: 'coleta' };
const HIST_PEND = [{ papel: 'mari', texto: 'Fica no Essencial ou prefere o Super?\n\n[botões: Fico no Essencial / Quero o Super]' }];
caso('upsell pendente: "Am n entende" → explica e pergunta de novo, sem pedir CPF', () => {
  const r = rodar('Sem problema, deixa eu explicar de outro jeito 😊\n\nVocê escolheu o Nio Essencial: 800 Mega, por R$140 por mês no boleto ou R$125 no cartão.\n\nPra eu seguir com o seu pedido, só preciso do seu nome completo e do seu CPF. Pode me mandar?',
    PEND, HIST_PEND, 'Am n entende', { condicoesEnviadas: true });
  const t = tudo(r);
  assert.ok(!pedeDados(t), `pediu nome/CPF com o upsell sem resposta: «${t.slice(-220)}»`);
  assert.ok(r.interativo && r.interativo.chave === 'upsell', 'sem os botões do upsell na 2ª pergunta');
  assert.ok(/explicar de outro jeito/.test(t), 'a explicação do modelo sumiu');
});
caso('upsell pendente: "Fico no Essencial" → grava a resposta e pede nome e CPF', () => {
  const r = rodar('Combinado, fica o Essencial então 😊', PEND, HIST_PEND, 'Fico no Essencial', { condicoesEnviadas: true });
  const t = tudo(r);
  assert.ok(pedeDados(t), `não pediu nome/CPF depois da resposta: «${t}»`);
  assert.strictEqual(((r.upd || {}).dados || {}).upsell_resposta, 'fica');
  assert.ok(!r.interativo || r.interativo.chave !== 'upsell', 'perguntou o upsell de novo');
});
caso('upsell pendente: "Quero o Super" → troca o plano e pede nome e CPF', () => {
  const r = rodar('Boa! O Super por R$170 por mês (R$155 no cartão) tá ótimo.', PEND, HIST_PEND, 'Quero o Super', { condicoesEnviadas: true });
  assert.strictEqual((r.upd || {}).plano_escolhido, 'V-REG-SUP');
  assert.strictEqual(((r.upd || {}).dados || {}).upsell_resposta, 'troca');
  assert.ok(pedeDados(tudo(r)), 'não pediu nome/CPF depois da troca');
});
caso('upsell pendente: o cliente manda o CPF direto → vale como "fica", sem pergunta de novo', () => {
  const r = rodar('Perfeito, obrigada! Agora me conta seu nome completo?', PEND, HIST_PEND, '529.982.247-25', { condicoesEnviadas: true });
  assert.strictEqual(((r.upd || {}).dados || {}).upsell_resposta, 'fica');
  assert.ok(!r.interativo || r.interativo.chave !== 'upsell', 'perguntou o upsell depois do CPF');
});
caso('upsell pendente: depois de 2 perguntas sem resposta, segue (vale "fica") e pede os dados', () => {
  const r = rodar('O chip vem incluso no plano, com 10 GB de 5G 😊', { ...PEND, dados: { telefone: '31999999999', upsell_perguntas: 2 } }, HIST_PEND, 'Tem chip?', { condicoesEnviadas: true });
  assert.strictEqual(((r.upd || {}).dados || {}).upsell_resposta, 'fica');
  assert.ok(pedeDados(tudo(r)), 'não pediu os dados depois das 2 perguntas');
});

// ───── (2) nome ─────
caso('nome: "Am n entende" depois do pedido de nome e CPF não vira nome', () => {
  const r = rodar('Sem problema, deixa eu explicar de outro jeito 😊', { plano_escolhido: 'V-REG-ESS', upsell_oferecido: true, dados: { telefone: '31999999999', upsell_resposta: 'fica' } },
    [{ papel: 'mari', texto: 'Fechou? Me manda seu nome completo e CPF que eu já adianto aqui.' }], 'Am n entende', { condicoesEnviadas: true });
  assert.ok(!(((r.upd || {}).dados || {}).nome), `gravou nome: ${JSON.stringify((r.upd || {}).dados)}`);
});
caso('nome: "Moro acima do bar" depois de "…no seu nome?" não vira nome (L-40)', () => {
  const r = rodar('Entendi, bom ponto de referência esse!', { dados: { telefone: '31999999999' } },
    [{ papel: 'mari', texto: 'Ela está ativa nessa unidade (Ap 01) hoje, no seu nome?' }], 'Moro acima do bar');
  assert.ok(!(((r.upd || {}).dados || {}).nome), `gravou nome: ${JSON.stringify((r.upd || {}).dados)}`);
});
caso('nome: nome ruim já gravado é trocado pelo nome certo ("Gizele Odile")', () => {
  const r = rodar('Agora preciso do seu melhor e-mail', { plano_escolhido: 'V-REG-ESS', dados: { telefone: '31999999999', cpf: '52998224725', nome: 'Am n entende', upsell_resposta: 'fica' } },
    [{ papel: 'mari', texto: 'Perfeito, obrigada! Agora me conta seu nome completo, pra eu seguir com o pedido?' }], 'Gizele odile', { condicoesEnviadas: true });
  assert.strictEqual(((r.upd || {}).dados || {}).nome, 'Gizele odile');
});
caso('nome: o nome que o modelo marcar como frase não entra; o certo entra', () => {
  const r1 = rodar('Anotado!\n[DADOS_COLETADOS: nome=Am n entende]', { dados: { telefone: '31999999999' } }, [], 'Am n entende');
  assert.ok(!(((r1.upd || {}).dados || {}).nome), `gravou nome da marca: ${JSON.stringify((r1.upd || {}).dados)}`);
  const r2 = rodar('Anotado!\n[DADOS_COLETADOS: nome=Maria das Dores]', { dados: { telefone: '31999999999' } }, [], 'Maria das Dores');
  assert.strictEqual(((r2.upd || {}).dados || {}).nome, 'Maria das Dores');
});
caso('nome: nome de verdade com "da/de/dos" e 1 letra no meio continua valendo', () => {
  const r = rodar('Perfeito! Agora o seu melhor e-mail?', { dados: { telefone: '31999999999' } },
    [{ papel: 'mari', texto: 'Me passa seu nome completo?' }], 'Edson J dos Santos');
  assert.strictEqual(((r.upd || {}).dados || {}).nome, 'Edson J dos Santos');
});
// ───── 26/11 (L-272, P55): frase de espera depois do pedido de nome; nome solto entra provisório ─────
const PEDIU = [{ papel: 'mari', texto: 'Podemos continuar? Me manda seu nome completo e CPF que eu já adianto o seu cadastro.' }];
for (const frase of ['Pera ai', 'Calma la', 'Um momentinho', 'Ja volto', 'Eita perai', 'Ok ta']) {
  caso(`nome: "${frase}" depois do pedido de nome completo não vira nome (L-272)`, () => {
    const r = rodar('Sem pressa! Fico aqui 😊', { plano_escolhido: 'V-REG-FIBRA', dados: { telefone: '31999999999' } }, PEDIU, frase, { condicoesEnviadas: true });
    assert.ok(!(((r.upd || {}).dados || {}).nome), `gravou nome: ${JSON.stringify((r.upd || {}).dados)}`);
  });
}
caso('nome: nome solto sem CPF entra como provisório; com CPF válido já na conversa, não', () => {
  const r = rodar('Perfeito! E o CPF?', { plano_escolhido: 'V-REG-FIBRA', dados: { telefone: '31999999999' } }, PEDIU, 'Julio Teste da Silva', { condicoesEnviadas: true });
  assert.strictEqual(r.upd.dados.nome, 'Julio Teste da Silva');
  assert.strictEqual(r.upd.dados.nome_provisorio, true);
  const r2 = rodar('Perfeito! Agora o e-mail?', { plano_escolhido: 'V-REG-FIBRA', dados: { telefone: '31999999999', cpf: '52998224725' } }, PEDIU, 'Julio Teste da Silva', { condicoesEnviadas: true });
  assert.strictEqual(r2.upd.dados.nome, 'Julio Teste da Silva');
  assert.ok(!r2.upd.dados.nome_provisorio, 'provisório mesmo com CPF válido');
});
// ───── 26/11 (P56): o 1º nome do WhatsApp não sai como vocativo se o cliente não o informou ─────
caso('vocativo: apelido do WhatsApp sai da resposta ("Tudo certo, Mamãe!" → "Tudo certo!")', () => {
  const r = rodar('Tudo certo, Mamãe! 😊 Se mudar de ideia, é só me chamar aqui.', { nome_contato: 'Mamãe', nome_confiavel: false, dados: { telefone: '31999999999' } }, [], 'vou pensar');
  assert.ok(!/mam[aã]e/i.test(tudo(r)), `ficou o apelido: «${tudo(r)}»`);
  assert.ok(/^Tudo certo! /.test(r.texto), `texto estragado: «${r.texto}»`);
});
caso('vocativo: cliente identificado como Maria e WhatsApp "Cidinha 🥰" → "Cidinha" sai, "Maria" fica', () => {
  const cv = { nome_contato: 'Cidinha 🥰', nome_confiavel: true, dados: { telefone: '31999999999', nome: 'Maria Aparecida Leandro' } };
  const r = rodar('Imagina, Cidinha! 💚', cv, [], 'obrigada');
  assert.ok(!/cidinha/i.test(tudo(r)), `ficou o apelido: «${tudo(r)}»`);
  const r2 = rodar('Imagina, Maria! 💚', cv, [], 'obrigada');
  assert.ok(/Maria/.test(tudo(r2)), `tirou o nome certo: «${tudo(r2)}»`);
});
caso('vocativo: WhatsApp "Julio Teixeira" e cliente informou "Júlio" → o nome fica', () => {
  const r = rodar('Sem pressa, Julio! Fico aqui 😊', { nome_contato: 'Julio Teixeira', nome_confiavel: true, dados: { telefone: '31999999999', nome: 'Júlio' } }, [], 'pera');
  assert.ok(/Julio/.test(tudo(r)), `tirou o nome certo: «${tudo(r)}»`);
});

console.log(falhas ? `\n${falhas} FALHOU` : '\ntudo ok');
process.exit(falhas ? 1 : 0);
