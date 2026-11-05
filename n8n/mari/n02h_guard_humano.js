// NIOGEN | n8n/mari/n02h_guard_humano.js — nó "2h · Guard humano" do mari_principal (04/11/2026)
// Padrão Renata (no2 §0a): humano atribuído, time atribuído ou conversa resolvida = Mari calada.
// 05/11 (prompt 16, adendo 2): etiqueta `nao-contatar` também cala a Mari, mesmo sem dono.
// Modo 'teste': não há Chatwoot → sempre "sem humano".
// Modo 'chatwoot': lê a resposta do nó "2g · Chatwoot conversa" (GET da conversa). Fail-open.

const e = $('2 · Entrada').first().json;
if (e.modo !== 'chatwoot') return [{ json: { ...e, humano: false, guard: 'sem humano (modo teste)' } }];

const c = $input.first().json || {};
const assignee = c.meta?.assignee || c.assignee || null;
const teamId = c.meta?.team?.id ?? c.team_id ?? null;
const status = c.status || null;

const labels = Array.isArray(c.labels) ? c.labels : [];

let motivo = null;
if (labels.includes('nao-contatar')) motivo = 'etiqueta nao-contatar';   // adendo 2: não falar, mesmo sem dono
else if (assignee && (assignee.id ?? assignee.account_id)) motivo = 'humano atribuído';
else if (teamId) motivo = 'time atribuído';
else if (status === 'resolved') motivo = 'conversa resolvida';

if (motivo) return [{ json: { ...e, humano: true, encerrar: true, saida: { silencio: true, motivo } } }];
return [{ json: { ...e, humano: false, guard: 'sem humano' } }];
