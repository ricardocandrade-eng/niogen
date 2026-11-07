// NIOGEN | n8n/cadencia/c09h_futuro_conferir.js — nó "9h · Conferir" do mari_cadencia (07/11/2026, prompt 28)
// Recebe a resposta da nota privada (nó 9g). Só marca a conversa (mari_futuro_marcar) quando a etiqueta (9f) e a
// nota (9g) voltaram ok — senão a próxima rodada tenta de novo. Falha vai para o log da execução, sem marcar.
const out = [];
$input.all().forEach((it, i) => {
  const base = $('9d · Montar etiquetas').itemMatching(i).json;
  const et = $('9f · Chatwoot etiquetas').itemMatching(i).json || {};
  const nota = it.json || {};
  const etOk = Array.isArray(et.payload) && et.payload.includes('interesse-futuro');
  const notaOk = !!nota.id && nota.private === true;
  out.push({ json: { ...base, marcar: etOk && notaOk,
    erro: etOk && notaOk ? null : `etiqueta ${etOk ? 'ok' : 'falhou'} · nota ${notaOk ? 'ok' : 'falhou'}` } });
});
return out;
