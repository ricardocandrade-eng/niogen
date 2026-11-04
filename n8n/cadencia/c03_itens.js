// NIOGEN | n8n/cadencia/c03_itens.js — nó "3b · Itens" do mari_cadencia (04/11/2026)
// A RPC mari_cadencia_candidatos devolve um array de objetos (cada um já com a decisão do banco:
// passo, ação, texto, template, params). Aqui só vira um item por conversa — sem decisão nenhuma.
const out = [];
for (const it of $input.all()) {
  const j = it.json;
  const lista = Array.isArray(j) ? j : (j && j.conversa_id ? [j] : []);
  for (const c of lista) {
    const v = (c && c.mari_cadencia_candidatos) || c;   // PostgREST pode embrulhar setof jsonb no nome da função
    if (v && v.conversa_id && v.pode_enviar === true) out.push({ json: v });
  }
}
return out.slice(0, 30);   // teto por rodada (o banco já limita; aqui é cinto + suspensório)
