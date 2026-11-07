// NIOGEN | n8n/cadencia/c09d_futuro_etiquetas.js — nó "9d · Montar etiquetas" do mari_cadencia (07/11/2026, prompt 28)
// Recebe a conversa lida no Chatwoot (nó 9c) e monta a lista de etiquetas = as atuais + interesse-futuro.
// O POST /labels do Chatwoot SUBSTITUI a lista inteira — por isso a união. Sem resposta do Chatwoot → não mexe.
const ETIQUETA = 'interesse-futuro';
const out = [];
$input.all().forEach((it, i) => {
  const base = $('9b · Itens futuro').itemMatching(i).json;
  const cw = it.json || {};
  const leu = cw && (cw.id !== undefined || cw.status !== undefined) && !cw.conversaId;
  if (!leu) { out.push({ json: { ...base, ok: false, erro: 'Chatwoot sem resposta ao ler a conversa' } }); return; }
  const atuais = Array.isArray(cw.labels) ? cw.labels.map(String) : [];
  const labels = atuais.includes(ETIQUETA) ? atuais : [...atuais, ETIQUETA];
  out.push({ json: { ...base, ok: true, labels } });
});
return out;
