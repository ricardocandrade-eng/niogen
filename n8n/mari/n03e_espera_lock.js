// NIOGEN | n8n/mari/n03e_espera_lock.js — nó "3e · Espera lock" do mari_principal (04/11/2026)
// A conversa está sendo respondida por outra execução (lock). Espera 1 s e tenta de novo,
// até ~45 s (TTL do lock), como o processing lock da Renata (no2 §2b).
const MAX = 45;
return [{ json: { esgotado: $runIndex >= MAX, tentativa: $runIndex + 1 } }];
