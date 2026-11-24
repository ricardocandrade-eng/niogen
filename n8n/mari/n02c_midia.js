// NIOGEN | n8n/mari/n02c_midia.js — nó "2c · Mídia" do mari_principal (04/11/2026)
// Padrão Renata (no2c): áudio, vídeo, figurinha ou documento sem texto → resposta fixa, sem a IA.
// 12/11 (0145): áudio transcrito NÃO chega aqui (vira "🎤 (áudio) …" e vai para a IA). Se chegou um áudio é porque a
// transcrição falhou, veio vazia ou está desligada → a frase fixa sai e o motivo vai para mari_erros (p_erro do 10b).
const p = $('4 · Preparar').first().json;
// 20/11 (prompt "conversa sem Chatwoot", item 6): figurinha sozinha não pede resposta — a Mari não diz "não consigo abrir" (soava
// robótico) e não manda nada: o cliente segue a conversa. A figurinha fica na conversa do NIOGEN (bucket).
const soFig = String((p.consolidado || {}).mensagem || '').split('\n').map((l) => l.trim()).filter(Boolean).every((l) => /^\[MIDIA:sticker\]$/i.test(l));
const midia = Array.isArray((p.consolidado || {}).midia) ? p.consolidado.midia : [];
const audiosSemTexto = midia.filter((m) => m && m.tipo === 'audio' && !m.transcricao);
// 23/11 (L-259): áudio que o transcritor devolveu em outro idioma (2b8) não foi entendido — a Mari ouve áudio, então a frase certa
// é pedir de novo ou por escrito, não "não consigo ouvir esse tipo de mensagem".
const naoEntendeu = audiosSemTexto.some((m) => /outro idioma/.test(String(m.erro || '')));
const texto = soFig ? '' : naoEntendeu ? 'Opa, não consegui entender esse áudio 😕 Pode mandar de novo ou escrever pra mim?'
  : 'Opa, não consigo ouvir ou abrir esse tipo de mensagem por aqui 😊 Pode me escrever o que você precisa?';
const erro = audiosSemTexto.length
  ? { no: '2c · Mídia', mensagem: `áudio sem transcrição: ${audiosSemTexto.map((m) => m.erro || 'sem motivo').join(' | ')}`.slice(0, 500),
      payload: { midia: audiosSemTexto.map((m) => ({ caminho: m.caminho || null, erro: m.erro || null, tamanho: m.tamanho || null })) } }
  : null;
return [{ json: {
  conversaId: p.conversa_id,
  texto,
  tags: soFig ? { midia: true, figurinha: true } : { midia: true },
  upd: {},
  handoff: null,
  erro,
  modelo: 'fixo:midia',
  tokensIn: null, tokensOut: null, latenciaMs: 0,
  turnoIds: p.consolidado.turno_ids,
} }];
