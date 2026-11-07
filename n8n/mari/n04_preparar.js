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

// ── v7 (prompt 27, A2/A3): rua que o CLIENTE escreveu ──
const normR = (s) => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
const PREF = /^(rua|r|avenida|av|travessa|tv|alameda|al|estrada|est|praca|rodovia|rod|beco|largo)\.?\s+/;
const PARADA = new Set(['de', 'da', 'do', 'dos', 'das', 'e']);
const palavras = (s) => normR(s).replace(PREF, '').replace(/[^a-z0-9\s]/g, ' ').split(/\s+/).filter((w) => w && !PARADA.has(w));
const RUA_RE = /\b(rua|r\.|avenida|av\.?|travessa|tv\.?|alameda|estrada|pra[cç]a|rodovia|beco)\s+([A-Za-zÀ-ÿ'.\s]{3,60}?)(?=\s*(?:,|;|\d|\bn[º°o.]|\bn[uú]mero|\bbairro|\bcep|$|\n|\.(?:\s|$)))/i;
function ruaDoCliente() {
  const fontes = [msg, ...(Array.isArray(r.historico) ? r.historico : []).filter((h) => h.papel === 'lead').slice(-6).reverse().map((h) => h.texto)];
  for (const t of fontes) {
    const m = String(t || '').match(RUA_RE);
    if (m) return `${m[1].replace(/\.$/, '')} ${m[2]}`.replace(/\s+/g, ' ').trim();
  }
  return null;
}
const lev1 = (a, b) => {   // distância ≤ 1 (erro de digitação)
  if (a === b) return true;
  if (Math.abs(a.length - b.length) > 1 || Math.min(a.length, b.length) < 5) return false;
  let i = 0, j = 0, d = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) { i++; j++; continue; }
    if (++d > 1) return false;
    if (a.length > b.length) i++; else if (b.length > a.length) j++; else { i++; j++; }
  }
  return d + (a.length - i) + (b.length - j) <= 1;
};
// Diverge = troca de palavra (Sebastião ANTÔNIO × Sebastião PEDRO) ou mais de 1 palavra faltando/sobrando.
function ruaDiverge(cli, cep) {
  const a = palavras(cli), b = palavras(cep);
  if (!a.length || !b.length) return false;
  const sobraA = a.filter((w) => !b.some((x) => lev1(w, x)));
  const sobraB = b.filter((w) => !a.some((x) => lev1(w, x)));
  return (sobraA.length > 0 && sobraB.length > 0) || sobraA.length + sobraB.length > 1;
}
const ruaCli = ruaDoCliente();
const VIA = (cidade, rua) => `https://viacep.com.br/ws/MG/${encodeURIComponent(cidade)}/${encodeURIComponent(rua)}/json/`;

// (A3) Escolha "1/2/3" de uma lista de ruas que a Mari ofereceu (cada opção traz o CEP): vira o CEP escolhido.
if (!out.p_cep && etapaEndereco) {
  const esc = msg.trim().toLowerCase().match(/^(?:a|o|op[cç][aã]o|n[º°o.]?)?\s*([1-3])\s*[.)!]?$|^(primeir|segund|terceir)[ao]$/);
  const ultMari = (Array.isArray(r.historico) ? r.historico : []).filter((h) => h.papel === 'mari').slice(-1)[0];
  let ceps = ultMari ? [...String(ultMari.texto || '').matchAll(/^\s*([1-3])\)[^\n]*?(\d{5})-?(\d{3})/gm)] : [];
  // Opção única escrita em frase ("…, CEP 36092-272. É esse endereço mesmo?") também vale como opção 1.
  if (!ceps.length && ultMari && !conv.cep) {
    const soltos = [...new Set([...String(ultMari.texto || '').matchAll(/\bCEP\s*(\d{5})-?(\d{3})\b/gi)].map((x) => x[1] + x[2]))];
    if (soltos.length === 1) ceps = [[null, '1', soltos[0].slice(0, 5), soltos[0].slice(5)]];
  }
  // Uma opção só e o cliente disse "sim / é essa / isso" = a opção 1.
  const afirma = ceps.length === 1 && /^(sim|isso|essa|e essa|é essa|exato|essa mesma|é essa mesma|correto|certo)\b/i.test(msg.trim());
  if ((esc || afirma) && ceps.length) {
    const n = afirma ? 1 : esc[1] ? Number(esc[1]) : { primeir: 1, segund: 2, terceir: 3 }[esc[2]];
    const alvo = ceps.find((c) => Number(c[1]) === n);
    if (alvo) { out.p_cep = alvo[2] + alvo[3]; out.cepDaLista = true; }
  }
}
// (A3) Sem CEP, com rua: busca no ViaCEP pela rua na cidade (anúncio da campanha 1 = Juiz de Fora) — até 3 opções.
if (!out.p_cep && !conv.cep && etapaEndereco && ruaCli) {
  const cidade = conv.cidade
    || (/juiz de fora|\bjf\b/i.test([msg, ...(r.historico || []).map((h) => h.texto)].join(' ')) ? 'Juiz de Fora' : null)
    || (['meta_ads', 'instagram', 'facebook'].includes(conv.origem) ? 'Juiz de Fora' : null);
  if (!cidade) out.ruaSemCidade = ruaCli;
  else {
    try {
      // O ViaCEP precisa do nome como está no cadastro ("Sebastião Pedro DA Silva"): tenta o nome inteiro sem o
      // "Rua/Av."; sem resultado, tenta sem as palavras de ligação.
      const inteiro = ruaCli.replace(/^(rua|r\.?|avenida|av\.?|travessa|tv\.?|alameda|estrada|pra[cç]a|rodovia|beco)\s+/i, '').trim();
      const busca = palavras(ruaCli).join(' ');
      let lst = inteiro.length >= 3 ? await this.helpers.httpRequest({ method: 'GET', url: VIA(cidade, inteiro), json: true, timeout: 6000 }) : [];
      if ((!Array.isArray(lst) || !lst.length) && busca.length >= 3 && busca !== normR(inteiro)) {
        lst = await this.helpers.httpRequest({ method: 'GET', url: VIA(cidade, busca), json: true, timeout: 6000 });
      }
      const vistos = new Set();
      out.opcoesRua = (Array.isArray(lst) ? lst : []).filter((x) => x && x.cep && !vistos.has(x.cep) && vistos.add(x.cep)).slice(0, 3)
        .map((x) => ({ logradouro: x.logradouro, bairro: x.bairro, cep: x.cep }));
      if (!out.opcoesRua.length) { out.ruaNaoAchada = ruaCli; delete out.opcoesRua; }
    } catch (e) { out.ruaNaoAchada = ruaCli; }
  }
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

// (A2) Rua do CEP diferente da rua que o cliente escreveu: a Mari pergunta qual é antes de seguir (uma vez — depois
// da resposta ela grava [ENDERECO: rua_confirmada=…]).
const ruaCep = (out.p_viacep && out.p_viacep.logradouro) || (conv.endereco_cep && conv.endereco_cep.logradouro) || null;
if (ruaCli && ruaCep && !out.cepDaLista && !((conv.dados || {}).rua_confirmada) && ruaDiverge(ruaCli, ruaCep)) {
  out.ruaDivergente = { cliente: ruaCli, cep: ruaCep };
}

return [{ json: out }];
