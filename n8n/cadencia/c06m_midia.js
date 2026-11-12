// NIOGEN | n8n/cadencia/c06m_midia.js — nó "6m · Mídia?" do mari_cadencia (12/11/2026, 0146)
// docs/Prompt_mari_resposta_audio_121126_1800.md, itens 6 e 6b: a cutucada escolhida vai como IMAGEM do plano (F2, padrão) ou
// como VOZ (F3, padrão), com A/B — metade das conversas recebe a mídia, metade só o texto (bit do id da conversa: voz = bit 0,
// imagem = bit 1; a medição recalcula o grupo pelo mesmo id). Só cutucadas que a Mari escreveu (F1–F5, texto livre na janela de 24 h).
// Config (config_mari_textos): midia_cadencia_ligado ('sim'), midia_cadencia_telefones ('teste' = telefones_teste, '' = todos),
// audio_cadencia_passo, imagem_cadencia_passo, midia_cadencia_ab ('sim'), audio_resposta_voz/modelo/instrucoes.
// Qualquer dúvida → sem mídia (a cutucada segue em texto pelo Chatwoot, como sempre).
const m = $('6h · Guard Chatwoot').first().json;
const ex = (n) => { try { return $(n).isExecuted; } catch (e) { return false; } };
const sem = (motivo) => [{ json: { ...m, midia: null, midiaMotivo: motivo } }];
if (m.acao !== 'texto' || !/^F[1-5]$/.test(String(m.passo || ''))) return sem('não é cutucada escrita');
const cfg = ((ex('6k · Supabase config') ? $('6k · Supabase config').first().json : null) || {}).textos || {};
if (String(cfg.midia_cadencia_ligado || '').toLowerCase() !== 'sim') return sem('desligado');
const tel = String(m.telefone || '').replace(/\D/g, '');
const lista = String(cfg.midia_cadencia_telefones == null ? 'teste' : cfg.midia_cadencia_telefones).trim();
const liberados = (lista === 'teste' ? String(cfg.telefones_teste || '') : lista).split(/[^0-9]+/).filter(Boolean);
if (lista !== '' && !liberados.includes(tel)) return sem('telefone fora da lista');
const tipo = m.passo === String(cfg.audio_cadencia_passo || '') ? 'voz' : m.passo === String(cfg.imagem_cadencia_passo || '') ? 'imagem' : null;
if (!tipo) return sem('passo sem mídia');
// A/B pelo id da conversa (estável): bit 0 → voz, bit 1 → imagem. 0 = grupo da mídia.
const byte = parseInt(String(m.conversaId || '').replace(/-/g, '').slice(-2), 16) || 0;
const ab = String(cfg.midia_cadencia_ab || 'sim').toLowerCase() === 'sim';
const grupoMidia = !ab || (tipo === 'voz' ? (byte & 1) === 0 : ((byte >> 1) & 1) === 0);
if (!grupoMidia) return sem(`A/B: grupo texto (${tipo})`);
const texto = String(m.texto || '').trim();
const base = { tipo, telefone: tel, texto, origem: 'cadencia', passo: m.passo, ab: tipo === 'voz' ? 'voz' : 'imagem',
  conversa_id: m.conversaId, chatwoot_conversa: m.chatwootConversationId || null };
if (tipo === 'voz') {
  // voz: curta e sem nada que precise ser lido (preço, número, link)
  if (texto.length > 250 || /R\$|\d{4,}|https?:\/\//.test(texto)) return sem('texto não cabe em voz');
  return [{ json: { ...m, midia: 'voz', pedidoMidia: { ...base, texto: texto.replace(/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}]/gu, '').replace(/\s+/g, ' ').trim(),
    voz: cfg.audio_resposta_voz || 'marin', modelo: cfg.audio_resposta_modelo || 'gpt-4o-mini-tts', instrucoes: cfg.audio_resposta_instrucoes || '' } } }];
}
// imagem: o cartão do plano que o 4b trouxe para ESTA conversa e ESTE passo
const ctx = ex('4b · Supabase contexto') ? ($('4b · Supabase contexto').first().json || {}) : {};
const md = ctx.midia || {};
if (ctx.conversa_id !== m.conversaId || ctx.passo !== m.passo || !/^https:\/\//.test(String(md.imagem_url || ''))) return sem('sem imagem do plano');
return [{ json: { ...m, midia: 'imagem', pedidoMidia: { ...base, imagem_url: md.imagem_url, plano: md.plano_da_imagem || null } } }];
