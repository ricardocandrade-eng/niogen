// NIOGEN | n8n/mari/n09d_handoff_chatwoot.js — nó "9d · Montar handoff Chatwoot" do mari_principal (05/11/2026, prompt 16 Parte G)
// Adendo 2: todo handoff deixa rastro visível no Chatwoot — etiquetas, nota privada com o briefing e (venda/humano) o time backoffice.
// As automações da conta (24387 resolvida → liberar · 24389 handoff-venda → backoffice · 24390 handoff-humano → backoffice +
// prioridade alta) já existem e NÃO são criadas nem alteradas por aqui.
// Só monta os pedidos; os nós 9e/9f/9h chamam a API (onError = segue, o handoff nunca derruba a resposta ao cliente).

const TIME_BACKOFFICE = 15102;
const NIOGEN = 'https://niogen.dharmatelecom.com.br/vendas.html';

const e = $('2 · Entrada').first().json;
const s = $('10 · Salvar turno').first().json;
const h = $('9 · Handoff').first().json || {};
const b = $input.first().json || {};   // linha de mari_conversas (9b)
let conv = {};
try { conv = $('2g · Chatwoot conversa').first().json || {}; } catch (err) { conv = {}; }

const motivo = (b.handoff_motivo || s.r?.handoff?.motivo || '').trim();
// v7 (prompt 27 A7): a nota começa pelo "1º PASSO: consultar viabilidade no portal" (posto pelo 7 · Extrair) e some
// "DFV: conferir manualmente" / "portal: não consultado — conferir manualmente" (linhas antigas do banco).
const briefing = String(b.handoff_briefing || '').split('\n')
  .filter((l) => !/^\s*(Viabilidade Nio — |DFV: conferir manualmente|DFV: sem base)/.test(l)).join('\n').trim();
const vendaId = h.venda_id || b.venda_id || null;

const VENDA = ['dados_completos'];
const HUMANO = ['pedido_humano', 'objecao', 'urgencia_alta'];
const SAIDA = ['recusa_compra', 'fora_de_area', 'sem_cobertura', 'interesse_caindo', 'multiplos_decisores', 'sem_contato'];

let tipo;
if (VENDA.includes(motivo)) tipo = 'venda';
else if (HUMANO.includes(motivo)) tipo = 'humano';
else if (motivo === 'ja_cliente_nio') tipo = /reclam/i.test(briefing) ? 'humano' : 'saida';   // cliente Nio reclamando = humano agora
else if (SAIDA.includes(motivo)) tipo = 'saida';
else tipo = 'humano';                                                                      // motivo desconhecido: na dúvida, gente

const novas = tipo === 'venda' ? ['handoff', 'handoff-venda'] : tipo === 'humano' ? ['handoff', 'handoff-humano'] : ['handoff'];
const atuais = Array.isArray(conv.labels) ? conv.labels : [];
const labels = [...new Set([...atuais, ...novas])];

const NOME = {
  dados_completos: 'dados completos (venda)', pedido_humano: 'pediu humano', objecao: 'objeção', urgencia_alta: 'urgência alta',
  ja_cliente_nio: 'já é cliente Nio', recusa_compra: 'recusou a compra', fora_de_area: 'fora da área', sem_cobertura: 'sem cobertura',
  interesse_caindo: 'interesse caindo', multiplos_decisores: 'mais de um decisor', sem_contato: 'sem contato',
};
// Prompt 18 (C8): a revenda não cobra nem manda link de pagamento.
// Prompt 19: o link da biometria também não é nosso — a própria Nio dispara (WhatsApp + e-mail) na hora do pedido.
// O briefing vem do modelo; o prompt v6 já proíbe, e isto tira o resto ("enviar o link de biometria e de pagamento").
const semPagamento = (t) => String(t || '')
  .replace(/\s*(?:,|\be\b|\bou\b)\s*(?:o\s+|um\s+)?(?:link\s+)?(?:de|do)\s+pagamento(?:\s+seguro)?/gi, '')
  .replace(/\b(?:enviar|mandar|encaminhar)\s+(?:ao\s+cliente\s+|para\s+o\s+cliente\s+|pro\s+cliente\s+)?(?:o\s+)?links?\s+(?:de|da|do)\s+(?:biometria|pagamento)(?:\s+seguro)?/gi,
    'avisar o cliente do link da biometria que a Nio dispara')
  .replace(/\blinks?\s+de\s+pagamento(?:\s+seguro)?/gi, 'link da biometria (da Nio)');

// Prompt 18 (B4): dados completos e venda NÃO criada (duplicidade ou outro erro) → a nota começa com o aviso e traz o
// link da venda que já existe, para o backoffice decidir.
const naoCriada = motivo === 'dados_completos' && !h.venda_id && h.ok === false;
const existente = h.venda_existente_id || null;
const nota = [
  naoCriada ? `⚠️ VENDA NÃO CRIADA — ${h.motivo_recusa || 'erro ao gravar a venda'}` : null,
  naoCriada && existente ? `Venda que já existe: ${NIOGEN}#venda=${existente}` : null,
  `MARI → BACKOFFICE · ${NOME[motivo] || motivo || 'handoff'}`,
  semPagamento(briefing) || '(sem briefing gravado — ver a conversa)',
  // B3: a nota termina com o link da ficha no NIOGEN.
  vendaId ? `Ficha no NIOGEN: ${NIOGEN}#venda=${vendaId}` : null,
].filter(Boolean).join('\n\n');

// v7 (prompt 27 A9): no handoff de dados completos, o contato do Chatwoot ganha o nome completo — só se o nome atual não
// parecer nome de pessoa ("Família", emoji, vazio, número…). Nunca troca um nome de pessoa.
const nomeAtual = String(e.nome || '').trim();
let nomeNovo = null;
try { nomeNovo = (s.r?.upd?.dados?.nome) || ((($('5b · Motor').first().json.ctx || {}).conversa || {}).dados || {}).nome || null; } catch (err) { nomeNovo = null; }
const NAO_PESSOA = /^(fam[ií]lia|casa|eu|m[ãa]e|pai|amor|vida|cliente|whatsapp|contato|teste|oi|ol[áa]|\.+|-+)$/i;
const pareceNome = (n) => /^[A-Za-zÀ-ÿ'´`.\- ]{3,}$/.test(n) && /[A-Za-zÀ-ÿ]{2,}/.test(n) && !NAO_PESSOA.test(n);
const renomear = motivo === 'dados_completos' && e.contatoId && nomeNovo && !pareceNome(nomeAtual)
  ? { id: e.contatoId, name: String(nomeNovo).trim() } : null;

return [{ json: {
  renomear,
  conta: e.config?.CHATWOOT_NIO_ACCOUNT,
  conversa: e.chatwootConversationId,
  labels, nota, tipo, motivo, vendaId, naoCriada, vendaExistenteId: existente,
  atribuirTime: tipo === 'venda' || tipo === 'humano',
  teamId: TIME_BACKOFFICE,
} }];
