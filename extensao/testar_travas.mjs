// NIOGEN | extensao/testar_travas.mjs | 12/11/2026 — Claude Code (docs/Prompt_extensao_ate_resumo_121126_0100.md)
// Teste das travas da condução até o Resumo. Roda com `node extensao/testar_travas.mjs`, sem dependências. Tem que dar VERDE
// antes de qualquer commit que mexa em travas.js ou na condução do content.js.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import vm from 'node:vm';

const aqui = dirname(fileURLToPath(import.meta.url));
const ctx = vm.createContext({});
vm.runInContext(readFileSync(join(aqui, 'travas.js'), 'utf8'), ctx);
const T = ctx.NIOGEN_TRAVAS;

let ok = 0, falhou = 0;
function caso(nome, cond) {
  if (cond) { ok += 1; } else { falhou += 1; console.log(`  FALHOU: ${nome}`); }
}
const pode = (alvo) => T.conferirClique(alvo).ok;

// ── 1. lista branca por etapa ──
caso('E1 Avançar', pode({ tipo: 'botao', texto: 'Avançar', etapa: 1 }));
caso('E1 Avançar com seta', pode({ tipo: 'botao', texto: 'Avançar →', etapa: 1 }));
caso('E1 Buscar não', !pode({ tipo: 'botao', texto: 'Buscar', etapa: 1 }));
caso('E1 opção da lista (UF/PDV/matrícula)', pode({ tipo: 'opcao', texto: 'TT837725 - JOYSSE', etapa: 1 }));
caso('E2 Buscar', pode({ tipo: 'botao', texto: 'Buscar', etapa: 2 }));
caso('E2 Avançar', pode({ tipo: 'botao', texto: 'Avançar', etapa: 2 }));
caso('E2 opção de endereço', pode({ tipo: 'opcao', texto: 'Rua São Sebastião, 420 - Centro', etapa: 2 }));
caso('E2 caixa Sem número', pode({ tipo: 'caixa', texto: 'Sem número', etapa: 2 }));
caso('E3 Buscar', pode({ tipo: 'botao', texto: 'Buscar', etapa: 3 }));
caso('E3 opção de lista não', !pode({ tipo: 'opcao', texto: 'qualquer', etapa: 3 }));
caso('E4 Avançar', pode({ tipo: 'botao', texto: 'Avançar', etapa: 4 }));
caso('E4 aceite WhatsApp (caixa)', pode({ tipo: 'caixa', texto: 'Aceito receber comunicações pelo WhatsApp', etapa: 4 }));
caso('E4 Buscar não', !pode({ tipo: 'botao', texto: 'Buscar', etapa: 4 }));
caso('E5 Avançar (até o Resumo)', pode({ tipo: 'botao', texto: 'Avançar', etapa: 5 }));
caso('E5 radio da forma', pode({ tipo: 'caixa', texto: 'Boleto', etapa: 5 }));
caso('E5 Selecionar oferta', pode({ tipo: 'botao', texto: 'Selecionar', etapa: 5 }));
caso('E6 Resumo: nenhum clique (botão)', !pode({ tipo: 'botao', texto: 'Avançar', etapa: 6 }));
caso('E6 Resumo: nenhum clique (caixa)', !pode({ tipo: 'caixa', texto: 'Li e aceito', etapa: 6 }));
caso('E7: nenhum clique', !pode({ tipo: 'botao', texto: 'Avançar', etapa: 7 }));
caso('etapa desconhecida: nada', !pode({ tipo: 'botao', texto: 'Avançar', etapa: null }));
caso('botão fora da lista (Voltar)', !pode({ tipo: 'botao', texto: 'Voltar', etapa: 3 }));

// ── 2. lista negra, em qualquer etapa ──
for (const [texto, etapa] of [['Salvar interesse', 2], ['Seguir fora da área', 2], ['Abrir OS', 5], ['Enviar', 4], ['Enviar link', 5],
  ['Finalizar', 5], ['Confirmar', 5], ['Concluir pedido', 5], ['Ir para o checkout', 5], ['Carregar pedido', 1], ['Reenviar', 4],
  ['Consultar outro CPF', 3], ['Confirmar pedido', 6]]) {
  caso(`lista negra: ${texto} (E${etapa})`, !pode({ tipo: 'botao', texto, etapa }));
  caso(`lista negra mesmo como opção: ${texto}`, !pode({ tipo: 'opcao', texto, etapa: 2 }));
}

// ── 3. "Continuar" em popup ──
caso('E2 Continuar no modal "disponível"', pode({ tipo: 'botao', texto: 'Continuar', etapa: 2, popup: { texto: 'Viabilidade disponível para o endereço. Velocidade até 1 Giga' } }));
caso('E2 Continuar em "indisponível"', !pode({ tipo: 'botao', texto: 'Continuar', etapa: 2, popup: { texto: 'Viabilidade indisponível' } }));
caso('E2 Continuar sem falar de viabilidade', !pode({ tipo: 'botao', texto: 'Continuar', etapa: 2, popup: { texto: 'Atenção' } }));
caso('E4 Continuar com biometria no texto', !pode({ tipo: 'botao', texto: 'Continuar', etapa: 4,
  popup: { texto: 'Crédito aprovado · Elegível para todas as formas de pagamento · Clique em Continuar para enviar ao cliente o link para Biometria' } }));
