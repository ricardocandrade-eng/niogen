// NIOGEN | n8n/mari/n02w_seguir.js — nó "2w · Seguir entrada" do mari_principal (08/11/2026, 0062)
// "#zerar" de um número FORA de config_mari_textos.telefones_teste: não é comando — a mensagem volta para o fluxo normal
// (2m · Modo chatwoot?) com os dados do 2 · Entrada, como se fosse uma fala comum do cliente.
// 12/11 (0145): com mídia, a entrada que vale é a do 2b8 · Juntar mídia (texto com a transcrição + lista de mídia).
const e = (() => { try { if ($('2b8 · Juntar mídia').isExecuted) return $('2b8 · Juntar mídia').first().json; } catch (x) { /* sem mídia */ } return $('2 · Entrada').first().json; })();
const { registrar, ...resto } = e;
return [{ json: resto }];
