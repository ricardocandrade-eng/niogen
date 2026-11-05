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

// (2a') CEP que ficou no histórico sem consulta: o cliente mandou o CEP enquanto um humano atendia (a fala entra
// em mari_turnos, mas o guard cala a Mari antes desta consulta). Sem isso a conversa ficava sem endereço do CEP e
// sem planos — a Mari improvisava bairro e não conseguia mostrar as opções (teste real de 05/11, pendência 34).
if (!out.p_cep && !conv.cep && etapaEndereco) {
  const hist = Array.isArray(r.historico) ? r.historico : [];
  for (let k = hist.length - 1; k >= 0; k--) {
    if (hist[k].papel !== 'lead') continue;
    const m = String(hist[k].texto || '').match(/(?<![\d.])(\d{2})\.?(\d{3})[-\s]?(\d{3})(?![\d])/);
    if (m) { out.p_cep = m[1] + m[2] + m[3]; out.cepDoHistorico = true; break; }
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
  const ROT = /\b(?:n[º°o.]\s*|n[uú]mero\s*:?\s*|num\.?\s*|casa\s+)(\d{1,5}[a-zA-Z]?)\b/i;
  const rot = resto.match(ROT);
  if (rot) num = rot[1];
  else if (/\bs\/?n\b|sem n[uú]mero/i.test(resto)) num = 's/n';
  else if (out.cepDoHistorico) {
    // CEP do histórico: número só com rótulo ("número 500"), procurado também nas falas antigas do cliente —
    // número solto na mensagem de agora ("quero o 1") não é número da casa.
    const hist = Array.isArray(r.historico) ? r.historico : [];
    for (let k = hist.length - 1; k >= 0 && !num; k--) {
      if (hist[k].papel !== 'lead') continue;
      const h = String(hist[k].texto || '').match(ROT);
      if (h) num = h[1];
    }
  } else {
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
