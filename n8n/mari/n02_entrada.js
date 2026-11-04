// NIOGEN | n8n/mari/n02_entrada.js — nó "2 · Entrada" do workflow mari_principal (04/11/2026)
// Normaliza a entrada (rota de teste ou webhook do Chatwoot), aplica o interruptor de modo
// (staticData._modoMari = 'teste' | 'chatwoot'), comandos admin da rota de teste, detecção de mídia
// e rate limit. Sem texto de negócio e sem segredo.

const sd = $getWorkflowStaticData('global');
if (!sd._modoMari) sd._modoMari = 'teste';
const modo = sd._modoMari;

// Preencher na virada para 'chatwoot' (conta/caixa próprias da Nio — nada da conta da Vero).
const CONFIG = {
  CHATWOOT_NIO_ACCOUNT: '',
  CHATWOOT_NIO_INBOX: '',
  MAX_CHAMADAS_HORA: 300,
};

const ex = (n) => { try { return $(n).isExecuted; } catch (e) { return false; } };
const fim = (saida) => [{ json: { encerrar: true, saida } }];

const MIDIA_SO = new Set(['audio', 'voice', 'video', 'sticker', 'document', 'file', 'attachment']);

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
    if (cmd === 'status') return fim({ admin: true, modo: sd._modoMari, chamadas_ultima_hora: (sd._apiCalls || []).length });
    return fim({ admin: true, erro: 'comando desconhecido (use: modo teste | modo chatwoot | status)' });
  }

  if (modo !== 'teste') return fim({ erro: `modo atual é '${modo}' — rota de teste desligada` });

  const tel = String(body.telefone || '').replace(/\D/g, '');
  if (!/^\d{10,15}$/.test(tel)) return fim({ erro: 'telefone inválido (só dígitos, com DDI)' });

  let texto = String(body.texto || '').trim();
  const midia = String(body.midia || '').toLowerCase().trim();
  if (midia) {
    if (midia === 'image' || midia === 'imagem') texto = ['[Imagem enviada pelo cliente]', texto].filter(Boolean).join('\n');
    else if (midia === 'location' || midia === 'localizacao') texto = ['[Localização enviada pelo cliente]', texto].filter(Boolean).join('\n');
    else if (!texto) texto = `[MIDIA:${MIDIA_SO.has(midia) ? midia : 'attachment'}]`;
  }
  if (!texto) return fim({ erro: 'texto vazio' });

  entrada = {
    canal: 'teste', telefone: tel, nome: String(body.nome || '').trim(), texto,
    origem: body.origem || 'teste', chatwootConversationId: null,
  };
} else if (ex('1c · Webhook Chatwoot')) {
  if (modo !== 'chatwoot') return [];
  const wb = $('1c · Webhook Chatwoot').first().json;
  const b = wb.body || wb;
  const p = b.payload || b;
  const msg = p.message || p;
  const conv = p.conversation || {};
  const sender = msg.sender || conv.meta?.sender || p.sender || {};
  const tipo = msg.message_type ?? p.message_type;
  const entrante = tipo === 0 || tipo === 'incoming' || (msg.sender_type || p.sender?.type) === 'contact';
  if (!entrante || msg.private) return [];
  const convId = String(conv.id || msg.conversation_id || p.conversation_id || '');
  if (!convId) return [];
  const att = (msg.attachments || p.attachments || [])[0] || {};
  const ft = String(att.file_type || '').toLowerCase();
  let texto = String(msg.content || p.content || '').trim();
  if (ft === 'image') texto = ['[Imagem enviada pelo cliente]', texto].filter(Boolean).join('\n');
  else if (ft === 'location') texto = ['[Localização enviada pelo cliente]', texto].filter(Boolean).join('\n');
  else if (ft && !texto) texto = `[MIDIA:${MIDIA_SO.has(ft) ? ft : 'attachment'}]`;
  if (!texto) return [];
  entrada = {
    canal: 'whatsapp', telefone: String(sender.phone_number || '').replace(/\D/g, ''),
    nome: String(sender.name || '').trim(), texto,
    origem: null, chatwootConversationId: convId,
  };
  if (!/^\d{10,15}$/.test(entrada.telefone)) return [];
} else {
  return [];
}

// Rate limit (orçamento de chamadas ao Claude por hora, padrão Renata).
sd._apiCalls = (sd._apiCalls || []).filter((t) => Date.now() - t < 3600000);
if (sd._apiCalls.length >= CONFIG.MAX_CHAMADAS_HORA) {
  return fim({ erro: `orçamento esgotado (${sd._apiCalls.length}/${CONFIG.MAX_CHAMADAS_HORA} por hora)` });
}
sd._apiCalls.push(Date.now());

return [{ json: { encerrar: false, modo, config: CONFIG, ...entrada } }];
