// NIOGEN | n8n/mari/n11f_fala.js — nó "11f · Separar fala" do mari_principal (12/11/2026, 0146)
// docs/Prompt_mari_resposta_audio_121126_1800.md. Decide se a resposta da Mari vira VOZ (mensagem de voz, voz Marin) e separa o que
// é "conversa" (vai na voz) do que fica por escrito (preço, lista, números, link, marcas, condições, resumo).
// Só quando: config audio_resposta_ligado = 'sim'; telefone liberado (audio_resposta_telefones: 'teste' = telefones_teste, '' = todos);
// a ÚLTIMA mensagem do cliente foi áudio transcrito; a resposta foi escrita pelo Claude agora (não fixa, não handoff);
// cabe no limite (audio_resposta_max_chars). Qualquer dúvida → texto, como sempre.
const j = $input.first().json;
const ex = (n) => { try { return $(n).isExecuted; } catch (e) { return false; } };
const naoFala = () => [{ json: { ...j, falar: false } }];
const s = j.saida || {};
if (j.modo !== 'chatwoot' || !s.resposta || s.handoff || s.abortado || s.silencio || !ex('4c · Supabase interativo')) return naoFala();
const cfg = ($('4c · Supabase interativo').first().json || {}).textos || {};
if (String(cfg.audio_resposta_ligado || '').toLowerCase() !== 'sim') return naoFala();
const tel = String(j.telefone || '').replace(/\D/g, '');
const lista = String(cfg.audio_resposta_telefones == null ? 'teste' : cfg.audio_resposta_telefones).trim();
const liberados = (lista === 'teste' ? String(cfg.telefones_teste || '') : lista).split(/[^0-9]+/).filter(Boolean);
if (lista !== '' && !liberados.includes(tel)) return naoFala();
// a mensagem de agora do cliente foi áudio transcrito?
const cons = ex('4 · Preparar') ? (($('4 · Preparar').first().json || {}).consolidado || {}) : {};
const midia = Array.isArray(cons.midia) ? cons.midia : [];
if (!midia.some((m) => m && m.tipo === 'audio' && m.transcricao)) return naoFala();
if (/^(fixo|abertura)/i.test(String(s.modelo || ''))) return naoFala();
// separar: balão com preço, número de 4+ dígitos, link, lista ou marca técnica fica em texto
const fica = (b) => /R\$|\d{4,}|https?:\/\/|\[[A-Z_]{3,}|^\s*(\d+[).]|[-•*])\s/m.test(b) || /\n\s*(\d+[).]|[-•*])\s/.test(b);
const baloes = Array.isArray(j.baloes) ? j.baloes : [];
// só os balões ANTES do primeiro que precisa ser escrito vão na voz (a voz sai primeiro; "qual deles?" depois da lista fica em texto)
const corte = baloes.findIndex((b) => fica(b));
const falados = corte < 0 ? baloes : baloes.slice(0, corte);
const texto = corte < 0 ? [] : baloes.slice(corte);
// tira emoji e espaços duplos (o TTS lê "💚" errado)
const fala = falados.join(' ').replace(/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}]/gu, '').replace(/\s+/g, ' ').trim();
const max = Number(cfg.audio_resposta_max_chars) || 350;
if (!fala || fala.length > max) return naoFala();
return [{ json: { ...j, falar: true, fala, baloesTexto: texto,
  pedidoVoz: { tipo: 'voz', telefone: tel, texto: fala, origem: 'resposta', conversa_id: s.conversa_id || null,
    chatwoot_conversa: j.chatwootConversationId || null, voz: cfg.audio_resposta_voz || 'marin',
    modelo: cfg.audio_resposta_modelo || 'gpt-4o-mini-tts', instrucoes: cfg.audio_resposta_instrucoes || '' } } }];
