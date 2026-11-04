// NIOGEN | n8n/mari/n02c_midia.js — nó "2c · Mídia" do mari_principal (04/11/2026)
// Padrão Renata (no2c): áudio, vídeo, figurinha ou documento sem texto → resposta fixa, sem a IA.
const p = $('4 · Preparar').first().json;
const texto = 'Opa, não consigo ouvir ou abrir esse tipo de mensagem por aqui 😊 Pode me escrever o que você precisa?';
return [{ json: {
  conversaId: p.conversa_id,
  texto,
  tags: { midia: true },
  upd: {},
  handoff: null,
  erro: null,
  modelo: 'fixo:midia',
  tokensIn: null, tokensOut: null, latenciaMs: 0,
  turnoIds: p.consolidado.turno_ids,
} }];
