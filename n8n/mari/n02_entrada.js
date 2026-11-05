// NIOGEN | n8n/mari/n02_entrada.js — nó "2 · Entrada" do workflow mari_principal (04/11/2026; resolvida → 2v em 05/11, prompt 18)
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

  // A rota de teste funciona nos dois modos (bateria): canal 'teste', resposta só no corpo HTTP,
  // nunca passa pelo Chatwoot (o 2m e o 11 seguem o gatilho, não o interruptor).

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
  if (b.event === 'conversation_status_changed') {
    const cid = String(b.id ?? b.conversation?.id ?? '');
    if (b.status !== 'resolved' || !cid) return [];
    return [{ json: { encerrar: false, registrar: 'resolvida', modo: 'chatwoot', canal: 'whatsapp', chatwootConversationId: cid } }];
  }
  if (b.event && b.event !== 'message_created') return [];   // conversation_updated etc.: o guard lê a conversa ao vivo

  const p = b.payload || b;
  const msg = p.message || p;
  const conv = p.conversation || {};
  const sender = msg.sender || conv.meta?.sender || p.sender || {};
  const tipo = msg.message_type ?? p.message_type;
  const entrante = tipo === 0 || tipo === 'incoming' || (msg.sender_type || p.sender?.type) === 'contact';
  const convId = String(conv.id || msg.conversation_id || p.conversation_id || '');
  if (!convId || msg.private) return [];

  // Fala do consultor no Chatwoot (saída, não privada, de um usuário): vira turno 'humano' no histórico da Mari,
  // sem resposta. O eco do envio da própria Mari tem o mesmo formato (mesmo usuário do token) — quem o separa é
  // o mari_registrar_turno (texto igual a uma fala da Mari nos últimos 10 min = eco, ignorado).
  const saida = tipo === 1 || tipo === 'outgoing';
  if (saida) {
    if (String(sender.type || msg.sender_type || '').toLowerCase() !== 'user') return [];
    const textoH = String(msg.content || p.content || '').trim();
    const contato = conv.meta?.sender || {};
    const telH = String(contato.phone_number || conv.contact_inbox?.source_id || '').replace(/\D/g, '');
    if (!textoH || !/^\d{10,15}$/.test(telH)) return [];
    return [{ json: { encerrar: false, registrar: 'humano', modo: 'chatwoot', canal: 'whatsapp', telefone: telH,
      nome: String(contato.name || '').trim(), texto: textoH, chatwootConversationId: convId } }];
  }
  if (!entrante) return [];
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

// modo DESTA execução: 'teste' (rota de teste) ou 'chatwoot' (webhook do Chatwoot, só com o interruptor em chatwoot).
const modoExec = entrada.canal === 'teste' ? 'teste' : 'chatwoot';
return [{ json: { encerrar: false, modo: modoExec, config: CONFIG, ...entrada } }];
