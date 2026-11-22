// NIOGEN | n8n/mari/n02h_guard_humano.js — nó "2h · Guard humano" do mari_principal (04/11/2026; porta 21/11/2026)
// 21/11 (fase 2, passo 4 — 0346): o guard deixa de ler o Chatwoot ao vivo e lê a resposta do BANCO ao "pode falar?" (nó 2g, RPC
// mari_pode_falar), que decide pela situação do lead e pelo NIOGEN: humano, time, não contatar, janela pós-handoff, Saída.
// Saídas iguais às de antes: humano=true + saida.silencio → 2r registra calado; humano=false → 3a · Supabase entrada.
// Sem resposta do banco, a Mari NÃO fala (Ricardo, 21/11: "Sim, fica calada").
// Modo 'teste': não há Chatwoot → sempre "sem humano".
// 12/11 (0145): com mídia, a entrada que vale é a do 2b8 · Juntar mídia (texto com a transcrição + lista de mídia).
const e = (() => { try { if ($('2b8 · Juntar mídia').isExecuted) return $('2b8 · Juntar mídia').first().json; } catch (x) { /* sem mídia */ } return $('2 · Entrada').first().json; })();
if (e.modo !== 'chatwoot') return [{ json: { ...e, humano: false, guard: 'sem humano (modo teste)' } }];

const r = $input.first().json || {};
if (typeof r.pode !== 'boolean') {
  return [{ json: { ...e, humano: true, encerrar: true, saida: { silencio: true, motivo: 'banco sem resposta (pode falar?) — Mari calada' } } }];
}
if (!r.pode) return [{ json: { ...e, humano: true, encerrar: true, saida: { silencio: true, motivo: r.motivo || 'banco: não falar' }, situacao: r.situacao || null } }];
return [{ json: { ...e, humano: false, guard: r.motivo || 'pode falar', situacao: r.situacao || null } }];
