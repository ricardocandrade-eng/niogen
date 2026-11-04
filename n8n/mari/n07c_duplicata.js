// NIOGEN | n8n/mari/n07c_duplicata.js — nó "7c · Anti-duplicata" do mari_principal (04/11/2026)
// Padrão Renata (no7b): antes de responder, confere se o lead mandou mensagem nova enquanto o Claude
// pensava (turnos pendentes no banco — lidos pelo nó 7b). Se sim, esta resposta é descartada, as mensagens
// voltam para a fila (mari_abortar) e a execução mais nova responde tudo junto.
const ex = (n) => { try { return $(n).isExecuted; } catch (e) { return false; } };
const r = ex('7r · Extrair (correção)') ? $('7r · Extrair (correção)').first().json : $('7 · Extrair').first().json;
const pendentes = $input.all().filter((i) => i.json && i.json.id !== undefined && i.json.id !== null).length;
return [{ json: { ...r, abortar: pendentes > 0, pendentesNovas: pendentes } }];
