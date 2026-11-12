// NIOGEN | n8n/mari/n02_entrada.js — nó "2 · Entrada" do workflow mari_principal (04/11/2026; resolvida → 2v em 05/11, prompt 18;
//   origem pela mensagem pronta (IG)/(FB)/anúncio em 06/11, 0033)
// Normaliza a entrada (rota de teste ou webhook do Chatwoot), aplica o interruptor de modo
// (staticData._modoMari = 'teste' | 'chatwoot'), comandos admin da rota de teste, detecção de mídia
// e rate limit. Sem texto de negócio e sem segredo.

const sd = $getWorkflowStaticData('global');
if (!sd._modoMari) sd._modoMari = 'teste';
const modo = sd._modoMari;

// Conta/caixa próprias da Nio no Chatwoot ("Nio Atendimento", WhatsApp Cloud do 31 2888-1265).
// Nada da conta da Vero — a validação abaixo descarta qualquer evento de outra conta/caixa.
const CONFIG = {
  CHATWOOT_NIO_ACCOUNT: '195428',
  CHATWOOT_NIO_INBOX: '153431',
  MAX_CHAMADAS_HORA: 300,
};

const ex = (n) => { try { return $(n).isExecuted; } catch (e) { return false; } };
const fim = (saida) => [{ json: { encerrar: true, saida } }];

const MIDIA_SO = new Set(['audio', 'voice', 'video', 'sticker', 'document', 'file', 'attachment']);

// Origem pela mensagem pronta (06/11, migration 0033): link da bio do Instagram termina em "(IG)", botão da página do
// Facebook em "(FB)", anúncio da campanha 1 começa com "Vi o anúncio" (INFRA §7). Sem marca = null → o banco grava 'direto'.
// O banco só usa a origem na conversa nova ou numa conversa ainda 'direto' — nunca troca uma origem já conhecida.
const origemDoTexto = (t) => {
  const s = String(t || '');
  if (/\(IG\)|vim pelo instagram/i.test(s)) return 'instagram';
  if (/\(FB\)|vim pela p[áa]gina do facebook/i.test(s)) return 'facebook';
  if (/vi o an[úu]ncio/i.test(s)) return 'meta_ads';
  return null;
};

// v7 (prompts 26 + 27, 06/11): resposta de botão. O Chatwoot entrega o TÍTULO do botão como texto (o id da Meta não
// chega). Plano B aprovado pelo Ricardo (06/11 18h42): títulos com o nome do plano. "Quero o Super" vira a fala
// "Quero o plano Nio Super"; "Detalhes Super" / "Mais detalhes" o 5b · Motor responde com o texto fixo, sem o Claude.
// Se um dia vier o id (plano:<codigo>:quero|detalhes), ele é usado.
const PLANOS_BOTAO = { fibra: 'Fibra', essencial: 'Essencial', super: 'Super', ultra: 'Ultra' };
function textoDoBotao(texto, botaoId) {
  const id = String(botaoId || '');
  const mid = id.match(/^plano:V-REG-([A-Z]+):(quero|detalhes)$/);
  if (mid) {
    const fam = { FIBRA: 'Fibra', ESS: 'Essencial', SUP: 'Super', ULT: 'Ultra' }[mid[1]];
    if (fam) return mid[2] === 'quero' ? `Quero o plano Nio ${fam}` : `Detalhes ${fam}`;
  }
  const t = String(texto || '').trim();
  const q = t.match(/^quero o (fibra|essencial|super|ultra)!?$/i);
  if (q) return `Quero o plano Nio ${PLANOS_BOTAO[q[1].toLowerCase()]}`;
  return t;
}
// Status do Chatwoot (0048, prompt 27 B2): lido em TODO evento já validado e gravado pelo 2t (mari_chatwoot_sync),
// antes dos guards e sem mudar o fluxo da Mari.
function statusDe(conv, convId) {
  if (!conv || !convId) return null;
  return {
    p_chatwoot_conversation_id: String(convId),
    p_status: conv.status || null,
    p_agente: (conv.meta && conv.meta.assignee && conv.meta.assignee.name) || null,
    p_time: (conv.meta && conv.meta.team && conv.meta.team.name) || null,
    p_etiquetas: Array.isArray(conv.labels) ? conv.labels : [],
  };
}

