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

// ── v7 (prompt 27, A2/A3): rua que o CLIENTE escreveu ──
const normR = (s) => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
const PREF = /^(rua|r|avenida|av|travessa|tv|alameda|al|estrada|est|praca|rodovia|rod|beco|largo)\.?\s+/;
const PARADA = new Set(['de', 'da', 'do', 'dos', 'das', 'e']);
const palavras = (s) => normR(s).replace(PREF, '').replace(/[^a-z0-9\s]/g, ' ').split(/\s+/).filter((w) => w && !PARADA.has(w));
const RUA_RE = /\b(rua|r\.|avenida|av\.?|travessa|tv\.?|alameda|estrada|pra[cç]a|rodovia|beco)\s+([A-Za-zÀ-ÿ'.\s]{3,60}?)(?=\s*(?:,|;|\d|\bn[º°o.]|\bn[uú]mero|\bbairro|\bcep|$|\n|\.(?:\s|$)))/i;
const ruaDe = (t) => { const m = String(t || '').match(RUA_RE); return m ? `${m[1].replace(/\.$/, '')} ${m[2]}`.replace(/\s+/g, ' ').trim() : null; };
const ROT = /\b(?:n[º°o.]\s*|n[uú]mero\s*:?\s*|num\.?\s*|casa\s+)(\d{1,5}[a-zA-Z]?)\b/i;
// Número da casa escrito junto da rua ("Rua dos Artistas, 123") ou com rótulo ("número 45"), da fala mais nova para a mais antiga.
function numeroJuntoDaRua(textos) {
  for (const t of textos) {
    const s = String(t || ''); const mr = s.match(RUA_RE);
    const h = (mr && s.slice(mr.index + mr[0].length).match(/^\s*,?\s*(?:n[º°o.]\s*|n[uú]mero\s*:?\s*)?(\d{1,5}[a-zA-Z]?)\b/i)) || s.match(ROT);
    if (h) return h[1];
  }
  return null;
}
const leadsRecentes = (Array.isArray(r.historico) ? r.historico : []).filter((h) => h.papel === 'lead').slice(-6).reverse().map((h) => h.texto);
// 18/11 (auditoria do funil, P40): ponto de referência que cita outra rua ("Atrás do banco da Avenida Bandeirantes",
// "Próximo ao Expominas, Avenida Delta") virava "a rua do cliente" e a Mari perguntava "a sua rua é essa ou é a Avenida…?"
// (3 conversas reais). A rua do cliente sai só do trecho ANTES da referência ("Rua das Flores 12, perto da Avenida X" → Rua das
// Flores); texto igual à referência já gravada não conta.
const REF_RE = /(?:^|[\s,;.(-])(perto|pr[oó]xim[oa]s?|atr[aá]s|em frente|de frente|ao lado|do lado|esquina|depois d[oa]|antes d[oa]|refer[eê]ncia|na altura|ao fundo|fundos d[oa])(?=[\s,:]|$)/i;
const refGravada = String(((conv && conv.dados) || {}).referencia || '').trim().toLowerCase();
const semReferencia = (t) => {
  const s = String(t || '');
  if (refGravada && s.trim().toLowerCase() === refGravada) return '';
  const m = s.match(REF_RE);
  return m ? s.slice(0, m.index) : s;
};
// A resposta à pergunta da referência ("Rua da praça") também não é a rua do cliente.
const ultimaMari = (Array.isArray(r.historico) ? r.historico : []).filter((h) => h.papel === 'mari').slice(-1).map((h) => String(h.texto || ''))[0] || '';
const respondeReferencia = /refer[eê]ncia/i.test(ultimaMari);
function ruaDoCliente() {
  for (const t of [msg, ...leadsRecentes]) {
    if (t === msg && respondeReferencia) continue;
    const x = ruaDe(semReferencia(t)); if (x) return x;
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
const DIG = (s) => String(s || '').replace(/\D/g, '');
const dadosConv = conv.dados || {};

// ── CEP pelas opções de rua — DADO GUARDADO, não o texto da Mari (correção de raiz, 07/11) ──
// Teste real 06/11 22h57 (conversa #1): o CEP da opção mostrada só existia no TEXTO da Mari, e o código o procurava na
// última fala dela; quando a Mari confirmou o endereço sem repetir o CEP, ele se perdeu (sem cidade, sem cluster, sem
// planos). Agora: (1) busca com UMA opção só → o CEP é gravado na mesma hora (a Mari confirma rua, bairro e CEP com o
// cliente); (2) várias opções → ficam em mari_conversas.dados.opcoes_rua (7 · Extrair grava) e a escolha do cliente
// ("2", "a segunda", o nome do bairro) é resolvida contra elas.
const escolha = msg.trim().toLowerCase().match(/^(?:a|o|op[cç][aã]o|n[º°o.]?)?\s*([1-3])\s*[.)!]?$|^(?:a |o )?(primeir|segund|terceir)[ao]$/);
const nEsc = escolha ? (escolha[1] ? Number(escolha[1]) : { primeir: 1, segund: 2, terceir: 3 }[escolha[2]]) : null;
const nega = /^(nao|nenhuma|nenhum|errad|outra|outro)\b/.test(normR(msg).trim());
const opcSalvas = !conv.cep && Array.isArray(dadosConv.opcoes_rua) && dadosConv.opcoes_rua.length ? dadosConv.opcoes_rua : null;
if (!out.p_cep && etapaEndereco && opcSalvas) {
  let alvo = nEsc ? opcSalvas[nEsc - 1] || null : null;
  if (!alvo && !nega) {
    const nm = normR(msg);
    const porBairro = opcSalvas.filter((o) => o.bairro && nm.includes(normR(o.bairro)));
    if (porBairro.length === 1) alvo = porBairro[0];
    else if (opcSalvas.length === 1) alvo = opcSalvas[0];
  }
  if (alvo) { out.p_cep = DIG(alvo.cep); out.cepDaLista = true; out.cepOrigem = 'opcao_rua'; out.limparOpcoes = true; }
  else if (nega) { out.limparOpcoes = true; out.opcoesRecusadas = ruaCli ? normR(ruaCli) : true; }
}

// Legado: conversas cujas opções foram mostradas antes desta correção (sem dados.opcoes_rua) — lê o texto da Mari.
if (!out.p_cep && etapaEndereco && !opcSalvas && !conv.cep) {
  const maris = (Array.isArray(r.historico) ? r.historico : []).filter((h) => h.papel === 'mari');
  const ultMari = maris.slice(-1)[0];
  let ceps = ultMari ? [...String(ultMari.texto || '').matchAll(/^\s*([1-3])\)[^\n]*?(\d{5})-?(\d{3})/gm)] : [];
  if (!ceps.length && ultMari) {
    const soltos = [...new Set([...String(ultMari.texto || '').matchAll(/\bCEP\s*(\d{5})-?(\d{3})\b/gi)].map((x) => x[1] + x[2]))];
    if (soltos.length === 1) ceps = [[null, '1', soltos[0].slice(0, 5), soltos[0].slice(5)]];
  }
  const curar = !!conv.numero;   // conversa que passou do endereço sem CEP (como a #1 de 06/11) se cura sozinha
  if (!ceps.length) {
    for (const h of maris.slice(curar ? -14 : -5, -1).reverse()) {
      const t = String(h.texto || '');
      const lst = [...t.matchAll(/^\s*([1-3])\)[^\n]*?(\d{5})-?(\d{3})/gm)];
      const sol = [...new Set([...t.matchAll(/\bCEP\s*(\d{5})-?(\d{3})\b/gi)].map((x) => x[1] + x[2]))];
      if (lst.length === 1) { ceps = lst; break; }
      if (lst.length > 1) break;
      if (sol.length === 1) { ceps = [[null, '1', sol[0].slice(0, 5), sol[0].slice(5)]]; break; }
    }
  }
  const afirma = ceps.length === 1 && !nega;
  if ((nEsc || afirma) && ceps.length) {
    const alvo = ceps.find((x) => Number(x[1]) === (afirma && !nEsc ? 1 : nEsc));
    if (alvo) { out.p_cep = alvo[2] + alvo[3]; out.cepDaLista = true; out.cepOrigem = 'opcao_rua'; }
  }
}

// Busca pela rua (sem CEP) no ViaCEP, na cidade (anúncio da campanha 1 = Juiz de Fora) — até 3 opções.
// Também refaz a busca quando o CEP veio de uma busca anterior e o cliente agora escreve OUTRA rua ("não, é a Rua X").
const ruaAgora = ruaDe(msg);
const endConv = conv.endereco_cep || {};
const refazBusca = !out.p_cep && !!conv.cep && dadosConv.cep_origem === 'busca_rua' && !!ruaAgora && !!endConv.logradouro && ruaDiverge(ruaAgora, endConv.logradouro);
const ruaBusca = refazBusca ? ruaAgora : ruaCli;
const recusada = !refazBusca && ruaBusca && (out.opcoesRecusadas || dadosConv.opcoes_rua_recusadas === normR(ruaBusca));
if (!out.p_cep && (!conv.cep || refazBusca) && etapaEndereco && ruaBusca && !recusada) {
  // 23/11 (L-259, P47): a cidade que o cliente disse para ver os planos (dados.planos_cidade) vale antes do palpite
  // "anúncio = Juiz de Fora" — a cliente de Ubá teve a rua procurada em Juiz de Fora.
  const cidade = (refazBusca ? null : conv.cidade)
    || dadosConv.planos_cidade
    || (/juiz de fora|\bjf\b/i.test([msg, ...(r.historico || []).map((h) => h.texto)].join(' ')) ? 'Juiz de Fora' : null)
    || (['meta_ads', 'instagram', 'facebook'].includes(conv.origem) ? 'Juiz de Fora' : null)
    || conv.cidade;
  if (!cidade) out.ruaSemCidade = ruaBusca;
  else {
    try {
      // O ViaCEP precisa do nome como está no cadastro ("Sebastião Pedro DA Silva"): tenta o nome inteiro sem o
      // "Rua/Av."; sem resultado, tenta sem as palavras de ligação.
      const inteiro = ruaBusca.replace(/^(rua|r\.?|avenida|av\.?|travessa|tv\.?|alameda|estrada|pra[cç]a|rodovia|beco)\s+/i, '').trim();
      const busca = palavras(ruaBusca).join(' ');
      let lst = inteiro.length >= 3 ? await this.helpers.httpRequest({ method: 'GET', url: VIA(cidade, inteiro), json: true, timeout: 6000 }) : [];
      if ((!Array.isArray(lst) || !lst.length) && busca.length >= 3 && busca !== normR(inteiro)) {
        lst = await this.helpers.httpRequest({ method: 'GET', url: VIA(cidade, busca), json: true, timeout: 6000 });
      }
      // 23/11 (L-259, P47): nome com erro de digitação ("gorasiu" × "Gorasil"). O ViaCEP só acha a palavra escrita igual
      // ao cadastro; sem resultado, busca de novo tirando uma palavra de cada vez (ou, com uma palavra só, pelo começo
      // dela) e fica só com a rua cujo nome bate com TODAS as palavras do cliente, cada uma com até 1 letra de diferença
      // (2 em palavra de 8+) ou o mesmo som (l/u no fim, s/z, letra dobrada). Palavra trocada não passa: nunca chuta.
      if (!Array.isArray(lst) || !lst.length) {
        const tk = palavras(ruaBusca);
        const consultas = tk.length >= 2
          ? tk.map((_, i) => tk.filter((__, j) => j !== i).join(' '))
          : tk.filter((w) => w.length >= 6).map((w) => w.slice(0, Math.max(4, w.length - 3)));
        const unicas = [...new Set(consultas.filter((q) => q.length >= 3))].slice(0, 5);
        const voltas = await Promise.all(unicas.map((q) => this.helpers.httpRequest({ method: 'GET', url: VIA(cidade, q), json: true, timeout: 5000 }).catch(() => [])));
        const som = (w) => w.replace(/ph/g, 'f').replace(/[wv]/g, 'v').replace(/y/g, 'i').replace(/z/g, 's').replace(/h/g, '')
          .replace(/l$/, 'u').replace(/(.)\1+/g, '$1');
        const dist = (a, b) => {   // Levenshtein
          const d = Array.from({ length: a.length + 1 }, (_, i) => [i]);
          for (let j = 1; j <= b.length; j++) d[0][j] = j;
          for (let i = 1; i <= a.length; i++) for (let j = 1; j <= b.length; j++) {
            d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
          }
          return d[a.length][b.length];
        };
        const parecida = (a, b) => a === b || som(a) === som(b) || dist(a, b) <= (Math.min(a.length, b.length) >= 8 ? 2 : Math.min(a.length, b.length) >= 5 ? 1 : 0);
        const bate = (x) => { const nome = palavras(x.logradouro); return tk.every((w) => nome.some((n) => parecida(w, n))); };
        const achadas = voltas.flatMap((v) => (Array.isArray(v) ? v : [])).filter((x) => x && x.cep && x.logradouro && bate(x));
        // Entre as que batem, só as de nome mais curto ("Rua Halfeld", não a "Rua Altivo Halfeld").
        const menor = Math.min(...achadas.map((x) => palavras(x.logradouro).length));
        lst = achadas.filter((x) => palavras(x.logradouro).length === menor);
      }
      const vistos = new Set();
      let cands = (Array.isArray(lst) ? lst : []).filter((x) => x && x.cep && !vistos.has(x.cep) && vistos.add(x.cep));
      // Mesmo nome de rua: "Rua Halfeld" não é a "Rua Altivo Halfeld" (se houver a de nome igual, só ela fica).
      const chave = (s) => palavras(s).sort().join(' ');
      const iguais = cands.filter((x) => chave(x.logradouro) === chave(ruaBusca));
      if (iguais.length) cands = iguais;
      // Rua longa = um CEP por faixa de número (ViaCEP "complemento": "de 2105 a 2325 - lado ímpar", "até 9/0010",
      // "de 4107/4108 ao fim", ou um número só = CEP de grande usuário). Com o número da casa, o CEP certo sai da faixa.
      const faixa = (comp) => {
        const s = normR(comp).replace(/\s+/g, ' ').trim();
        if (!s) return { tudo: true };
        const lado = /impar/.test(s) ? 1 : /\bpar\b/.test(s) ? 0 : null;
        const nums = (s.match(/\d+/g) || []).map(Number);
        if (/^ate\b/.test(s) && nums.length) return { de: 0, ate: Math.max(...nums), lado };
        if (/ao fim/.test(s) && nums.length) return { de: Math.min(...nums), ate: Infinity, lado };
        if (/^de\b/.test(s) && nums.length >= 2) return { de: Math.min(...nums), ate: Math.max(...nums), lado };
        if (/^\d+$/.test(s)) return { unico: nums[0] };
        return { tudo: true };   // "(Res M Marinho)", "lado par" sem números… vale a rua inteira
      };
      // Número: junto da rua/rotulado, ou a resposta curta "2000" ao pedido do número (rua com vários CEPs).
      const soNumero = (msg.trim().match(/^(?:n[º°o.]?\s*|n[uú]mero\s*:?\s*)?(\d{1,5})[a-zA-Z]?\s*$/i) || [])[1];
      const numBusca = Number(String(numeroJuntoDaRua([msg, ...leadsRecentes]) || soNumero || conv.numero || '').replace(/\D/g, '')) || null;
      const serve = (x, n) => {
        const f = faixa(x.complemento);
        if (f.unico !== undefined) return f.unico === n;
        if (f.tudo) return true;
        return n >= f.de && n <= f.ate && (f.lado === null || n % 2 === f.lado);
      };
      const temFaixas = cands.some((x) => { const f = faixa(x.complemento); return !f.tudo; });
      if (temFaixas) {
        if (numBusca) {
          const doNumero = cands.filter((x) => serve(x, numBusca));
          cands = doNumero;   // número fora de todas as faixas → nenhuma opção (a Mari pede o CEP)
        } else {
          cands = cands.filter((x) => faixa(x.complemento).unico === undefined);   // sem número: CEP de grande usuário não serve
        }
      }
      const opcoes = cands.slice(0, 3).map((x) => ({ logradouro: x.logradouro, bairro: x.bairro, cep: x.cep }));
      if (cands.length === 1) {
        out.p_cep = DIG(opcoes[0].cep); out.cepDaBusca = { rua: ruaBusca, ...opcoes[0] }; out.cepOrigem = 'busca_rua'; out.limparOpcoes = true;
      } else if (cands.length > 3 && temFaixas && !numBusca) {
        out.ruaPedeNumero = ruaBusca;   // muitos CEPs pelo número: pedir o número (não chutar 3 opções)
      } else if (cands.length > 1) out.opcoesRua = opcoes;
      else out.ruaNaoAchada = ruaBusca;
    } catch (e) { out.ruaNaoAchada = ruaBusca; }
  }
} else if (recusada && !out.p_cep && !conv.cep) out.opcoesRecusadasRua = ruaBusca;

const cepAtual = out.p_cep || conv.cep;

// (2b) Complemento explícito (o "não tem" vem pela tag [ENDERECO] do modelo).
if (cepAtual && ['abertura', 'endereco', 'elegibilidade'].includes(conv.etapa)) {
  // 10/11 (rodada única): "Casa A/B/C" e "Loja" (sem número) são o complemento que o Novo Pedido da Nio pede num menu.
  // Letra maiúscula ("Casa B") em qualquer mensagem; minúscula só na resposta curta ("casa b") — "casa e trabalho" não é.
  let c = resto.match(/\b(ap(?:to|artamento)?\.?\s*\d+\s*[a-z]?|bloco\s*\w+(?:\s*ap(?:to)?\.?\s*\d+)?|casa\s+(?:dos\s+)?fundos|fundos|lote\s*\d+\w*|sala\s*\d+\w*|loja\s*\d+\w*)\b/i);
  if (!c) {
    const casa = resto.match(/\b([Cc]asa\s+[A-E])(?![A-Za-z0-9])/) || (resto.trim().length <= 24 ? resto.match(/\b(casa\s+[a-e])(?![a-z0-9])/i) : null);
    if (casa) c = [casa[0], casa[1].replace(/\s+/g, ' ').replace(/^casa/i, 'Casa').replace(/[a-e]$/, (x) => x.toUpperCase())];
  }
  if (c) {
    out.p_complemento = c[1].replace(/\s+/g, ' ').trim();
    resto = resto.replace(c[1], ' ');   // número da casa não pode sair do complemento
  }
}

// (2c) Número da casa: com rótulo ("nº 123", "número 45", "casa 12") ou número solto numa mensagem curta.
if (cepAtual && (out.p_cep || !conv.numero)) {
  let num = null;
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
  } else if (!(out.cepDaLista && nEsc)) {
    // "2" que escolhe a opção de rua não é o número da casa.
    const curta = resto.replace(/\s+/g, ' ').trim();
    const solto = curta.match(/(?:^|[\s,;])(\d{1,5}[a-zA-Z]?)(?=$|[\s,;.])/);
    if (solto && curta.length <= 60 && !/\d{6,}/.test(curta.replace(/[.\-\s]/g, ''))) num = solto[1];
  }
  // CEP da opção/busca de rua: o número que o cliente escreveu junto da rua ("Rua dos Artistas, 123") numa fala anterior.
  if (!num && (out.cepDaLista || out.cepDaBusca)) num = numeroJuntoDaRua(leadsRecentes);
  if (num) out.p_numero = num.toUpperCase();
}
// CEP novo de uma opção/busca de rua = o MESMO endereço da conversa: o mari_contexto zera número e complemento quando o
// CEP muda, então o que o cliente já deu vai junto (teste real 07/11 00h26: a cura apagou o 123 e o "Apto 403").
if ((out.cepDaLista || out.cepDaBusca) && out.p_cep !== conv.cep) {
  if (!out.p_numero && conv.numero) out.p_numero = String(conv.numero);
  if (!out.p_complemento && conv.complemento) out.p_complemento = String(conv.complemento);
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
if (ruaCli && ruaCep && !out.cepDaLista && !out.cepDaBusca && !((conv.dados || {}).rua_confirmada) && ruaDiverge(ruaCli, ruaCep)) {
  out.ruaDivergente = { cliente: ruaCli, cep: ruaCep };
}

return [{ json: out }];
