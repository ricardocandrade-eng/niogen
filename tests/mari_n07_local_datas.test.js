// NIOGEN | tests/mari_n07_local_datas.test.js | 12/11/2026 — Claude Code. Sem API: node tests/mari_n07_local_datas.test.js n8n/mari/n07_extrair.js
// Datas D+1/D+2/D+3 em botões depois do pagamento, depois Manhã/Tarde; sem_cobertura pode ser dito; pedido em aberto na nota.
const fs = require('fs');
const code = fs.readFileSync(process.argv[2], 'utf8');
const _h = new Date(new Date().toLocaleString('en-US', { timeZone: 'America/Sao_Paulo' }));
const _a = new Date(_h.getFullYear(), _h.getMonth(), _h.getDate() + 1);
const AMANHA = `${_a.getFullYear()}-${String(_a.getMonth() + 1).padStart(2, '0')}-${String(_a.getDate()).padStart(2, '0')}`;
function rodar(bruto, conv, msg, hist) {
  const nodes = {
    '5b · Motor': { ctx: { conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', planos: [], dentroHorario: true,
      inter: { textos: {}, feriados: [{ data: AMANHA, cidade: '' }, { data: '2099-01-01', cidade: 'Outra' }] },
      conversa: Object.assign({ id: 'c1', etapa: 'coleta', cidade: 'Contagem', cep: '32000000', numero: '10', complemento: 'casa',
        elegibilidade: 'ok', plano_escolhido: 'fibra', forma_pagamento: 'boleto', status: 'ativo',
        dados: { nome: 'Eli Teste', cpf: '52998224725', telefone: '31999999999', email: 'a@b.com', referencia: 'x' } }, conv) } },
    '4 · Preparar': { consolidado: { mensagem: msg, historico: hist || [] } },
    '4c · Supabase interativo': { textos: {} }, '2 · Entrada': { modo: 'chatwoot' },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const $input = { first: () => ({ json: { content: [{ type: 'text', text: bruto }], usage: {}, stop_reason: 'end_turn' } }) };
  return new Function('$', '$input', '$json', '$runIndex', code)($, $input, {}, 0)[0].json;
}
let falhas = 0; const ok = (c, n) => { console.log((c ? 'ok   ' : 'FALHOU ') + n); if (!c) falhas++; };
// 1) pagou no boleto → botões de data (modelo perguntou manhã/tarde: a pergunta sai)
let r = rodar('Fechado.\n\nPra instalação, você prefere manhã ou tarde? O nosso time confirma a data por aqui.', {}, 'Boleto bancário');
ok(r.interativo && r.interativo.chave === 'data' && r.interativo.botoes.length === 3, '1 · pagamento escolhido → 3 botões de data');
ok(!/manh/i.test(r.texto.split('[')[0]) || !/tarde\?/i.test(r.texto), '1 · pergunta de manhã/tarde removida');
ok(r.interativo && r.interativo.botoes.every((b) => !/^Dom/.test(b.title)), '1 · nenhum domingo');
ok(r.interativo && r.interativo.botoes.every((b) => b.id !== `dt:${AMANHA}`), '1 · feriado (amanhã, no teste) fica de fora');
console.log('   datas:', r.interativo && r.interativo.botoes.map((b) => b.title).join(' | '));
// 2) escolheu a data → grava instalacao_data e pede o turno
const dt = r.interativo ? r.interativo.botoes[1].title : 'Sex, 13/11';
r = rodar('Perfeito!', {}, dt);
ok(r.upd && r.upd.dados && r.upd.dados.instalacao_data === dt, '2 · data escolhida gravada em dados.instalacao_data');
ok(r.interativo && r.interativo.chave === 'turno', '2 · depois da data → botões Manhã/Tarde');
// 3) escolheu o turno → instalacao_preferencia = data + período
r = rodar('Show!\n[DADOS_COLETADOS: nome=Eli Teste; cpf=52998224725; email=a@b.com; pagamento=boleto; instalacao=manhã]', { dados: { nome: 'Eli Teste', cpf: '52998224725', telefone: '31999999999', email: 'a@b.com', referencia: 'x', instalacao_data: dt } }, 'Manhã');
ok(r.upd && r.upd.instalacao_preferencia === `${dt}, manhã`, `3 · preferência = "${dt}, manhã" (veio ${r.upd && r.upd.instalacao_preferencia})`);
ok(!r.interativo || !['data', 'turno'].includes(r.interativo.chave), '3 · com o período, não pergunta de novo');
// 4) sem_cobertura: a fala de "não chega" passa no filtro; sem decisão, continua barrada
r = rodar('Poxa, Eli, infelizmente a fibra da Nio ainda não chegou no seu endereço 😕 Deixei seu interesse registrado.\n[HANDOFF]\nmotivo_handoff: sem_cobertura\n[/HANDOFF]', { cobertura_decisao: 'sem_cobertura', forma_pagamento: null, plano_escolhido: null, etapa: 'planos' }, 'ok');
ok(!r.corrigir && r.handoff && r.handoff.motivo === 'sem_cobertura', '4 · sem_cobertura: aviso + handoff sem_cobertura passam');
r = rodar('Poxa, infelizmente a fibra da Nio ainda não chegou no seu endereço.', { cobertura_decisao: 'elegivel_200m', forma_pagamento: null, plano_escolhido: null, etapa: 'planos' }, 'ok');
ok(r.corrigir === true, '4 · elegível 200 m: negar cobertura continua barrado (pede reescrita)');
// 5) pedido em aberto + decisão na nota do handoff
r = rodar('Pronto, Eli, tudo certo por aqui!\n[HANDOFF]\nmotivo_handoff: dados_completos\nbriefing_humano: ok\n[/HANDOFF]\n[DADOS_COLETADOS: pedido_aberto=fui eu, desisti dele]',
  { nio_pedido_aberto: 'sim', cobertura_decisao: 'elegivel_200m', instalacao_preferencia: 'Sex, 13/11, manhã', etapa: 'resumo' }, 'Sim, está certo');
const br = r.handoff ? r.handoff.lead.briefing : '';
ok(/ELEGÍVEL PELOS 200 m/.test(br), '5 · nota com a decisão (elegível 200 m)');
ok(/PEDIDO NIO EM ANDAMENTO[^\n]*fui eu, desisti/.test(br), '5 · nota com o pedido em andamento e a resposta do cliente');
console.log(falhas ? `VERMELHO — ${falhas} falha(s)` : 'VERDE');
process.exitCode = falhas ? 1 : 0;
// P27/P28 determinísticos (12/11)
{
  const r1 = rodar('A Nio atende Juiz de Fora 🎯 Olha as opções:\n[CARROSSEL_PLANOS]', { cobertura_decisao: 'sem_cobertura', forma_pagamento: null, plano_escolhido: null, etapa: 'planos' }, 'Uso a Vivo');
  const ok1 = r1.handoff && r1.handoff.motivo === 'sem_cobertura' && /ainda não chega/.test(r1.texto) && !(r1.interativo && r1.interativo.tipo === 'carrossel');
  console.log((ok1 ? 'ok   ' : 'FALHOU ') + 'P27 · sem_cobertura → aviso fixo + handoff, sem carrossel');
  const r2 = rodar('Entendi! Seguimos então. Qual seu melhor e-mail?', { nio_pedido_aberto: 'sim', forma_pagamento: null }, 'Fui eu, mas desisti daquele',
    [{ papel: 'mari', texto: 'Uma coisa, Ana: já existe um pedido de internet da Nio em andamento no seu CPF. Foi você que fez?' }]);
  const ok2 = r2.upd && r2.upd.dados && r2.upd.dados.pedido_aberto_resposta === 'Fui eu, mas desisti daquele';
  console.log((ok2 ? 'ok   ' : 'FALHOU ') + 'P28 · resposta do cliente sobre o pedido anotada');
  if (!ok1 || !ok2) process.exitCode = 1;
}
{
  const r3 = rodar('Só confirmando os 11 dígitos: 52998224725, certo?\n\nE qual seu melhor e-mail?', { nio_pedido_aberto: 'sim', forma_pagamento: null }, 'Ana, CPF 52998224725', []);
  const ok3 = /pedido de internet da Nio em andamento no seu CPF/.test(r3.texto) && (r3.texto.match(/\?/g) || []).length === 2;
  console.log((ok3 ? 'ok   ' : 'FALHOU ') + 'P28 · pergunta fixa do pedido em andamento, sem outras perguntas | ' + r3.texto.replace(/\n/g, ' ').slice(0, 120));
  if (!ok3) process.exitCode = 1;
}
// cenário k (12/11): lista escrita em cidade com carrossel → vira o carrossel
{
  const fs2 = require('fs'); const code2 = fs2.readFileSync(process.argv[2], 'utf8');
  const card = (c, n, p, pc) => ({ plano_codigo: c, nome: n, nome_curto: n, preco: p, preco_cartao: pc, imagem_url: 'x', titulo_quero: 'Quero', titulo_detalhes: 'Detalhes',
    texto_card: `${n} R$ ${p.toFixed(2).replace('.', ',')} R$ ${pc.toFixed(2).replace('.', ',')}` });
  const nodes = { '5b · Motor': { ctx: { conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', carrossel: true, segmento: 'varejo', cluster: 'regular',
      planos: [{ codigo: 'F', nome: 'Nio Fibra', portfolio: 'varejo', variante: '', preco: 110, preco_cartao: 95, velocidade_mb: 600 }, { codigo: 'E', nome: 'Nio Essencial', portfolio: 'varejo', variante: '', preco: 140, preco_cartao: 125, velocidade_mb: 800 }],
      inter: { textos: {}, cartoes: [card('F', 'Nio Fibra', 110, 95), card('E', 'Nio Essencial', 140, 125)] },
      conversa: { id: 'c1', etapa: 'planos', cidade: 'Juiz de Fora', cep: '36035130', numero: '123', complemento: 'Apto 403', elegibilidade: 'ok', dados: { referencia: 'x' } } } },
    '4 · Preparar': { consolidado: { mensagem: 'Nenhuma', historico: [] } } };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const bruto = 'A Nio atende Juiz de Fora 🎯 A disponibilidade exata na sua rua o nosso time confirma no sistema da Nio antes de abrir o pedido.\n\n1) Nio Fibra, 600 Mega — R$110 por mês (R$95 no cartão)\n\n2) Nio Essencial, 800 Mega — R$140 por mês (R$125 no cartão)\n\nQual te agrada mais?';
  const $input = { first: () => ({ json: { content: [{ type: 'text', text: bruto }], usage: {}, stop_reason: 'end_turn' } }) };
  const r = new Function('$', '$input', '$json', '$runIndex', code2)($, $input, {}, 0)[0].json;
  const ok = r.interativo && r.interativo.tipo === 'carrossel' && !/1\) Nio Fibra/.test(r.texto);
  console.log((ok ? 'ok   ' : 'FALHOU ') + 'k · lista escrita vira carrossel | ' + (r.interativo && r.interativo.tipo) + ' | ' + r.texto.replace(/\n/g, ' ').slice(0, 90));
  if (!ok) process.exitCode = 1;
}
// 0138 — crédito pela Mari (12/11)
{
  const base = { forma_pagamento: null, etapa: 'coleta', dados: { nome: 'Eli Teste', cpf: '52998224725', telefone: '31999999999', email: 'a@b.com', referencia: 'x' } };
  const c1 = rodar('Show!\n[BOTOES:pagamento]', base, 'Sim, está certinho');
  const ok1 = c1.interativo && c1.interativo.chave === 'credito' && c1.interativo.botoes.length === 2;
  console.log((ok1 ? 'ok   ' : 'FALHOU ') + 'C1 · e-mail confirmado → pede a autorização do crédito (no lugar do pagamento) | ' + (c1.interativo && c1.interativo.chave));
  const pergunta = [{ papel: 'mari', texto: 'Antes da forma de pagamento: você autoriza a gente a consultar o seu CPF na análise de crédito da Nio?' }];
  const c2 = rodar('Obrigada!\n[BOTOES:pagamento]', base, 'Sim, autorizo', pergunta);
  const ok2 = c2.upd && c2.upd.dados && c2.upd.dados.credito_autorizado_em && c2.upd.dados.credito_autorizacao_frase === 'Sim, autorizo' && c2.interativo && c2.interativo.chave === 'pagamento';
  console.log((ok2 ? 'ok   ' : 'FALHOU ') + 'C2 · "Sim, autorizo" grava quando + frase e segue para o pagamento | ' + (c2.interativo && c2.interativo.chave));
  const c2b = rodar('Tudo bem!\n[BOTOES:pagamento]', base, 'Não autorizo', pergunta);
  const ok2b = c2b.upd && c2b.upd.dados && c2b.upd.dados.credito_recusado_em && !c2b.upd.dados.credito_autorizado_em && c2b.interativo && c2b.interativo.chave === 'pagamento';
  console.log((ok2b ? 'ok   ' : 'FALHOU ') + 'C2b · "Não autorizo" grava a recusa e segue para o pagamento');
  const c3 = rodar('Perfeito!', Object.assign({}, base, { forma_pagamento: 'boleto', credito_resultado: 'aprovado_cartao', credito_autorizado_em: '2026-11-12T12:00:00Z' }), 'Sex, 13/11');
  const ok3 = /liberou o seu pedido só no cartão/.test(c3.texto) && c3.upd.dados && c3.upd.dados.credito_cartao_avisado === true;
  console.log((ok3 ? 'ok   ' : 'FALHOU ') + 'C3 · aprovado só no cartão + boleto → avisa (cartão ou outro titular)');
  const c4 = rodar('Show, seguimos.', Object.assign({}, base, { forma_pagamento: 'boleto', credito_resultado: 'negado', credito_autorizado_em: '2026-11-12T12:00:00Z' }), 'Manhã');
  const ok4 = c4.handoff && c4.handoff.motivo === 'pedido_humano' && /não aprovou o pedido neste CPF/.test(c4.texto);
  console.log((ok4 ? 'ok   ' : 'FALHOU ') + 'C4 · negado → avisa e chama o time');
  if (!(ok1 && ok2 && ok2b && ok3 && ok4)) process.exitCode = 1;
}
