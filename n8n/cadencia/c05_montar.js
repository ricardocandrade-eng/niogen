// NIOGEN | n8n/cadencia/c05_montar.js — nó "5 · Montar envio" do mari_cadencia (04/11/2026)
// Recebe UM candidato (loop de 1) e monta o corpo da mensagem para a API do Chatwoot:
//   texto livre (dentro da janela de 24 h) → { content, message_type, private:false }
//   template (fora da janela)              → { content: corpo renderizado, template_params: { name, category,
//                                              language, processed_params: { body: { "1": …, "2": … } } } }
// (formato do noF4b da Renata, capturado do payload da própria UI do Chatwoot).
// semEnvio = true quando NÃO há envio real: modo teste, canal 'teste', telefone de teste 5500000000xxx ou
// passo ENCERRAR (só muda o status). Nunca o nome da revendedora no texto (o banco já filtra; aqui de novo).

const CONFIG = {
  CHATWOOT_NIO_ACCOUNT: '195428',   // conta própria da Nio no Chatwoot (nunca a da Vero) — prompt 28, 07/11
};

const c = $input.first().json;
const modo = $('2 · Interruptor').first().json.modo;
const tel = String(c.telefone || '');
const texto = String(c.texto || '');

const PROIBIDO = new RegExp(['dh' + 'arma', 'gr[aá]tis', 'gratuit', 'combo', 'pacote', 'nio 5g', '2028', 'sem fidelidade'].join('|'), 'i');
let erro = null;
if (c.acao !== 'encerrar' && (!texto || PROIBIDO.test(texto) || texto.includes('*'))) erro = 'texto vazio ou reprovado no filtro de saída';

const semEnvio = c.acao === 'encerrar' || modo !== 'chatwoot' || c.canal === 'teste' || tel.startsWith('5500000000');

let corpo = null;
if (c.acao === 'texto') {
  corpo = { content: texto, message_type: 'outgoing', private: false };
} else if (c.acao === 'template') {
  const body = {};
  (c.params || []).forEach((v, i) => { body[String(i + 1)] = String(v); });
  corpo = {
    content: texto, message_type: 'outgoing', content_type: 'text',
    template_params: { name: c.template, category: c.categoria || 'MARKETING', language: 'pt_BR', processed_params: { body } },
  };
}

if (!semEnvio && !c.chatwoot_conversation_id) erro = erro || 'conversa sem chatwoot_conversation_id';
if (!semEnvio && !CONFIG.CHATWOOT_NIO_ACCOUNT) erro = erro || 'CHATWOOT_NIO_ACCOUNT vazio';

return [{ json: {
  conversaId: c.conversa_id,
  passo: c.proximo_passo,
  acao: c.acao,
  texto,
  excecao: c.excecao || null,
  semEnvio: semEnvio && !erro,
  erro,
  chatwootConversationId: c.chatwoot_conversation_id || null,
  corpo,
  config: CONFIG,
} }];
