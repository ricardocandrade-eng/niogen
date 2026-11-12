// NIOGEN | n8n/mari/n02h_guard_humano.js — nó "2h · Guard humano" do mari_principal (04/11/2026)
// Padrão Renata (no2 §0a): humano atribuído, time atribuído ou conversa resolvida = Mari calada.
// 05/11 (prompt 16, adendo 2): etiqueta `nao-contatar` também cala a Mari, mesmo sem dono.
// Modo 'teste': não há Chatwoot → sempre "sem humano".
// Modo 'chatwoot': lê a resposta do nó "2g · Chatwoot conversa" (GET da conversa). Fail-open.

// 12/11 (0145): com mídia, a entrada que vale é a do 2b8 · Juntar mídia (texto com a transcrição + lista de mídia).
const e = (() => { try { if ($('2b8 · Juntar mídia').isExecuted) return $('2b8 · Juntar mídia').first().json; } catch (x) { /* sem mídia */ } return $('2 · Entrada').first().json; })();
if (e.modo !== 'chatwoot') return [{ json: { ...e, humano: false, guard: 'sem humano (modo teste)' } }];

const c = $input.first().json || {};
const assignee = c.meta?.assignee || c.assignee || null;
const teamId = c.meta?.team?.id ?? c.team_id ?? null;
const status = c.status || null;

const labels = Array.isArray(c.labels) ? c.labels : [];

let motivo = null;
if (labels.includes('nao-contatar')) motivo = 'etiqueta nao-contatar';   // adendo 2: não falar, mesmo sem dono
else if (assignee && (assignee.id ?? assignee.account_id)) motivo = 'humano atribuído';
else if (teamId && !labels.includes('handoff-venda')) motivo = 'time atribuído';
else if (status === 'resolved') motivo = 'conversa resolvida';

// Janela pós-handoff (Ricardo, 07/11 23h30 — migration 0061): venda passada ao backoffice (etiqueta handoff-venda, time
// atribuído pela automação) e AINDA SEM DONO → segue para o 3a; quem decide é o mari_entrada (handoff dados_completos há
// menos de N min — config_mari_textos.pos_handoff_minutos — e nenhuma fala do nosso time desde então). Fora disso ele
// devolve silêncio e a mensagem fica registrada, como no 2r. Alguém do time assumiu (dono) → calada, como sempre.
if (!motivo && teamId) return [{ json: { ...e, humano: false, guard: 'time sem dono + handoff-venda — janela pós-handoff (banco decide)' } }];

if (motivo) return [{ json: { ...e, humano: true, encerrar: true, saida: { silencio: true, motivo } } }];
return [{ json: { ...e, humano: false, guard: 'sem humano' } }];
