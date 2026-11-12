// NIOGEN | n8n/mari/n11i_depois_voz.js — nó "11i · Depois da voz" do mari_principal (12/11/2026, 0146)
// A voz saiu → seguem só os balões que ficam por escrito (preço, lista…). Não saiu → a resposta inteira vai em texto, como sempre
// (o mari_midia_envio já gravou o erro em mari_erros). O cliente nunca fica sem resposta por causa da voz.
const base = $('11f · Separar fala').first().json;
const r = $input.first().json || {};
const { falar, fala, baloesTexto, pedidoVoz, ...orig } = base;
if (!r.ok) return [{ json: orig }];
const baloes = Array.isArray(baloesTexto) ? baloesTexto : [];
return [{ json: { ...orig, baloes, resposta: baloes.join('\n'),
  atrasos: baloes.map((b, i) => (i === 0 ? 1 : Math.min(6, Math.max(2, Math.round(b.length / 60))))), vozEnviada: true } }];
