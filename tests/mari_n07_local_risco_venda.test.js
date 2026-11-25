// NIOGEN | tests/mari_n07_local_risco_venda.test.js | 25/11/2026 — Claude Code. Sem API: node tests/mari_n07_local_risco_venda.test.js n8n/mari/n07_extrair.js
// Caso L-377 (Ricardo, 25/11): com o plano escolhido, pressa na instalação ("Teria para hoje?") ou ameaça de desistir ("Então pode
// deixar obg") → a Mari aciona o atendente na hora (handoff urgencia_alta), sem negar e sem repetir a pergunta do período.
// As falas do modelo abaixo são as que ele escreveu na conversa real.
const fs = require('fs');
const code = fs.readFileSync(process.argv[2] || 'n8n/mari/n07_extrair.js', 'utf8');
function rodar(bruto, conv, msg, extra) {
  const x = extra || {};
  const nodes = {
    '5b · Motor': { ctx: { conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', planos: [], dentroHorario: x.fora ? false : true,
      inter: { textos: x.textos || {}, feriados: [] },
      conversa: Object.assign({ id: 'c1', etapa: 'coleta', cidade: 'Juiz de Fora', cep: '36013150', numero: '10', complemento: 'apto 1',
        elegibilidade: 'ok', plano_escolhido: 'V-REG-FIBRA', forma_pagamento: 'cartao', status: 'ativo', funil_destino: 'em_andamento',
        dados: { nome: 'eli teste', cpf: '52998224725', telefone: '31999999999', email: 'a@b.com', referencia: 'x', instalacao_data: 'Qui, 26/11' } }, conv) } },
    '4 · Preparar': { consolidado: { mensagem: msg, historico: [] } },
    '4c · Supabase interativo': { textos: x.textos || {} }, '2 · Entrada': { modo: 'chatwoot' },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const $input = { first: () => ({ json: { content: [{ type: 'text', text: bruto }], usage: {}, stop_reason: 'end_turn' } }) };
  return new Function('$', '$input', '$json', '$runIndex', code)($, $input, {}, 0)[0].json;
}
let falhas = 0; const ok = (c, n) => { console.log((c ? 'ok   ' : 'FALHOU ') + n); if (!c) falhas++; };
const urg = (r) => !!(r.handoff && r.handoff.motivo === 'urgencia_alta');
const NEGOU = 'Entendo a pressa, Eli, mas pra hoje não vai rolar — a instalação depende da agenda da Nio, e o processo todo (biometria, análise, agenda) leva um tempinho. Pra garantir o mais rápido possível, me confirma: prefere manhã ou tarde no dia 26/11?';

// 1) pressa: "Teria para hoje" + "?" (juntadas) — o modelo negou
let r = rodar(NEGOU, {}, 'Teria para hoje\n?');
ok(urg(r), '1 · "Teria para hoje?" → handoff urgencia_alta');
ok(/acionar agora um atendente/.test(r.texto) && /tentar encaixar a sua instalação pra hoje/.test(r.texto), '1 · fala: atendente vai tentar encaixar pra hoje | ' + r.texto.replace(/\n/g, ' '));
ok(/^(💚 )?Entendi, Eli!/.test(r.texto), '1 · chama pelo primeiro nome (o 💚 da despedida é do sistema)');
ok(!/não vai rolar/.test(r.texto) && !r.interativo, '1 · sem a negação do modelo e sem botões');
ok(r.upd && r.upd.dados && r.upd.dados.risco_venda === 'pressa', '1 · dados.risco_venda = pressa');
ok(/VENDA EM RISCO/.test(r.handoff.lead.briefing) && /Fazer agora: Assumir AGORA/.test(r.handoff.lead.briefing), '1 · nota do time: venda em risco + assumir agora');
// 2) ameaça de desistir no período — o modelo só escreveu a marca dos botões
r = rodar('[BOTOES:turno]', {}, 'Então pode deixar obg');
ok(urg(r) && !r.interativo, '2 · "Então pode deixar obg" → handoff urgencia_alta, sem botões de período');
ok(/acionar agora um atendente/.test(r.texto) && /melhor dia e horário/.test(r.texto), '2 · fala: atendente vê o melhor dia e horário | ' + r.texto.replace(/\n/g, ' '));
ok(r.upd.dados.risco_venda === 'desiste', '2 · dados.risco_venda = desiste');
// 3) controles: resposta do período, data, "tanto faz"
for (const m of ['Pode deixar de manhã', 'Manhã', 'Tanto faz', 'Sex, 27/11', 'pode ser de tarde', 'Amanhã não estarei em casa']) {
  r = rodar('[BOTOES:turno]', {}, m);
  ok(!urg(r), `3 · controle «${m}» não vira urgência`);
}
// 4) antes do plano: fica com o modelo (guard-rail 7), o motor não força
r = rodar('A Nio atende Juiz de Fora 🎯', { plano_escolhido: null, forma_pagamento: null, etapa: 'planos' }, 'tem pra hoje?');
ok(!urg(r), '4 · sem plano escolhido o motor não força');
// 5) "hoje mesmo te mando o CPF", antes da forma de pagamento, não é pressa
r = rodar('Combinado! Fico no aguardo 😊', { forma_pagamento: null }, 'Hoje mesmo te mando o CPF');
ok(!urg(r), '5 · "Hoje mesmo te mando o CPF" não é pressa');
// 6) urgência dita com todas as letras vale depois do plano, mesmo antes do pagamento
r = rodar('Entendi! Qual o seu CPF?', { forma_pagamento: null }, 'é urgente, preciso o quanto antes');
ok(urg(r), '6 · "urgente / o quanto antes" depois do plano → urgência');
// 7) já com o time (pós-handoff): o motor não mexe
r = rodar('Oi!', { status: 'handoff_realizado' }, 'Teria para hoje?');
ok(!r.handoff, '7 · conversa já com o time: sem novo handoff');
// 8) fora do horário: não promete "hoje" nem "já te chama"
r = rodar(NEGOU, {}, 'Teria para hoje?', { fora: true });
ok(urg(r) && /pro quanto antes/.test(r.texto) && /próximo horário de atendimento/.test(r.texto) && !/pra hoje/.test(r.texto), '8 · fora do horário: "quanto antes" + próximo horário | ' + r.texto.replace(/\n/g, ' '));
// 9) texto trocado na configuração
r = rodar(NEGOU, {}, 'Teria para hoje?', { textos: { risco_pressa_fala: 'Opa{nome}! Um atendente vai tentar encaixar. {prazo}.' } });
ok(r.texto.replace(/^💚 /, '') === 'Opa, Eli! Um atendente vai tentar encaixar. Ele já te chama aqui mesmo.', '9 · texto da configuração | ' + r.texto);
// 10) "não quero" na hora da instalação também vai ao time (é venda com plano e pagamento escolhidos)
r = rodar('Sem problema! Se mudar de ideia, é só me chamar aqui.\n[HANDOFF]\nmotivo_handoff: recusa_compra\n[/HANDOFF]', {}, 'esquece, não quero mais');
ok(urg(r), '10 · "esquece, não quero mais" na hora de marcar → time (não a despedida de recusa)');
console.log(falhas ? `VERMELHO — ${falhas} falha(s)` : 'VERDE');
process.exitCode = falhas ? 1 : 0;