caso('E4 Continuar mesmo sem biometria (popup da E4 é do humano)', !pode({ tipo: 'botao', texto: 'Continuar', etapa: 4, popup: { texto: 'Resultado da análise' } }));
caso('E2 Continuar que fala de link', !pode({ tipo: 'botao', texto: 'Continuar', etapa: 2, popup: { texto: 'Disponível. Vamos enviar o link de pagamento' } }));
caso('E3 Tentar novamente (Receita)', pode({ tipo: 'botao', texto: 'Tentar novamente', etapa: 3, popup: { texto: 'OPS, OCORREU UM ERRO!' } }));
caso('E3 Salvar interesse no popup', !pode({ tipo: 'botao', texto: 'Salvar interesse', etapa: 3, popup: { texto: 'Pedido encontrado' } }));
caso('popupSeguro sem biometria', T.popupSeguro('Viabilidade disponível'));
caso('popupSeguro com biometria', !T.popupSeguro('enviar ao cliente o link para Biometria'));

// ── 4. popups classificados ──
caso('popup recompra', T.classificarPopup('Pedido encontrado', 'Já existe outro pedido em andamento', 3) === 'pedido_em_andamento');
caso('popup celular', T.classificarPopup('', 'excede a quantidade de repetições de mesmo número permitidas', 4) === 'contato_repetido');
caso('popup e-mail', T.classificarPopup('Atenção!', 'E-mail inválido. Por favor preencha um e-mail válido', 4) === 'email_invalido');
caso('popup aprovado todas', T.classificarPopup('Resultado da análise de crédito', 'Crédito aprovado Elegível para todas as formas de pagamento', 4) === 'aprovado_todas');
caso('popup só cartão', T.classificarPopup('', 'Crédito aprovado. Elegível somente para cartão', 4) === 'aprovado_cartao');
caso('popup negado', T.classificarPopup('', 'Crédito não aprovado', 4) === 'negado');
caso('popup Receita', T.classificarPopup('', 'OPS, OCORREU UM ERRO!', 3) === 'receita_retry');
caso('motivo recompra', T.MOTIVO_POPUP.pedido_em_andamento === 'recompra');

// ── 5. rede: regras casando com URLs de amostra ──
const B = (url, metodo = 'POST', pos = true) => T.redeBloqueada(url, metodo, pos);
const API = 'https://pap-api.niointernet.com.br/';
caso('rede: checkout/enviar barrado', !!B(`${API}api/portal/aberturaos/checkout/enviar`));
caso('rede: aberturaos POST barrado', !!B(`${API}api/portal/aberturaos/abrir`));
caso('rede: biometria/envio barrado', !!B(`${API}api/portal/biometria/envio`));
caso('rede: pagamento/reenviolink barrado', !!B(`${API}api/portal/pagamento/reenviolink`));
caso('rede: dadosBancarios barrado', !!B(`${API}api/portal/dadosBancarios/salvar`));
caso('rede: SAVE_LEAD barrado', !!B(`${API}api/portal/lead/SAVE_LEAD`));
caso('rede: prevenda barrado', !!B(`${API}api/portal/prevenda/salvar`));
caso('rede: carrinho …/enviar barrado', !!B(`${API}api/portal/carrinho/123/enviar`));
caso('rede: portabilidade (não consulta) barrado', !!B(`${API}api/portal/novafibra/portabilidadenovafibra/salvar`));
caso('rede: portabilidade consulta LIBERADA', !B(`${API}api/portal/novafibra/portabilidadenovafibra/consultaDdd/MG`, 'GET'));
caso('rede: portabilidade consultaOperadoras LIBERADA', !B(`${API}api/portal/novafibra/portabilidadenovafibra/consultaOperadoras`, 'GET'));
caso('rede: leitura do carrinho (GET) liberada', !B(`${API}api/portal/aberturaos/carrinho/98765`, 'GET'));
caso('rede: carrinho POST em aberturaos barrado', !!B(`${API}api/portal/aberturaos/carrinho/98765`, 'POST'));
caso('rede: interesse barrado depois da E2', !!B(`${API}api/portal/interesse/salvar`, 'POST', true));
caso('rede: interesse livre até a E2', !B(`${API}api/portal/interesse/consulta`, 'GET', false));
caso('rede: viabilidade livre', !B(`${API}api/portal/novafibra/viabilidade/consulta`, 'POST'));
caso('rede: crédito livre', !B(`${API}api/portal/novafibra/analiseCredito`, 'POST'));
caso('rede: regras com tabIds', T.regrasRede(42, true).every((r) => r.condition.tabIds.length === 1 && r.condition.tabIds[0] === 42));
caso('rede: interesse só depois da E2', !T.regrasRede(1, false).some((r) => r.condition.regexFilter === 'interesse')
  && T.regrasRede(1, true).some((r) => r.condition.regexFilter === 'interesse'));
