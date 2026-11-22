// NIOGEN | n8n/cadencia/c09h_futuro_conferir.js — nó "9h · Conferir" do mari_cadencia (07/11/2026; porta 21/11/2026)
// 21/11 (fase 2, passo 4 — 0346): a etiqueta interesse-futuro e a nota não vão mais direto ao Chatwoot: o nó 9f pede ao banco
// (RPC mari_chatwoot_pedir, pedido 'interesse_futuro'), que põe as duas ordens na fila pela porta (etiqueta por add, nunca a
// lista inteira). Marca a conversa (mari_futuro_marcar) só quando o banco aceitou; senão a próxima rodada tenta de novo.
const out = [];
$input.all().forEach((it, i) => {
  const base = $('9b · Itens futuro').itemMatching(i).json;
  const r = it.json || {};
  const ok = r.ok === true;
  out.push({ json: { ...base, marcar: ok, erro: ok ? null : 'porta: ' + (r.erro || 'sem resposta do banco') } });
});
return out;
