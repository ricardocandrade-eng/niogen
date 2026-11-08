// NIOGEN | n8n/mari/n02w_seguir.js — nó "2w · Seguir entrada" do mari_principal (08/11/2026, 0062)
// "#zerar" de um número FORA de config_mari_textos.telefones_teste: não é comando — a mensagem volta para o fluxo normal
// (2m · Modo chatwoot?) com os dados do 2 · Entrada, como se fosse uma fala comum do cliente.
const e = $('2 · Entrada').first().json;
const { registrar, ...resto } = e;
return [{ json: resto }];