caso('rede: ids na faixa da condução', T.regrasRede(1, true).every((r) => T.idsRegras().includes(r.id)));
caso('rede: regexFilter sem lookahead (RE2)', T.regrasRede(1, true).every((r) => !/\(\?[=!<]/.test(r.condition.regexFilter)));
// 0.6.1: o Chrome recusou a 7401 (> 2 KB compilada) por causa de {1,40}. Sem repetição contada e regex curta.
caso('rede: regexFilter sem repetição contada {n,m} (limite de 2 KB do Chrome)', T.regrasRede(1, true).every((r) => !/\{\d/.test(r.condition.regexFilter) && r.condition.regexFilter.length <= 80));
caso('rede: consulta da portabilidade liberada (com id e query)', B('https://x/api/portabilidadenovafibra/consultaPlanos/ABC-12?uf=MG', 'GET') === null);
caso('rede: portabilidade fora da consulta barrada', B('https://x/api/portabilidadenovafibra/consultaPlanos/1/salvar') !== null);
caso('rede: leitura do carrinho liberada (GET com id)', B('https://x/api/aberturaos/carrinho/9f3a?x=1', 'GET') === null);
caso('rede: carrinho/<id>/enviar barrado mesmo em GET', B('https://x/api/aberturaos/carrinho/9f3a/enviar', 'GET') !== null);
caso('rede: carrinho em POST barrado', B('https://x/api/aberturaos/carrinho/9f3a', 'POST') !== null);

// ── 6. forma de pagamento e oferta ──
caso('DACC para', !T.formaDaVenda('dacc').ok && T.formaDaVenda('dacc').motivo === 'dacc');
caso('boleto → BOLETO', T.formaDaVenda('boleto').valor === 'BOLETO');
caso('cartão → CREDITO', T.formaDaVenda('cartao').valor === 'CREDITO');
const cartoes = [
  T.lerOferta('NIO FIBRA ESSENCIAL\n500 Mega\nR$ 99,99/mês\nCom fidelidade'),
  T.lerOferta('NIO FIBRA ULTRA\n1 Giga\nR$ 149,99/mês\nCom fidelidade'),
  T.lerOferta('NIO FIBRA ULTRA\n1 Giga\nR$ 159,99/mês\nSem fidelidade'),
];
caso('oferta lida (giga → 1000)', cartoes[1].megas === 1000 && cartoes[1].preco === 149.99);
caso('oferta única casa', T.casarOferta(cartoes, { nomes: ['Nio Fibra Ultra'], megas: 1000, precos: [149.99] }).i === 1);
caso('oferta ambígua para', !T.casarOferta(cartoes, { nomes: ['Nio Fibra Ultra'], megas: 1000, precos: [149.99, 159.99] }).ok);
caso('oferta ausente para', !T.casarOferta(cartoes, { nomes: ['Nio Fibra Super'], megas: 700, precos: [119.99] }).ok);
caso('oferta com preço errado para', !T.casarOferta(cartoes, { nomes: ['Nio Fibra Essencial'], megas: 500, precos: [89.99] }).ok);

// ── 7. endereço e complemento (52 ≠ 520; nunca troca de unidade) ──
caso('endereço pelo número exato', T.alvoEndereco(['Rua A, 520 - Centro', 'Rua A, 52 - Centro'], '52').alvo === 'Rua A, 52 - Centro');
caso('endereço único', T.alvoEndereco(['Rua A - Centro'], '').alvo === 'Rua A - Centro');
caso('endereço sem número claro para', !T.alvoEndereco(['Rua A, 10', 'Rua B, 20'], '30').ok);
caso('complemento 403 → Apartamento 403', T.alvoComplemento(['Apartamento 1403', 'Apartamento 403'], '403').alvo === 'Apartamento 403');
caso('complemento fora da lista para', !T.alvoComplemento(['Apartamento 101'], '205').ok);
caso('complemento com blocos sem bloco para', !T.alvoComplemento(['Bloco 1 - Apartamento 205', 'Bloco 2 - Apartamento 205'], '205').ok);
caso('complemento com bloco dito casa', T.alvoComplemento(['Bloco 1 - Apartamento 205', 'Bloco 2 - Apartamento 205'], 'Bloco 2 apto 205').alvo === 'Bloco 2 - Apartamento 205');

// ── 8. texto redigido para o NIOGEN ──
caso('redigir tira CPF, celular e e-mail', !/\d{6}|@/.test(T.redigir('CPF 123.456.789-09, cel (32) 99999-8888, a@b.com.br')));

console.log(`\n${falhou ? 'VERMELHO' : 'VERDE'} — ${ok} ok, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);
