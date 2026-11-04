// NIOGEN | n8n/mari/n04_preparar.js — nó "4 · Preparar" do mari_principal (04/11/2026)
// Entrada: resultado 'ok' do mari_consolidar (mensagens pendentes juntas + histórico + conversa).
// Faz: (1) detecta turno só de mídia (vai para a resposta fixa, sem IA); (2) extrai CEP, número e
// complemento da mensagem; (3) CEP novo → ViaCEP (público). O resto (área, cluster, planos, DFV)
// é o mari_contexto no banco. Sem texto de negócio.

const r = $input.first().json;
const conv = r.conversa || {};
const msg = String(r.mensagem || '');
const linhas = msg.split('\n').map((l) => l.trim()).filter(Boolean);
const soMidia = linhas.length > 0 && linhas.every((l) => /^\[MIDIA:\w+\]$/.test(l));

const out = {
  conversa_id: conv.id, consolidado: r, soMidia,
  p_cep: null, p_numero: null, p_complemento: null, p_viacep: null, cepInvalido: false, viacepFalhou: false,
};
if (soMidia) return [{ json: out }];

const etapaEndereco = ['abertura', 'endereco', 'elegibilidade'].includes(conv.etapa) || !conv.cep || /\bcep\b/i.test(msg);

// (2a) CEP: 8 dígitos isolados (36070-480, 36070480, 36.070-480).
let resto = msg;
if (etapaEndereco) {
  const m = msg.match(/(?<![\d.])(\d{2})\.?(\d{3})[-\s]?(\d{3})(?![\d])/);
  if (m) {
    // O lookbehind/lookahead já descarta pedaço de CPF ou telefone formatado.
    out.p_cep = m[1] + m[2] + m[3];
    resto = msg.slice(0, m.index) + ' ' + msg.slice(m.index + m[0].length);
  }
}

const cepAtual = out.p_cep || conv.cep;

// (2b) Complemento explícito (o "não tem" vem pela tag [ENDERECO] do modelo).
if (cepAtual && ['abertura', 'endereco', 'elegibilidade'].includes(conv.etapa)) {
  const c = resto.match(/\b(ap(?:to|artamento)?\.?\s*\d+\s*[a-z]?|bloco\s*\w+(?:\s*ap(?:to)?\.?\s*\d+)?|casa\s+(?:dos\s+)?fundos|fundos|lote\s*\d+\w*|sala\s*\d+\w*|loja\s*\d+\w*)\b/i);
  if (c) {
    out.p_complemento = c[1].replace(/\s+/g, ' ').trim();
    resto = resto.replace(c[1], ' ');   // número da casa não pode sair do complemento
  }
}

// (2c) Número da casa: com rótulo ("nº 123", "número 45", "casa 12") ou número solto numa mensagem curta.
if (cepAtual && (out.p_cep || !conv.numero)) {
  let num = null;
  const rot = resto.match(/\b(?:n[º°o.]\s*|n[uú]mero\s*:?\s*|num\.?\s*|casa\s+)(\d{1,5}[a-zA-Z]?)\b/i);
  if (rot) num = rot[1];
  else if (/\bs\/?n\b|sem n[uú]mero/i.test(resto)) num = 's/n';
  else {
    const curta = resto.replace(/\s+/g, ' ').trim();
    const solto = curta.match(/(?:^|[\s,;])(\d{1,5}[a-zA-Z]?)(?=$|[\s,;.])/);
    if (solto && curta.length <= 60 && !/\d{6,}/.test(curta.replace(/[.\-\s]/g, ''))) num = solto[1];
  }
  if (num) out.p_numero = num.toUpperCase();
}

// (3) ViaCEP para CEP novo.
if (out.p_cep && out.p_cep !== conv.cep) {
  try {
    const v = await this.helpers.httpRequest({ method: 'GET', url: `https://viacep.com.br/ws/${out.p_cep}/json/`, json: true, timeout: 6000 });
    if (v && !v.erro && v.localidade) {
      out.p_viacep = { cep: v.cep, logradouro: v.logradouro || '', bairro: v.bairro || '', localidade: v.localidade, uf: v.uf };
    } else {
      out.cepInvalido = true;
    }
  } catch (e) {
    out.viacepFalhou = true; // fail-open: segue sem o endereço; o prompt pergunta rua e bairro
  }
}

return [{ json: out }];
