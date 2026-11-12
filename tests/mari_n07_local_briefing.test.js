// NIOGEN | tests/mari_n07_local_briefing.test.js | 12/11/2026 — Claude Code (achados 1 e 2 da auditoria). Sem API: node tests/mari_n07_local_briefing.test.js n8n/mari/n07_extrair.js
// Teste local: briefing do handoff dados_completos com viabilidade automática e cliente sem cartão.
const fs = require('fs');
const code = fs.readFileSync(process.argv[2], 'utf8');
function rodar(bruto, conv, hist, msg) {
  const nodes = {
    '5b · Motor': { ctx: { conversaId: 'c1', t0: Date.now(), turnoIds: [1], promptVersao: 'mari_v7', planos: [], dentroHorario: true,
      conversa: Object.assign({ id: 'c1', etapa: 'resumo', cidade: 'Contagem', cep: '32000000', numero: '10', complemento: 'casa',
        elegibilidade: 'ok', plano_escolhido: 'fibra', forma_pagamento: 'boleto', instalacao_preferencia: 'manha',
        dados: { nome: 'Eli Teste', cpf: '52998224725', telefone: '31999999999', email: 'a@b.com', referencia: 'x' } }, conv) } },
    '4 · Preparar': { consolidado: { mensagem: msg, historico: hist } },
    '2 · Entrada': { modo: 'chatwoot' },
  };
  const $ = (n) => ({ first: () => ({ json: nodes[n] || {} }), isExecuted: !!nodes[n], all: () => [{ json: nodes[n] || {} }] });
  const $input = { first: () => ({ json: { content: [{ type: 'text', text: bruto }], usage: {}, stop_reason: 'end_turn' } }) };
  return new Function('$', '$input', '$json', '$runIndex', code)($, $input, {}, 0)[0].json;
}
const bruto = 'Pronto, Eli, tudo certo por aqui! 💚\n\nAgora o nosso time confere tudo no sistema da Nio e abre o seu pedido.\n[HANDOFF]\nmotivo_handoff: dados_completos\nbriefing_humano: lead completo\n[/HANDOFF]';
const hist = [{ papel: 'lead', texto: 'Ah então vou pedir outra porque eu não tenho cartão não' }, { papel: 'mari', texto: 'Dá pra pagar no boleto' }];
let r = rodar(bruto, { nio_viab_resultado: 'sem_viabilidade' }, hist, 'Sim, está certo');
console.log('A) motivo:', r.handoff && r.handoff.motivo, '\n' + (r.handoff ? r.handoff.lead.briefing : '(sem handoff) ' + JSON.stringify(r.erro)));
r = rodar(bruto, { nio_viab_resultado: 'viavel', nio_viab_velocidade: '1 Giga' }, [{ papel: 'lead', texto: 'pago no cartão sim' }], 'Sim');
console.log('\nB)\n' + (r.handoff ? r.handoff.lead.briefing : '(sem handoff)'));
