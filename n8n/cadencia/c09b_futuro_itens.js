// NIOGEN | n8n/cadencia/c09b_futuro_itens.js — nó "9b · Itens futuro" do mari_cadencia (07/11/2026, prompt 28)
// A RPC mari_futuro_pendentes (0052) devolve as conversas cuja venda está em Saída "Interesse futuro (com data)" e
// ainda sem a etiqueta/nota para essa data. Aqui só vira um item por conversa — sem decisão nenhuma.
// RPC com erro (ex.: 0052 ainda não aplicada) → nada a fazer nesta rodada (o ramo principal não é afetado).
const CHATWOOT_NIO_ACCOUNT = '195428';   // conta própria da Nio no Chatwoot (nunca a da Vero) — a mesma do c05
const out = [];
for (const it of $input.all()) {
  const j = it.json;
  if (!j || j.error || j.code || (j.message && !j.conversa_id)) continue;   // erro da RPC: pula
  const lista = Array.isArray(j) ? j : (j.conversa_id || j.mari_futuro_pendentes ? [j] : []);
  for (const x of lista) {
    const v = (x && x.mari_futuro_pendentes) || x;
    if (v && v.conversa_id && v.chatwoot_conversation_id && v.volta_em) {
      out.push({ json: { conta: CHATWOOT_NIO_ACCOUNT, conversaId: v.conversa_id, cw: String(v.chatwoot_conversation_id),
        voltaEm: v.volta_em, nota: v.nota } });
    }
  }
}
return out.slice(0, 20);