let entrada;

if (ex('1 · Webhook Mari teste')) {
  const body = $('1 · Webhook Mari teste').first().json.body || {};

  // Comandos admin (só pela rota de teste, que já exige o header secreto).
  if (body.admin) {
    const cmd = String(body.admin).toLowerCase().trim();
    if (cmd === 'modo teste' || cmd === 'modo chatwoot') {
      sd._modoMari = cmd.split(' ')[1];
      return fim({ admin: true, modo: sd._modoMari });
    }
    if (cmd === 'status') return fim({ admin: true, modo: sd._modoMari, chamadas_ultima_hora: (sd._apiCalls || []).length, tel_real: sd._telReal ? `…${sd._telReal.slice(-4)}` : null });
    // v7: teste no celular do Ricardo pela rota de ensaio — só ESTE número recebe carrossel/botões de verdade (Graph API).
    const tr = cmd.match(/^tel real (\d{12,13}|off)$/);
    if (tr) { sd._telReal = tr[1] === 'off' ? null : tr[1]; return fim({ admin: true, tel_real: sd._telReal ? `…${sd._telReal.slice(-4)}` : null }); }
    return fim({ admin: true, erro: 'comando desconhecido (use: modo teste | modo chatwoot | status | tel real <55DDDNUMERO> | tel real off)' });
  }

  // A rota de teste funciona nos dois modos (bateria): canal 'teste', resposta só no corpo HTTP,
  // nunca passa pelo Chatwoot (o 2m e o 11 seguem o gatilho, não o interruptor).

  const tel = String(body.telefone || '').replace(/\D/g, '');
  if (!/^\d{10,15}$/.test(tel)) return fim({ erro: 'telefone inválido (só dígitos, com DDI)' });

  let texto = textoDoBotao(body.texto, body.botao_id);
  const midia = String(body.midia || '').toLowerCase().trim();
  if (midia) {
    if (midia === 'image' || midia === 'imagem') texto = ['[Imagem enviada pelo cliente]', texto].filter(Boolean).join('\n');
    else if (midia === 'location' || midia === 'localizacao') texto = ['[Localização enviada pelo cliente]', texto].filter(Boolean).join('\n');
    else if (!texto) texto = `[MIDIA:${MIDIA_SO.has(midia) ? midia : 'attachment'}]`;
  }
  if (!texto) return fim({ erro: 'texto vazio' });

  entrada = {
    canal: 'teste', telefone: tel, nome: String(body.nome || '').trim(), texto,
    // origem 'auto' = a bateria testa a leitura da mensagem pronta (sem marca → 'direto').
    origem: body.origem === 'auto' ? (origemDoTexto(texto) || 'direto') : (body.origem || 'teste'), chatwootConversationId: null,
    // Envio real (Graph API) só para o número liberado pelo admin "tel real" — nunca para outro.
    enviarReal: body.enviar_real === true && !!sd._telReal && tel === sd._telReal,
  };
} else if (ex('1c · Webhook Chatwoot')) {
  if (modo !== 'chatwoot') return [];
  const wb = $('1c · Webhook Chatwoot').first().json;

  // Validação de origem (padrão no0 da Renata). O n8n 1.94 não entrega o corpo bruto ao Code, então o
  // HMAC não é recalculado: exige o header de assinatura do Chatwoot bem formado e, depois, conta e caixa
  // exatamente as da Nio. Sem assinatura = erro (vai para mari_erros); outra conta/caixa = descarte calado.
  const sig = String((wb.headers || {})['x-chatwoot-signature'] || '');
  if (!sig) throw new Error('[1c] Header x-chatwoot-signature ausente — requisição bloqueada.');
  if (!/^sha256=[0-9a-f]{64}$/.test(sig)) throw new Error('[1c] Formato de assinatura inválido — requisição bloqueada.');

  const b = wb.body || {};
  const contaId = String(b.account?.id ?? b.account_id ?? '');
  const caixaId = String(b.inbox?.id ?? b.inbox_id ?? b.conversation?.inbox_id ?? '');
  if (contaId !== CONFIG.CHATWOOT_NIO_ACCOUNT || caixaId !== CONFIG.CHATWOOT_NIO_INBOX) return [];
  // Prompt 18 (A): conversa RESOLVIDA no Chatwoot encerra o ciclo da Mari (handoff fechado, histórico mantido) — o nó
  // 2v chama mari_encerrar_ciclo. Reaberta sem dono, a Mari volta sabendo o histórico; com dono/time/nao-contatar,
  // o guard 2h continua calando. No evento de status o corpo É a conversa (id, status, inbox_id).
  // Eventos de conversa (o corpo É a conversa): status do Chatwoot sempre; "resolvida" ainda fecha o ciclo (2v).
  if (b.event === 'conversation_status_changed' || b.event === 'conversation_updated') {
    const cid = String(b.id ?? b.conversation?.id ?? '');
    const cwStatus = statusDe(b.conversation || b, cid);
    if (b.event === 'conversation_status_changed' && b.status === 'resolved' && cid) {
      return [{ json: { encerrar: false, registrar: 'resolvida', modo: 'chatwoot', canal: 'whatsapp', chatwootConversationId: cid, cwStatus } }];
    }
    return cwStatus ? [{ json: { soStatus: true, cwStatus } }] : [];
  }
  if (b.event && b.event !== 'message_created') return [];

  const p = b.payload || b;
  const msg = p.message || p;
  const conv = p.conversation || {};
  const sender = msg.sender || conv.meta?.sender || p.sender || {};
  const tipo = msg.message_type ?? p.message_type;
  const entrante = tipo === 0 || tipo === 'incoming' || (msg.sender_type || p.sender?.type) === 'contact';
  const convId = String(conv.id || msg.conversation_id || p.conversation_id || '');
  if (!convId) return [];
  const cwStatus = statusDe(conv, convId);
  if (msg.private) return cwStatus ? [{ json: { soStatus: true, cwStatus } }] : [];

  // Fala do consultor no Chatwoot (saída, não privada, de um usuário): vira turno 'humano' no histórico da Mari,
  // sem resposta. O eco do envio da própria Mari tem o mesmo formato (mesmo usuário do token) — quem o separa é
  // o mari_registrar_turno (texto igual a uma fala da Mari nos últimos 10 min = eco, ignorado).
  const soStatus = cwStatus ? [{ json: { soStatus: true, cwStatus } }] : [];
  const saida = tipo === 1 || tipo === 'outgoing';
  if (saida) {
    if (String(sender.type || msg.sender_type || '').toLowerCase() !== 'user') return soStatus;
    const textoH = String(msg.content || p.content || '').trim();
    const contato = conv.meta?.sender || {};
    const telH = String(contato.phone_number || conv.contact_inbox?.source_id || '').replace(/\D/g, '');
    if (!textoH || !/^\d{10,15}$/.test(telH)) return soStatus;
    return [{ json: { encerrar: false, registrar: 'humano', modo: 'chatwoot', canal: 'whatsapp', telefone: telH,
      nome: String(contato.name || '').trim(), texto: textoH, chatwootConversationId: convId, cwStatus } }];
  }
  if (!entrante) return soStatus;
  const atts = (msg.attachments || p.attachments || []).filter((a) => a && typeof a === 'object');
  const att = atts[0] || {};
  const ft = String(att.file_type || '').toLowerCase();
  // 12/11 (Prompt_midia_transcricao): TODOS os anexos. Áudio e imagem até 16 MB são baixados para o bucket privado
  // (cadeia 2b); vídeo, documento e o resto ficam só registrados (o time abre no Chatwoot). A transcrição que o próprio
  // Chatwoot às vezes manda (transcribed_text) é aproveitada sem custo.
  const LIM = 16 * 1024 * 1024;
  const anexos = atts.map((a, i) => {
    const f = String(a.file_type || '').toLowerCase();
    const tipo = f === 'image' ? 'imagem' : (f === 'audio' || f === 'voice') ? 'audio' : f === 'video' ? 'video' : f === 'location' ? 'local' : f === 'sticker' ? 'figurinha' : 'arquivo';
    const tam = Number(a.file_size) || null;
    const url = String(a.data_url || '');
    return { n: i, tipo, mime: String(a.content_type || '') || null, ext: String(a.extension || '').replace(/[^a-z0-9]/gi, '').toLowerCase() || null,
      tamanho: tam, url: /^https:\/\//.test(url) ? url : null, cw_transcricao: String(a.transcribed_text || '').trim() || null,
      baixar: ['audio', 'imagem'].includes(tipo) && /^https:\/\//.test(url) && (!tam || tam <= LIM) };
  }).filter((a) => a.tipo !== 'local');
  const msgId = String(msg.id ?? p.id ?? Date.now());
  const ca = msg.content_attributes || p.content_attributes || {};
  let texto = textoDoBotao(msg.content || p.content || '', ca.button_reply_id || ca.id || (ca.interactive && ca.interactive.id));
  if (ft === 'image') texto = ['[Imagem enviada pelo cliente]', texto].filter(Boolean).join('\n');
  else if (ft === 'location') texto = ['[Localização enviada pelo cliente]', texto].filter(Boolean).join('\n');
  else if (ft && !texto) texto = `[MIDIA:${MIDIA_SO.has(ft) ? ft : 'attachment'}]`;
  if (!texto) return soStatus;
  entrada = {
    canal: 'whatsapp', telefone: String(sender.phone_number || '').replace(/\D/g, ''),
    nome: String(sender.name || '').trim(), texto,
    origem: origemDoTexto(texto), chatwootConversationId: convId,
    contatoId: sender.id ?? conv.meta?.sender?.id ?? null,   // v7 (A9): nome do contato no handoff
    cwStatus,
    anexos: anexos.length ? anexos : null,
    baixarMidia: anexos.some((a) => a.baixar),
    msgId,
  };
  if (!/^\d{10,15}$/.test(entrada.telefone)) return soStatus;
  // 08/11 (0062): "#zerar" = comando de teste — encerra a conversa da Mari e a próxima mensagem começa do zero. Quem pode
  // é o banco que decide (config_mari_textos.telefones_teste); número fora da lista segue o fluxo normal como fala comum.
  if (/^\s*[#/]\s*zerar\s*$/i.test(texto)) entrada.registrar = 'zerar';
} else {
  return [];
}

// Rate limit (orçamento de chamadas ao Claude por hora, padrão Renata).
sd._apiCalls = (sd._apiCalls || []).filter((t) => Date.now() - t < 3600000);
if (sd._apiCalls.length >= CONFIG.MAX_CHAMADAS_HORA) {
  return fim({ erro: `orçamento esgotado (${sd._apiCalls.length}/${CONFIG.MAX_CHAMADAS_HORA} por hora)` });
}
sd._apiCalls.push(Date.now());

// modo DESTA execução: 'teste' (rota de teste) ou 'chatwoot' (webhook do Chatwoot, só com o interruptor em chatwoot).
const modoExec = entrada.canal === 'teste' ? 'teste' : 'chatwoot';
return [{ json: { encerrar: false, modo: modoExec, config: CONFIG, ...entrada } }];
