// NIOGEN | n8n/mari/n09d_handoff_chatwoot.js — nó "9d · Montar handoff Chatwoot" do mari_principal (05/11/2026, prompt 16 Parte G)
// Adendo 2: todo handoff deixa rastro visível no Chatwoot — etiquetas, nota privada com o briefing e (venda/humano) o time backoffice.
// As automações da conta (24387 resolvida → liberar · 24389 handoff-venda → backoffice · 24390 handoff-humano → backoffice +
// prioridade alta) já existem e NÃO são criadas nem alteradas por aqui.
// Só monta os pedidos; os nós 9e/9f/9h chamam a API (onError = segue, o handoff nunca derruba a resposta ao cliente).

const TIME_BACKOFFICE = 15102;
const NIOGEN = 'https://ricardocandrade-eng.github.io/niogen/vendas.html';

const e = $('2 · Entrada').first().json;
const s = $('10 · Salvar turno').first().json;
const h = $('9 · Handoff').first().json || {};
const b = $input.first().json || {};   // linha de mari_conversas (9b)
let conv = {};
try { conv = $('2g · Chatwoot conversa').first().json || {}; } catch (err) { conv = {}; }

const motivo = (b.handoff_motivo || s.r?.handoff?.motivo || '').trim();
const briefing = String(b.handoff_briefing || '').trim();
const vendaId = h.venda_id || b.venda_id || null;

const VENDA = ['dados_completos'];
const HUMANO = ['pedido_humano', 'objecao', 'urgencia_alta'];
const SAIDA = ['recusa_compra', 'fora_de_area', 'sem_cobertura', 'interesse_caindo', 'multiplos_decisores', 'sem_contato'];

let tipo;
if (VENDA.includes(motivo)) tipo = 'venda';
else if (HUMANO.includes(motivo)) tipo = 'humano';
else if (motivo === 'ja_cliente_nio') tipo = /reclam/i.test(briefing) ? 'humano' : 'saida';   // cliente Nio reclamando = humano agora
else if (SAIDA.includes(motivo)) tipo = 'saida';
else tipo = 'humano';                                                                      // motivo desconhecido: na dúvida, gente

const novas = tipo === 'venda' ? ['handoff', 'handoff-venda'] : tipo === 'humano' ? ['handoff', 'handoff-humano'] : ['handoff'];
const atuais = Array.isArray(conv.labels) ? conv.labels : [];
const labels = [...new Set([...atuais, ...novas])];

const NOME = {
  dados_completos: 'dados completos (venda)', pedido_humano: 'pediu humano', objecao: 'objeção', urgencia_alta: 'urgência alta',
  ja_cliente_nio: 'já é cliente Nio', recusa_compra: 'recusou a compra', fora_de_area: 'fora da área', sem_cobertura: 'sem cobertura',
  interesse_caindo: 'interesse caindo', multiplos_decisores: 'mais de um decisor', sem_contato: 'sem contato',
};
const nota = [
  `MARI → BACKOFFICE · ${NOME[motivo] || motivo || 'handoff'}`,
  briefing || '(sem briefing gravado — ver a conversa)',
  vendaId ? `${NIOGEN}#venda=${vendaId}` : null,
].filter(Boolean).join('\n\n');

return [{ json: {
  conta: e.config?.CHATWOOT_NIO_ACCOUNT,
  conversa: e.chatwootConversationId,
  labels, nota, tipo, motivo, vendaId,
  atribuirTime: tipo === 'venda' || tipo === 'humano',
  teamId: TIME_BACKOFFICE,
} }];
