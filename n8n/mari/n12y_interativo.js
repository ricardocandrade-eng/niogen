// NIOGEN | n8n/mari/n12y_interativo.js — nó "12y · Montar interativo" do mari_principal (06/11/2026, prompts 26 + 27, Mari v7)
// Monta a mensagem interativa (carrossel de ofertas ou botões) para a Graph API do WhatsApp — SEMPRE pela Graph API
// (phone_number_id 1342993658907403, credencial n8n "WABA Nio (Nio_API)"), nunca pelo Chatwoot. Só dentro da janela de
// 24 h (é resposta ao cliente): mensagem interativa, não template. Textos e imagens vêm do 7 · Extrair (0047, exatos da spec).
// Depois do envio, o 12v deixa uma NOTA PRIVADA no Chatwoot (o backoffice vê o que a Mari mandou) — o 2 · Entrada ignora nota privada.
const s = $('11 · Saída').first().json;
const it = s.interativo || {};
const to = String(s.telefone || '').replace(/\D/g, '');

let interactive;
if (it.tipo === 'carrossel') {
  interactive = {
    type: 'carousel',
    body: { text: it.corpo },
    action: {
      cards: (it.cartoes || []).map((k, i) => ({
        card_index: i,
        type: 'button',
        header: { type: 'image', image: { link: k.imagem } },
        body: { text: k.texto },
        action: { buttons: k.botoes.map((b) => ({ type: 'quick_reply', quick_reply: { id: b.id, title: b.title } })) },
      })),
    },
  };
} else {
  interactive = {
    type: 'button',
    body: { text: it.corpo },
    action: { buttons: (it.botoes || []).map((b) => ({ type: 'reply', reply: { id: b.id, title: b.title } })) },
  };
}

const nota = it.tipo === 'carrossel'
  ? `🤖 Mari enviou ${it.resumo}`
  : `🤖 Mari enviou ${it.resumo}\n\n${it.corpo}`;

return [{ json: {
  graph: { messaging_product: 'whatsapp', recipient_type: 'individual', to, type: 'interactive', interactive },
  nota,
  fallbackTexto: it.fallbackTexto || '',
  tipo: it.tipo,
  conversaId: (s.saida || {}).conversa_id || null,
  chatwootConversationId: s.chatwootConversationId,
  config: s.config,
} }];
