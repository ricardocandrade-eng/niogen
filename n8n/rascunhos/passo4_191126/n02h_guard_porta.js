// NIOGEN | n8n/rascunhos/passo4_191126/n02h_guard_porta.js — RASCUNHO do nó "2h · Guard humano" do mari_principal (19/11/2026)
// Fase 2, passo 4 (um projetor só): o guard deixa de ler o Chatwoot ao vivo (GET do nó 2g) e pergunta ao BANCO "pode falar?"
// (RPC mari_pode_falar, rascunho supabase/rascunhos/0308_mari_pela_porta_RASCUNHO.sql), que responde pela situação do lead.
// Mesmas saídas do guard de hoje (n8n/mari/n02h_guard_humano.js): humano=true + saida.silencio → 2r registra calado;
// humano=false → 3a · Supabase entrada (o mari_entrada decide a resposta, a janela pós-handoff e a Saída).
// DIFERENÇA de propósito: sem resposta do banco, a Mari NÃO fala (hoje, sem resposta do Chatwoot, vale a foto do webhook).
// Modo 'teste': sem Chatwoot → sempre "sem humano", como hoje.
const e = (() => { try { if ($('2b8 · Juntar mídia').isExecuted) return $('2b8 · Juntar mídia').first().json; } catch (x) { /* sem mídia */ } return $('2 · Entrada').first().json; })();
if (e.modo !== 'chatwoot') return [{ json: { ...e, humano: false, guard: 'sem humano (modo teste)' } }];

const r = $input.first().json || {};
if (typeof r.pode !== 'boolean') {
  return [{ json: { ...e, humano: true, encerrar: true, saida: { silencio: true, motivo: 'banco sem resposta (pode falar?) — Mari calada' } } }];
}
if (!r.pode) return [{ json: { ...e, humano: true, encerrar: true, saida: { silencio: true, motivo: r.motivo || 'banco: não falar' }, situacao: r.situacao || null } }];
return [{ json: { ...e, humano: false, guard: r.motivo || 'pode falar', situacao: r.situacao || null } }];
