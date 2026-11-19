// NIOGEN | n8n/rascunhos/passo4_191126/c09h_futuro_conferir_porta.js — RASCUNHO do nó "9h · Conferir" do mari_cadencia (19/11/2026)
// Fase 2, passo 4: a etiqueta interesse-futuro e a nota não são mais postas direto no Chatwoot (nós 9c ler, 9d montar a lista
// inteira, 9f etiquetas, 9g nota): o nó 9f pede ao banco (RPC mari_chatwoot_pedir, pedido 'interesse_futuro'), que põe as duas
// ordens na fila pela porta (etiqueta como add, nunca a lista inteira). Marca a conversa só quando o banco aceitou.
const out = [];
$input.all().forEach((it, i) => {
  const base = $('9b · Itens futuro').itemMatching(i).json;
  const r = it.json || {};
  const ok = r.ok === true;
  out.push({ json: { ...base, marcar: ok, erro: ok ? null : 'porta: ' + (r.erro || 'sem resposta do banco') } });
});
return out;
