// NIOGEN | n8n/mari/n07_extrair.js — nós "7 · Extrair" e "7r · Extrair (correção)" do mari_principal (04/11/2026)
// Mesmo código nos dois nós (o build injeta este arquivo em ambos). Faz:
//  1. guard de thinking: só blocos type=text de content[] (lição da Renata, 18/08);
//  2. extrai as tags da Mari e o bloco [HANDOFF] (YAML);
//  3. limpa tags e placeholder vazado (padrão no7 da Renata);
//  4. FILTRO DE SAÍDA determinístico: nome da revendedora, palavras proibidas da Nio, "2028", asterisco,
//     "cobertura confirmada", placeholder. 1ª tentativa com violação → pede reescrita (nó 5c);
//     2ª tentativa com violação → fallback neutro + mari_erros;
//  5. converte tags em atualizações da conversa (p_upd do mari_salvar_turno) e decide o handoff.

const ex = (n) => { try { return $(n).isExecuted; } catch (e) { return false; } };
const motor = $('5b · Motor').first().json;
const ctx = motor.ctx;
const prep = $('4 · Preparar').first().json;
const tentativa = ex('6r · Claude (correção)') ? 2 : 1;
const resp = $input.first().json || {};

const norm = (s) => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');

// v7 (prompt 26, spec §4): "Detalhes <plano>" — texto fixo do cartão, sem Claude e sem filtro (texto aprovado pelo Ricardo).
// 08/11 (abertura B2): o mesmo caminho leva a abertura com 3 botões (interativo), a resposta fixa de cada botão e o
// handoff do "💬 Falar com alguém" — tudo montado no 5b, com tags/upd próprios (dados.abertura, dados.abertura_botao).
if (resp.fixo && (resp.fixo.texto || resp.fixo.interativo)) {
  const fx = resp.fixo;
  const tf = fx.texto ? String(fx.texto) : '';
  const it = fx.interativo || null;
  let modoFx = null;
  try { modoFx = ($('2 · Entrada').first().json || {}).modo; } catch (e) { modoFx = null; }
  return [{ json: {
    corrigir: false, conversaId: ctx.conversaId,
    texto: it ? [tf, it.corpo, `[${it.resumo}]`].filter(Boolean).join('\n\n') : tf,
    tags: fx.tags || { detalhes: fx.plano }, upd: fx.upd || {}, handoff: fx.handoff || null, erro: null,
    baloes: tf ? [tf] : [], interativo: it, emojiAjustes: null, modelo: fx.modelo || 'texto_fixo', tokensIn: null, tokensOut: null,
    latenciaMs: Date.now() - ctx.t0, turnoIds: ctx.turnoIds, promptVersao: ctx.promptVersao, violacoes: null, violacoesCorrigidas: null,
    esperaAntes: modoFx === 'chatwoot' && fx.modelo === 'abertura_b2' ? 2 : 0.1,
  } }];
}

// ── 1. texto (guard de thinking) ──
let bruto = '';
let erroApi = null;
if (Array.isArray(resp.content)) {
  bruto = resp.content.filter((b) => b && b.type === 'text').map((b) => b.text || '').join('\n').trim();
  if (!bruto) erroApi = `resposta sem bloco de texto (stop_reason=${resp.stop_reason || '?'})`;
} else {
  erroApi = String(resp.error?.message || resp.message || JSON.stringify(resp).slice(0, 300));
}
const usage = resp.usage || {};
const tokensIn = (usage.input_tokens || 0) + (usage.cache_read_input_tokens || 0) + (usage.cache_creation_input_tokens || 0) || null;
const tokensOut = usage.output_tokens || null;
// @ensaio-inicio — medição por chamada (07/11): usage separado; no 7r soma a 1ª chamada (6 · Claude). Só a rota de teste devolve.
const usoDe = (u) => ({ input_tokens: u.input_tokens || 0, cache_creation_input_tokens: u.cache_creation_input_tokens || 0,
  cache_read_input_tokens: u.cache_read_input_tokens || 0, output_tokens: u.output_tokens || 0 });
const uso = usoDe(usage);
uso.chamadas = 1;
if (tentativa === 2) {
  try {
    const u1 = usoDe(($('6 · Claude').first().json || {}).usage || {});
    for (const k of Object.keys(u1)) uso[k] += u1[k];
    uso.chamadas = 2;
  } catch (e) { /* sem a 1ª chamada: fica só a da correção */ }
}
uso.modelo = resp.model || motor.model;
uso.corteHist = ctx.corteHist || null;
// @ensaio-fim

// ── 2. tags ──
const tag = (n) => { const m = bruto.match(new RegExp(`\\[${n}\\s*:\\s*([^\\]]*)\\]`, 'i')); return m ? m[1].trim() : null; };
const temTag = (n) => new RegExp(`\\[${n}\\]`, 'i').test(bruto);
const kv = (s) => {
  const o = {};
  String(s || '').split(/[;|]/).forEach((par) => {
    const i = par.indexOf('=');
    if (i > 0) o[par.slice(0, i).trim().toLowerCase()] = par.slice(i + 1).trim();
  });
  return o;
};

let handoffYaml = null;
const hm = bruto.match(/\[HANDOFF\]([\s\S]*?)(\[\/HANDOFF\]|$)/i);
if (hm) {
  handoffYaml = {};
  hm[1].split('\n').forEach((l) => {
    const m = l.match(/^\s*([a-z_]+)\s*:\s*(.*?)\s*$/i);
    if (!m || m[1] === 'lead_data') return;
    let v = m[2].replace(/^["']|["']$/g, '').trim();
    if (!v || v.toLowerCase() === 'null' || /^\[.*\]$/.test(v)) v = null;
    handoffYaml[m[1].toLowerCase()] = v;
  });
}

// v7: o modelo às vezes imita o resumo que o histórico guarda ("[botões: Cartão de crédito / …]", "[carrossel: …]") em vez
// da marca. Vira a marca certa aqui e some do texto (bateria 06/11: o pagamento saiu sem botões por isso).
const imitado = { botoes: null, carrossel: false };
bruto = bruto.replace(/\[bot[oõ]es:\s*([^\]]*)\]/gi, (m, x) => {
  const t = norm(x);
  // A marca DE VERDADE ([BOTOES:pagamento|resumo|sim_nao]) também casa com este padrão (o /i) e era apagada aqui — o
  // pagamento nunca saía pela marca, só pelas travas. Conversa #5 (07/11 18h53): a Mari respondeu só "[BOTOES:pagamento]",
  // a marca sumiu, o texto ficou vazio e o cliente ficou sem resposta. A marca certa fica para o tag('BOTOES').
  if (/^\s*(pagamento|resumo|sim_nao)\s*$/.test(t)) return m;
  // Só pagamento e resumo: "Sim / Não" copiado caía em pergunta aberta (complemento + referência) — teste real 06/11.
  imitado.botoes = /cart|boleto|debito/.test(t) ? 'pagamento' : /corrig|esta certo/.test(t) ? 'resumo' : null;
  return '';
}).replace(/\[carrossel:[^\]]*\]/gi, () => { imitado.carrossel = true; return ''; });

const tags = {
  cidade_detectada: tag('CIDADE_DETECTADA'),
  endereco: tag('ENDERECO'),
  elegibilidade: tag('ELEGIBILIDADE'),
  segmento: tag('SEGMENTO'),
  plano_escolhido: tag('PLANO_ESCOLHIDO'),
  upsell_oferecido: temTag('UPSELL_OFERECIDO') || null,
  dados_coletados: tag('DADOS_COLETADOS'),
  sinal_urgencia: tag('SINAL_URGENCIA'),
  agendamento_retorno: tag('AGENDAMENTO_RETORNO'),
  avaliacao: tag('AVALIACAO'),
  // v7: carrossel e botões (o n8n monta a mensagem interativa) e a pista de Nio/Oi (prompt 27 A10)
  carrossel: temTag('CARROSSEL_PLANOS') || imitado.carrossel || null,
  botoes: tag('BOTOES') || imitado.botoes,
  pista_nio: tag('PISTA_NIO'),
  objecao: tag('OBJECAO'),   // 10/11 (rodada única, Bloco 4b): objeção contornada neste turno
  handoff: handoffYaml,
};
Object.keys(tags).forEach((k) => { if (tags[k] === null) delete tags[k]; });

// ── 3. limpeza ──
const NOMES_TAG = 'CIDADE_DETECTADA|ENDERECO|ELEGIBILIDADE|SEGMENTO|PLANO_ESCOLHIDO|UPSELL_OFERECIDO|DADOS_COLETADOS|SINAL_URGENCIA|AGENDAMENTO_RETORNO|AVALIACAO|CARROSSEL_PLANOS|BOTOES|PISTA_NIO|OBJECAO';
let texto = bruto
  .replace(/\[HANDOFF\][\s\S]*?(\[\/HANDOFF\]|$)/gi, '')
  .replace(new RegExp(`\\[(?:${NOMES_TAG})(?:\\s*:[^\\]]*)?\\]`, 'gi'), '')
  .replace(/^\s*\[?(INTERNAL DATA|ESTADO_ATUAL[^\]]*)\]?.*$/gim, '')
  .replace(/[ \t]+\n/g, '\n')
  .replace(/\n{3,}/g, '\n\n')
  .trim();

// ── 3a. travas do teste real de 07/11 23h08 (conversa #1) ──
const conv0 = ctx.conversa || {};
// Janela pós-handoff (0061): a venda já foi passada ao nosso time há poucos minutos e ninguém da equipe falou ainda.
// A Mari só responde agradecimento ou dúvida final — não muda estado, não faz handoff, não manda botão.
const posHandoff = conv0.status === 'handoff_realizado';
// Cobertura: "A Nio atende o seu endereço ✅" só com o PORTAL viável. O DFV "viável" é pista e não libera a frase — o
// modelo confundiu os dois (portal indisponível, DFV viável). Sem portal viável, a frase vira a da cidade (Passo 3).
if (conv0.nio_viab_resultado !== 'viavel') {
  const cidadeTxt = conv0.cidade ? `A Nio atende ${conv0.cidade} 🎯 ` : '';
  texto = texto.replace(/a nio atende (o )?seu endere[cç]o[.!]?[ \t]*✅?️?[ \t]*/gi,
    `${cidadeTxt}A disponibilidade exata na sua rua o nosso time confirma no sistema da Nio antes de abrir o pedido. `)
    .replace(/[ \t]+\n/g, '\n');
}
// LGPD: uma vez por conversa ("Seus dados são usados só pro seu pedido com a Nio." saiu duas vezes).
if (conv0.lgpd_enviada) {
  texto = texto.replace(/\n*[ \t]*Seus dados s[aã]o usados s[oó] pro seu pedido com a Nio\.?[ \t]*/gi, '').trim();
}

// ── 3b. bloco de condições (prompt v5, decisão do Ricardo 05/11 16h33) ──
// O texto é EXATO: o modelo escreve só a marca [CONDICOES] e o sistema põe o bloco, com a taxa e os meses do plano
// escolhido (varejo = R$ 540 / 12 meses = o texto do Ricardo palavra por palavra; Empresas = 24 meses; sem fidelidade =
// taxa na 1ª fatura, porque "ZERO" seria benefício fora da tabela).
const VERc = Number((String(ctx.promptVersao || '').match(/mari_v(\d+)/) || [])[1] || 0);
// 10/11 (rodada única): texto APROVADO pelo Ricardo em 09/11 ~00h15 — "isenta", sem "grátis"; o Wi-Fi vem do plano.
const COND_ABRE = 'As condições do seu plano:';
let condicoesInseridas = false;
function blocoCondicoes() {
  const codTag = String(tag('PLANO_ESCOLHIDO') || '').toUpperCase().match(/[VE]-[A-Z0-9]+-[A-Z]+/);
  const cod = (codTag && codTag[0]) || (ctx.conversa || {}).plano_escolhido;
  const pl = (ctx.planos || []).find((p) => p.codigo === cod) || null;
  const taxa = pl && pl.taxa_habilitacao != null ? Number(pl.taxa_habilitacao) : 540;
  const taxaTxt = `R$ ${Number.isInteger(taxa) ? taxa : taxa.toFixed(2).replace('.', ',')}`;
  const meses = pl ? pl.isencao_meses : 12;
  const linhaTaxa = meses
    ? `• Taxa de instalação isenta, com fidelidade de ${meses} meses`
    : `• Taxa de instalação (${taxaTxt}) cobrada na 1ª fatura (versão sem fidelidade)`;
  const wifi = pl && pl.wifi ? String(pl.wifi).trim() : 'Wi-Fi';
  return [COND_ABRE, '',
    '• Preço fixo até janeiro/2030',
    linhaTaxa,
    `• Roteador ${wifi} incluído, sem custo`,
    '• 1ª fatura 25 dias depois da instalação (no cartão, no dia da instalação)',
    '', 'A velocidade real depende do aparelho e do Wi-Fi.'].join('\n');
}
if (VERc >= 5 && /\[CONDI[CÇ][OÕ]ES\]/i.test(texto)) {
  // Ensaio 07/11 23h55: "Tô te mandando as condições certinhas:" logo antes da marca só repete a abertura do bloco — sai.
  texto = texto.replace(/(^|\n)[^\n]*condi[cç][oõ]es[^\n]*:[ \t]*(?=\s*(\|\|\s*)?\[CONDI[CÇ][OÕ]ES\])/gi, '$1');
  // O bloco vai sempre sozinho num balão: o sistema põe o "||" antes e depois (balões vazios somem no corte).
  texto = texto.replace(/\[CONDI[CÇ][OÕ]ES\]/gi, () => (condicoesInseridas ? '' : (condicoesInseridas = true, `\n||\n${blocoCondicoes()}\n||\n`)))
    .replace(/(\s*\|\|\s*){2,}/g, '\n||\n').replace(/^\s*\|\|\s*|\s*\|\|\s*$/g, '')
    .replace(/\n{3,}/g, '\n\n').trim();
}

// ── 4. filtro de saída ──
// O nome da revendedora é montado por partes: o export do workflow não pode conter a palavra.
const PROIBIDAS = [
  ['dh' + 'arma', 'o nome da empresa revendedora'], ['gratis', '"grátis"'], ['gratuit', '"gratuito"'], ['combo', '"combo"'], ['pacote', '"pacote"'],
  ['bundle', '"bundle"'], ['nio 5g', '"Nio 5G"'], ['nio movel', '"Nio Móvel"'], ['nio cel', '"Nio Cel"'], ['nio mobile', '"Nio Mobile"'],
  ['chip da nio', '"chip da Nio"'], ['2028', '"2028"'], ['cobertura confirmada', '"cobertura confirmada"'],
  ['fibra dedicada', '"fibra dedicada"'],   // 10/11 (rodada única, §9)
];
// v3 (Bloco 2, itens 4 e 5) — só para o prompt v3 (a v2 usa ✅ 🎯 📍 💰 1️⃣ de propósito).
// Expressão de robô → pede reescrita. Emoji → o motor corrige sozinho (sem gastar outra chamada) e conta.
const VER = Number((String(ctx.promptVersao || '').match(/mari_v(\d+)/) || [])[1] || 0);
const V3 = VER >= 3;
const V4 = VER >= 4;   // venda remota (05/11): instalação no lugar da visita, viabilidade oficial
const V6 = VER >= 6;   // prompt 19 (05/11): o link da biometria é disparado pela própria Nio (WhatsApp + e-mail)
const V7 = VER >= 7;   // prompts 26 + 27 (06/11): carrossel/botões; sem promessa de cobertura nem de prazo
// v7 (prompt 27 A1): quem decide a viabilidade é o PORTAL — antes dele, nenhuma promessa de cobertura no endereço.
// Liberado: "A Nio atende [cidade]" (a cidade) e "a disponibilidade exata na sua rua o nosso time confirma…".
function prometeCobertura(n) {
  if (((ctx.conversa || {}).nio_viab_resultado) === 'viavel') return false;   // portal já disse viável (nível A)
  // Pergunta ou condicional ("pra eu ver se a Nio chega aí", "chega aí?") não é promessa — só afirmação conta.
  return n.split(/(?<=[.?!\n])/).filter((f) => !f.includes('?') && !/\b(ver|saber|confirmar|checar|conferir|olhar) se\b|\bse (a nio |a fibra |ela )?(chega|atende)\b/.test(f)).some((f) =>
    // 07/11 23h10: "atende o seu endereço" (sem o "no") passava pela trava.
    /\b(atende|chega|tem cobertura|tem fibra|tem disponibilidade)\s+(a[ií]\b|na sua rua|no seu endereco|(o )?seu endereco|(a )?sua rua|na sua casa|(a )?sua casa|no seu predio|no seu bairro)/.test(f)
    || /\btem cobertura\b|\bcobertura (no|na|pro|pra) (seu|sua)\b|(seu endereco|sua rua|sua casa) (e|esta|ta|fica) (atendid|coberto|coberta)/.test(f)
    || (/\bboa noticia\b/.test(f) && /atende|cobertura|chega|disponivel/.test(f)));
}
// v7 (prompt 27 A8): prazo para abrir o pedido ou instalar não existe — "em até N horas/minutos", "hoje ainda".
function prometePrazo(n) {
  return n.split(/[.?!\n]+/).some((f) => /\b(pedido|instala|abr[ei]r|abert[oa]|ativa)/.test(f)
    && /\bem ate \d+\s*(h\b|hora|horas|min|minuto|minutos)|\bhoje ainda\b|\bainda hoje\b|\bate amanha\b|\bamanha mesmo\b/.test(f));
}
// v6: frase em que a Mari (ou "o nosso time") promete mandar o link. Liberado: "a própria Nio te manda o link" e negações.
function mandaLinkNosso(n) {
  return n.split(/[.?!\n]+/).some((f) => /\b(mand|envi|encaminh)\w*\b.{0,50}\blink\b/.test(f)
    && /\b(nosso time|nossa equipe|o time|a gente|eu|vou|o consultor|nosso consultor|nos)\b/.test(f)
    && !/\bnio\b.{0,25}\b(mand|envi|dispar)\w*/.test(f) && !/\b(pela|da) (propria )?nio\b/.test(f)
    && !/\b(nao|nunca)\b.{0,30}\b(mand|envi)/.test(f));
}
const FRASES_ROBO = [['prezad', '"Prezado"'], ['informamos', '"Informamos"'], ['gostaria de', '"Gostaria de"'],
  ['fico a disposicao', '"Fico à disposição"'], ['estou aqui para ajudar', '"Estou aqui para ajudar"'],
  ['como posso te ajudar hoje', '"Como posso te ajudar hoje?"'], ['certamente', '"Certamente"'], ['excelente pergunta', '"Excelente pergunta"']];

// Trava de valor/plano fora da tabela (07/11). Devolve o que não bate, para o pedido de reescrita.
function foraDaTabela(t) {
  const n = norm(t);
  const pls = ctx.planos || [];
  const cents = (v) => Math.round(Number(v) * 100);
  const ok = new Set([cents(540)]);   // taxa padrão do bloco de condições
  const add = (v) => { if (v !== null && v !== undefined && v !== '' && Number.isFinite(Number(v))) ok.add(cents(v)); };
  const boletos = [], cartoesP = [];
  for (const p of pls) {
    add(p.preco); add(p.preco_cartao); add(p.taxa_habilitacao);
    if (p.preco != null) boletos.push(Number(p.preco));
    if (p.preco_cartao != null) { cartoesP.push(Number(p.preco_cartao)); add(Number(p.preco) - Number(p.preco_cartao)); }
    for (const v of [p.preco, p.preco_cartao]) {   // preco_dia do 5b · Motor: centavos para cima + "menos de R$N"
      if (v === null || v === undefined) continue;
      const c = Math.ceil(cents(v) / 30); ok.add(c); ok.add((Math.floor(c / 100) + 1) * 100);
    }
  }
  [boletos, cartoesP].forEach((arr) => arr.forEach((a) => arr.forEach((b) => { if (a > b) add(a - b); })));   // upsell "por mais R$X"
  // O que o próprio cliente escreveu ("pago R$ 120 hoje", "tenho 300 mega") pode voltar na fala.
  const cons = prep.consolidado || {};
  const doCliente = norm([cons.mensagem, ...(Array.isArray(cons.historico) ? cons.historico : []).filter((h) => h.papel === 'lead').map((h) => h.texto)].join(' '));
  const RS = /r\$\s*(\d{1,3}(?:\.\d{3})+|\d+)(?:,(\d{1,2}))?/g;
  const valor = (m) => Number(m[1].replace(/\./g, '')) * 100 + (m[2] ? Number(m[2].padEnd(2, '0')) : 0);
  for (const m of doCliente.matchAll(RS)) ok.add(valor(m));
  const fora = [];
  for (const m of n.matchAll(RS)) if (!ok.has(valor(m))) fora.push(m[0].replace(/\s+/g, ''));
  // Velocidades: "500 Mega" / "1 Giga" (GB é a internet 5G, não entra).
  const vel = new Set(pls.map((p) => Number(p.velocidade_mb)).filter(Boolean));
  const velCli = new Set([...doCliente.matchAll(/\b(\d{2,4})\s*(?:mega|mb\b|mbps)/g)].map((m) => Number(m[1])));
  for (const m of n.matchAll(/\b(\d{2,4})\s*(?:mega|mb\b|mbps)/g)) if (!vel.has(Number(m[1])) && !velCli.has(Number(m[1]))) fora.push(m[0]);
  for (const m of n.matchAll(/\b(\d)\s*giga\b/g)) if (!vel.has(Number(m[1]) * 1000)) fora.push(m[0]);
  // Nome de plano: "Nio Turbo" não existe. Liberados os nomes da tabela (Fibra, Essencial, Super, Ultra, Empresas).
  const familias = new Set(['fibra', 'essencial', 'super', 'ultra', 'empresas', 'internet']);
  pls.forEach((p) => String(p.nome || '').split(/\s+/).forEach((w) => familias.add(norm(w))));
  for (const m of String(t || '').matchAll(/\bNio\s+([A-ZÀ-Ú][a-zà-ú]{2,})/g)) if (!familias.has(norm(m[1]))) fora.push(`Nio ${m[1]}`);
  return [...new Set(fora)];
}

// Trava do upsell (portão 09/11, cenário p): "Essencial R$140… por mais R$15 tem o Super" passava na trava geral porque
// R$15 existe na tabela (desconto do cartão). Aqui "por mais R$X" só vale se X for a diferença real entre o plano escolhido
// e um plano acima do mesmo segmento (boleto ou cartão); sem plano identificado, a diferença entre dois planos na mesma forma.
function upsellForaDaConta(t) {
  const n = norm(t);
  const pls = ctx.planos || [];
  const RSX = /por mais r\$\s*(\d+)(?:,(\d{1,2}))?/g;
  const ditos = [...n.matchAll(RSX)].map((m) => Number(m[1]) * 100 + (m[2] ? Number(m[2].padEnd(2, '0')) : 0));
  if (!ditos.length || !pls.length) return [];
  const cents = (v) => Math.round(Number(v) * 100);
  const codTag = String(tags.plano_escolhido || '').toUpperCase().match(/[VE]-[A-Z0-9]+-[A-Z]+/);
  const cod = (codTag && codTag[0]) || (ctx.conversa || {}).plano_escolhido;
  let ch = pls.find((p) => p.codigo === cod) || null;
  if (!ch) {   // "Boa! O Essencial por R$140…" sem a marca: plano pelo nome, antes do "por mais"
    const antes = n.slice(0, n.indexOf('por mais r$'));
    const fam = ['ultra', 'super', 'essencial', 'fibra'].filter((f) => antes.includes(f)).pop();
    const seg0 = ctx.segmento || 'varejo';
    if (fam) ch = pls.find((p) => p.portfolio === seg0 && ['regular', 'oferta50'].includes(p.variante) && norm(p.nome).includes(fam)) || null;
  }
  const ok = new Set();
  const par = (a, b) => {
    if (Number(b.preco) > Number(a.preco)) ok.add(cents(b.preco) - cents(a.preco));
    if (a.preco_cartao != null && b.preco_cartao != null && Number(b.preco_cartao) > Number(a.preco_cartao)) ok.add(cents(b.preco_cartao) - cents(a.preco_cartao));
  };
  if (ch) pls.filter((o) => o.portfolio === ch.portfolio && o.variante === ch.variante).forEach((o) => par(ch, o));
  else pls.forEach((a) => pls.filter((b) => b.portfolio === a.portfolio && b.variante === a.variante).forEach((b) => par(a, b)));
  const R = (c) => `R$${c % 100 ? (c / 100).toFixed(2).replace('.', ',') : c / 100}`;
  return ditos.filter((c) => !ok.has(c)).map((c) => `${R(c)}${ch && ok.size ? ` (a diferença certa a partir do ${String(ch.nome || '').replace(/^Nio (Empresas )?/, '').split(' ')[0]} é ${[...ok].sort((a, b) => a - b).map(R).join(' ou ')})` : ''}`);
}

// 10/11 (rodada única, Bloco 4b): objeção não é despedida. Conversas reais 09/11: #39 "não, pago 119,90 por um giga" →
// recusa_compra no 1º não; #36 "vou ver com meu filho" → despedida. Detecta a objeção na mensagem do cliente e, se a Mari
// encerrou sem ter contornado 2 vezes (e sem um "não quero" explícito), pede reescrita.
const OBJ_RE = {
  consultar_alguem: /\b(ver|falar|conversar|consultar|decidir|olhar) com (o |a )?(meu |minha )?(marido|esposa|mulher|esposo|filh[oa]s?|pai|mae|socio|socia|familia|patrao|chefe)\b/,
  pensar: /\b(vou|deixa eu|preciso|vou ter que) pensar\b|\bdepois (eu )?(vejo|olho|falo|decido|te falo)\b|\bvou (ver|olhar) (direitinho|com calma)\b/,
  preco: /\b(ta|esta|e|achei|muito|meio|bem) (car[oa]|salgad[oa])\b|\bcar[oa] demais\b|\bpreco (ta |esta |e )?(alto|salgado)\b|\bnao cabe no (meu )?bolso\b/,
  ja_tem: /\bja tenho (internet|net|fibra|wi-?fi|plano)\b|\bja (uso|sou cliente)\b|\bme atende (bem|super bem)\b|\bto satisfeit|\bestou satisfeit|\bpago (so )?(r\$ ?)?\d+|\bfidelizad/,
  marca: /\bnao conhec\w* (a )?nio\b|\bmarca nova\b|\bnunca ouvi\b|\b(e|eh) a oi\b|\boi com outro nome\b/,
  sem_5g: /\bnao (preciso|quero|uso) (d[oe] )?(5g|chip|celular|internet movel)\b/,
};
const NAO_QUERO_RE = /\bnao (tenho|tem) interesse\b|\bnao quero\b|\bpode parar\b|\bnao me (mand|cham|lig)\w*\b|\bpara de me\b|\bchega\b|\bvou bloquear\b|\bme (tira|remove) da lista\b|\bsem interesse\b/;
const msgObj = norm((prep.consolidado || {}).mensagem || '');
const objecaoDaMsg = Object.keys(OBJ_RE).find((k) => OBJ_RE[k].test(msgObj)) || null;
const naoQuero = NAO_QUERO_RE.test(msgObj);
const objecoesAntes = (((ctx.conversa || {}).dados || {}).objecoes) || {};
function violacoesDe(t) {
  const n = norm(t);
  const v = PROIBIDAS.filter(([k]) => n.includes(k)).map(([, r]) => `usou a palavra proibida ${r}`);
  if (V3) FRASES_ROBO.filter(([k]) => n.includes(k)).forEach(([, r]) => v.push(`usou a expressão de robô ${r}`));
  // v4 (venda remota, guard-rail 24): nada de visita/presencial e nenhum link — link de biometria/pagamento é do nosso time.
  if (V4 && /visit[ao]|presencial/.test(n)) v.push('falou em visita/presencial (a venda é remota: biometria por link, o técnico só instala)');
  if (V4 && /https?:\/\/|www\./.test(n)) v.push(V6 ? 'mandou um link (a Mari nunca manda link: o da biometria chega pela própria Nio, por WhatsApp e e-mail)'
    : 'mandou um link (link de biometria ou pagamento é do nosso time, nunca da Mari)');
  if (V6 && mandaLinkNosso(n)) v.push('disse que a Mari ou o nosso time manda o link da biometria (guard-rail 24: ele chega pela própria Nio, por WhatsApp e e-mail, assim que o pedido é aberto)');
  // Adendo 05/11 10h05: a viabilidade nunca nega venda — nenhuma fala que negue ou insinue falta de cobertura.
  if (V4 && /nao atende (o seu|seu|esse|aí|ai)|ainda nao chegou|nao chegou (a )?fibra|sem viabilidade|sem cobertura|nao tem (cobertura|fibra)|fibra .{0,20}chegar na sua rua/.test(n)) {
    v.push('negou ou insinuou falta de cobertura (proibido: a viabilidade nunca nega venda; fale da cidade e siga o fluxo)');
  }
  // Guard-rail 23 (afrouxado 05/11): a sugestão de upgrade vem DEPOIS da confirmação da escolha com o valor do plano
  // (a confirmação sorteada da conversa) — o 1º "R$" da resposta tem de vir antes do "por mais R$".
  if (V3 && temTag('UPSELL_OFERECIDO') && /por mais r\$/.test(n) && n.indexOf('r$') >= n.indexOf('por mais r$')) {
    v.push('sugestão de upgrade sem antes confirmar a escolha com o plano e o valor (guard-rail 23)');
  }
  if (VER >= 5) {
    // Prompt 18 (C8): a revenda não cobra, não recebe e não manda link de pagamento — quem cobra é a Nio.
    // Negar é permitido ("não tem link de pagamento", "a gente não cobra"): a frase negada sai antes da checagem
    // (bateria da produção, cenário 30: a negação caía no filtro duas vezes e virava "Só um instante").
    const nPag = n.replace(/\b(nao|nenhum|sem|nunca)\b[^.?!\n]{0,40}?(link (de |do |pro |para o |pra )?pagamento|pagamento seguro|cadastr\w* (do |o |seu )?cartao|cobra\w*)/g, ' ')
      .replace(/\b(a gente|nos|nosso time|o time|o consultor) (nao|nunca) (cobra|vai cobrar|faz a cobranca)/g, ' ');
    if (/link (de |do |pro |para o |pra )?pagamento|pagamento seguro|cadastr\w* (do |o |seu )?cartao|dados do cartao|(a gente|nos|nosso time|o time|o consultor) (cobra|vai cobrar|faz a cobranca)|cobranca (e feita |fica )?(pelo|por|com) (nosso|o nosso|a gente)/.test(nPag)) {
      v.push('falou de link de pagamento ou de cobrança pela revenda (quem cobra é a própria Nio; escolhida a forma, segue direto para manhã ou tarde)');
    }
    // Guard-rail 14: "sem custo" só na linha do roteador do bloco de condições (texto do Ricardo).
    if (n.replace(/roteador em comodato incluido sem custo extra|roteador [^\n]{0,20}incluido, sem custo/g, '').includes('sem custo')) v.push('usou "sem custo" (proibido; a única exceção é a linha do roteador nas condições)');
    // C7: condições só pelo bloco exato ([CONDICOES]); escritas com as próprias palavras → reescrever.
    if (!t.includes(COND_ABRE) && /2030/.test(n) && /roteador/.test(n)) {
      v.push('escreveu as condições com as próprias palavras — use a marca [CONDICOES] sozinha num balão (o sistema põe o texto exato)');
    }
  }
  if (V7 && prometeCobertura(n)) v.push('prometeu cobertura no endereço ("a Nio atende aí", "tem cobertura", "chega na sua rua"): proibido antes do portal — diga "A Nio atende [cidade] 🎯 A disponibilidade exata na sua rua o nosso time confirma no sistema da Nio antes de abrir o pedido."');
  // Teste real 07/11 00h11 (conversa #1): sem CEP/cidade o estado não tinha planos ("NÃO apresente planos nem preços") e,
  // pressionado por "Não recebi nada", o modelo INVENTOU três planos ("Nio Turbo, 500 Mega — R$99,90"). Trava geral (vale
  // com ou sem planos no estado): todo valor em R$, toda velocidade e todo nome "Nio X" da resposta têm de existir na
  // tabela da cidade (config_planos) — ou ser conta dela (diferença entre planos, desconto do cartão, preço por dia) ou
  // algo que o próprio cliente escreveu.
  if (V7) {
    const fora = foraDaTabela(t);
    if (fora.length) {
      v.push((ctx.planos || []).length
        ? `citou valor, velocidade ou plano que não existe na tabela desta cidade (${fora.join('; ')}): use só os planos e valores do [INTERNAL DATA], copiados como estão`
        : `citou preço ou plano sem ter planos no estado (${fora.join('; ')}) — a cidade ainda não foi identificada pelo CEP: não invente nomes nem valores, peça o CEP e o número`);
    }
    const upErr = upsellForaDaConta(t);
    if (upErr.length) v.push(`upsell com a diferença errada ("por mais ${upErr.join('; ')}"): copie o valor do campo upsell do plano escolhido no [INTERNAL DATA]`);
  }
  // Teste real 08/11 00h15: "por mais R$30 o Super já vem com o dobro de velocidade (1 Giga)" — Essencial 800 Mega × Super
  // 1 Giga (+25 %). Comparação ("o dobro", "duas vezes mais", "3x mais", "o triplo", "metade") sobre velocidade, internet ou
  // plano não existe na tabela: a Mari diz os números como estão ("vai de 800 Mega pra 1 Giga").
  if (V7 && n.split(/[.?!\n]+/).some((f) => /\b(o )?dobro\b|\bduas vezes\b|\btres vezes\b|\b\d+\s*x\s+mais\b|\b(o )?triplo\b|\bmetade\b/.test(f)
    && /velocidade|internet|mega|giga|\bgb\b|rapid|plano|wi-?fi|nio (fibra|essencial|super|ultra)|\b(fibra|essencial|super|ultra)\b/.test(f))) {
    v.push('comparou planos com "o dobro"/"duas vezes"/"metade" — isso não está na tabela: diga os números como estão no [INTERNAL DATA] (ex.: "vai de 800 Mega pra 1 Giga e ainda traz Globoplay por 12 meses")');
  }
  // 08/11 00h36: "Esse CPF parece incompleto" para um CPF de 11 dígitos válido (o estado nem tinha CPF ainda). Se o cliente
  // mandou agora um CPF que confere, dizer que ele está errado é proibido → reescrita.
  if (V7 && /\bcpf\b[^.?!\n]{0,40}(incomplet|invalid|errad|nao parece|nao confere)/.test(n)) {
    const okCpf = (x) => { if (x.length !== 11 || /^(\d)\1{10}$/.test(x)) return false; const dv = (k) => { let s = 0; for (let i = 0; i < k; i++) s += Number(x[i]) * (k + 1 - i); const r = (s * 10) % 11; return r === 10 ? 0 : r; }; return dv(9) === Number(x[9]) && dv(10) === Number(x[10]); };
    const cands = [...String((prep.consolidado || {}).mensagem || '').matchAll(/\d[\d.\s-]{9,16}\d/g)].map((m) => m[0].replace(/\D/g, ''));
    if (cands.some(okCpf)) v.push('disse que o CPF está incompleto/errado, mas o CPF que o cliente mandou é válido: emita [DADOS_COLETADOS: …; cpf=…] e siga para o próximo dado');
  }
  // 10/11 (rodada única, §9): economia prometida em reais não existe — pode perguntar quanto o cliente paga hoje.
  if (V7 && /\beconomiz\w*\b[^.?!\n]{0,40}r\$\s*\d|\b(sobra|fica) (r\$\s*\d+[^.?!\n]{0,15}) (a menos|mais barato)/.test(n)) {
    v.push('prometeu economia em reais ("você economiza R$X") — proibido: pergunte quanto o cliente paga hoje e mostre o que a Nio traz');
  }
  if (V7 && handoffYaml && objecaoDaMsg && !naoQuero && Number(objecoesAntes[objecaoDaMsg] || 0) < 2
    && (['recusa_compra', 'multiplos_decisores', 'interesse_caindo'].includes(norm(handoffYaml.motivo_handoff || '').replace(/[^a-z_]/g, ''))
      // portão 10/11 (P21): "continua caro" sem pedir desconto não é insistência de desconto — handoff objecao também é despedida
      || (objecaoDaMsg === 'preco' && !/descont|abaix|faz (um |por )?menos|mais barat/.test(msgObj)
        && norm(handoffYaml.motivo_handoff || '').replace(/[^a-z_]/g, '') === 'objecao'))) {
    v.push(`encerrou a conversa numa objeção (${objecaoDaMsg}) que ainda não foi contornada 2 vezes — objeção não é despedida: tire o [HANDOFF], responda a objeção com UM argumento do Bloco 4b, termine com uma pergunta e emita [OBJECAO: ${objecaoDaMsg}]`);
  }
  if (V7 && prometePrazo(n)) v.push('prometeu prazo para abrir o pedido ou instalar ("em até N horas", "hoje ainda"): não existe — diga "o nosso time confere tudo no sistema da Nio e abre o seu pedido"');
  // v7: o CPF mascarado (123.***.***-30) é o formato pedido — não é markdown.
  if (t.replace(/\d{3}\.?[*x•]{3}\.?[*x•]{3}-?\d{2}/gi, '').includes('*')) v.push('usou asterisco (markdown aparece cru no WhatsApp)');
  if (/\{\{|\[(?:nome|rua|bairro|n[uú]mero|valor|plano|cpf|e-?mail|telefone|dia|per[ií]odo|forma|prazo|data|dd\/mm|taxa|meses|diferen[çc]a|benef[ií]cio|cidade|cep|complemento)[^\]]*\]/i.test(t)) {
    v.push('deixou um campo entre colchetes sem preencher (placeholder)');
  }
  return v;
}
let erro = null;
let violacoesCorrigidas = null;
if (!erroApi) {
  const v = violacoesDe(texto);
  if (v.length && tentativa === 1) {
    return [{ json: { corrigir: true, textoRuim: bruto, violacoes: v, conversaId: ctx.conversaId } }];
  }
  if (v.length) {
    erro = { no: '7r · Extrair (correção)', mensagem: `filtro de saída: ${v.join('; ')}`, payload: { texto_bloqueado: texto, prompt: ctx.promptVersao } };
    texto = 'Só um instante, vou confirmar essa informação com nosso time e já te respondo 😊';
  }
  if (tentativa === 2) {
    try { violacoesCorrigidas = $('7 · Extrair').first().json.violacoes || null; } catch (e) { violacoesCorrigidas = null; }
  }
} else {
  erro = { no: tentativa === 2 ? '6r · Claude (correção)' : '6 · Claude', mensagem: `Claude API: ${erroApi}`, payload: { prompt: ctx.promptVersao } };
  texto = 'Tive uma instabilidade aqui 😕 Pode me mandar sua última mensagem de novo?';
}

// ── 4b. balões ("||", até 3) e regra de emoji da v3 (correção determinística, contada em emojiAjustes) ──
const EMOJI_RE = /\p{Extended_Pictographic}️?/gu;
const EMOJI_PROIBIDOS = new Set(['🎯', '📍', '💰', '✅', '🚀', '✨', '💡', '🔥', '📌', '👉', '⭐']);
let baloes = String(texto || '').split(/\s*\|\|\s*/).map((s) => s.trim()).filter(Boolean);
if (baloes.length > 3) baloes = [baloes[0], baloes[1], baloes.slice(2).join('\n\n')];
const emojiAjustes = [];
// Ricardo (05/11 ~17h15): 💚 em toda saudação e despedida. Quem põe é o sistema (fim deste nó) e ele não conta no limite
// de emoji — o 💚 que o modelo escrever sai aqui, antes da regra de emoji.
const CORACAO = '💚';
// Exceção: na janela pós-handoff o 💚 do "Imagina! 💚" é do modelo (Ricardo, 07/11 23h30).
if (VER >= 5 && !posHandoff) baloes = baloes.map((b) => b.replace(/[ \t]*💚[ \t]*/gu, ' ').trim()).filter(Boolean);
// v4 (Ricardo, 05/11, pendência 47): ✅ e 🎯 liberados SÓ nas falas de cobertura do roteiro — "a Nio atende o seu
// endereço ✅" e "a Nio atende aí em [cidade] 🎯". Viram marcador antes da regra de emoji (não contam no limite) e voltam no fim.
const SELO_OK = '\u0001OK\u0001', SELO_AL = '\u0001AL\u0001';
if (V4) {
  baloes = baloes.map((b) => b
    .replace(/(atende o seu endere[cç]o!?)[ \t]*✅️?/gi, (m, f) => `${f} ${SELO_OK}`)
    .replace(/(atende (?:a[ií] em [^\n.!🎯]{2,40}?|a sua cidade)[.!]?)[ \t]*🎯/gi, (m, f) => `${f.trimEnd()} ${SELO_AL}`)
    // v7 (A1): "A Nio atende Juiz de Fora 🎯" — a fala liberada da cidade
    .replace(/(a nio atende [^\n.!🎯]{2,40}?[.!]?)[ \t]*🎯/gi, (m, f) => `${f.trimEnd()} ${SELO_AL}`));
}
// Janela pós-handoff: o 💚 do "Imagina! 💚" não conta no limite de emoji (vira selo e volta no fim).
const SELO_CO = 'CO';
if (posHandoff) baloes = baloes.map((b) => b.replace(/💚/gu, SELO_CO));
if (V3) {
  const limpa = (s) => s.replace(/[ \t]{2,}/g, ' ').replace(/[ \t]+\n/g, '\n').replace(/^[ \t]+/gm, '').trim();
  baloes = baloes.map((b) => {
    let s = b.replace(/([0-9])️?⃣/g, (m, d) => { emojiAjustes.push('1️⃣→1)'); return `${d})`; });
    s = s.replace(EMOJI_RE, (e) => { const base = e.replace('️', ''); if (EMOJI_PROIBIDOS.has(base)) { emojiAjustes.push(`proibido ${base}`); return ''; } return e; });
    s = s.replace(/^(\s*)(\p{Extended_Pictographic}️?\s*)+/gmu, (m, sp) => { emojiAjustes.push('emoji no começo de linha'); return sp; });
    let visto = 0;
    s = s.replace(EMOJI_RE, (e) => { visto += 1; if (visto > 1) { emojiAjustes.push('2º emoji no mesmo balão'); return ''; } return e; });
    return limpa(s);
  }).filter(Boolean);
  // Cliente que não usa emoji: no máximo 2 na conversa inteira (os já usados vêm do 5b · Motor).
  if (!(ctx.emojiCliente > 0)) {
    let livres = Math.max(0, 2 - (ctx.emojiMari || 0));
    baloes = baloes.map((b) => limpa(b.replace(EMOJI_RE, (e) => { if (livres > 0) { livres -= 1; return e; } emojiAjustes.push('acima de 2 na conversa'); return ''; })));
  }
}
if (V4) baloes = baloes.map((b) => b.split(SELO_OK).join('✅').split(SELO_AL).join('🎯'));
if (posHandoff) baloes = baloes.map((b) => b.split(SELO_CO).join('💚'));
// Prompt 18 (C5/C6): parágrafos separados por linha em branco em todo balão; a lista de planos com uma linha em branco
// entre cada opção. Só as linhas "•" seguidas (resumo e condições) ficam coladas uma na outra.
if (VER >= 5) {
  baloes = baloes.map((b) => {
    const ls = b.split(/\n/).map((l) => l.trim()).filter(Boolean);
    return ls.map((l, i) => (i === 0 ? '' : (l.startsWith('•') && ls[i - 1].startsWith('•') ? '\n' : '\n\n')) + l).join('');
  });
}
// 💚 na saudação: fim do 1º parágrafo da 1ª mensagem da conversa ("Olá, tudo bem? Mari da Nio aqui. 💚").
if (VER >= 5 && ctx.primeira && baloes.length) {
  const ps = baloes[0].split('\n\n');
  // 07/11 23h08: "Oi! Aqui é a Mari, da Nio 👋 💚" — o cumprimento sorteado já tinha emoji. O 💚 TOMA O LUGAR dele.
  ps[0] = `${ps[0].replace(/[ \t]*(\p{Extended_Pictographic}️?[ \t]*)+$/u, '')} ${CORACAO}`;
  baloes[0] = ps.join('\n\n');
}
// "Anotado" a cada dado (5 vezes na conversa #1 de 07/11): um humano não confirma cada resposta, só segue para a próxima.
// Sai a FRASE que só diz "anotado" ("Anotado!", "Perfeito, anotado 😊", "Show, anotado o e-mail."); o resto fica
// ("Show, Ricardo! Anotado." → "Show, Ricardo!"). Fora da despedida de handoff. Se não sobrar nada e não houver botões
// nem carrossel para mandar, a fala fica como veio (nunca deixar o cliente no vácuo).
const soAnotado = (f) => /^((perfeito|show|beleza|otimo|certo|ok|pronto|fechado|boa|massa|tudo certo)[,!. ]+([a-z]+[,!. ]+)?)?anotad[oa]( (o|a) (seu |sua )?[a-z-]+| aqui| tudo)?[.!]*$/
  .test(norm(f).replace(/\p{Extended_Pictographic}️?/gu, '').replace(/\s+/g, ' ').trim());
if (V7 && !handoffYaml && baloes.length) {
  // Só mexe no parágrafo que tem a frase (listas "•" do resumo e das condições ficam intactas).
  const limpos = baloes.map((b) => b.split('\n\n').map((p) => {
    const fr = p.split(/(?<=[.!?])[ \t]+/);
    return fr.some(soAnotado) ? fr.filter((f) => !soAnotado(f)).join(' ').trim() : p;
  })
    .filter(Boolean).join('\n\n')).filter((b) => b.trim());
  if (limpos.length || tags.botoes || tags.carrossel) baloes = limpos;
}
// 10/11 (rodada única, item "sem emoji em pedido de dado"): parágrafo que pede nome, CPF, e-mail, CEP, número,
// complemento ou referência sai sem emoji ("…pode me mandar? 😊" → "…pode me mandar?").
if (V7 && !handoffYaml && baloes.length) {
  const pedeDado = (p) => {
    const q = norm(p);
    return /(nome completo|\bcpf\b|e-?mail|\bcep\b|numero da casa|\bo numero\b|complemento|ponto de referencia|\breferencia\b)/.test(q)
      && /(me (manda|passa|fala|diz|confirma)|pode (me )?(mandar|passar)|qual (o |e o )?(seu|sua)|preciso d|me conta|\?)/.test(q);
  };
  baloes = baloes.map((b) => b.split('\n\n').map((p) => (pedeDado(p) && !/^•/.test(p.trim())
    ? p.replace(/[ \t]*\p{Extended_Pictographic}️?/gu, '').replace(/[ \t]+([?.!,])/g, '$1').trim() : p)).join('\n\n'));
}
texto = baloes.join('\n\n');

// ── 5. atualizações da conversa ──
const c = ctx.conversa || {};
const upd = {};
const dados = {};
const d = kv(tags.dados_coletados);
const hy = handoffYaml || {};
const nome = d.nome || hy.nome;
const cpf = (d.cpf || hy.cpf || '').replace(/\D/g, '');
let tel = (d.telefone || hy.telefone || '').replace(/\D/g, '');
if (/^55\d{10,11}$/.test(tel)) tel = tel.slice(2);
const email = (d.email || hy.email || '').trim();
if (nome && nome !== '—') { dados.nome = nome; upd.nome_confiavel = true; }
if (cpf) dados.cpf = cpf;
// 08/11 (Ricardo): o telefone de contato é o do WhatsApp — a Mari não pergunta; o sistema grava. Celular sem o 9 (como o
// WhatsApp entrega, "553288015161", ou como o modelo copiou na conversa #1, "3288015161") ganha o 9 de volta.
const com9 = (x) => (/^\d{2}[6-9]\d{7}$/.test(x) ? `${x.slice(0, 2)}9${x.slice(2)}` : x);
if (tel) tel = com9(tel);
if (V7 && !tel && !((c.dados || {}).telefone) && c.telefone) {
  tel = com9(String(c.telefone).replace(/\D/g, '').replace(/^55(?=\d{10,11}$)/, ''));
}
if (tel) dados.telefone = tel;
if (email && email !== '—') dados.email = email.toLowerCase();
// 10/11 (rodada única, parte 5): o termômetro precisa destes — antes o motor não gravava.
const foneWaC = com9(String(c.telefone || '').replace(/\D/g, '').replace(/^55(?=\d{10,11}$)/, ''));
if (V7 && tel && foneWaC && tel === foneWaC) dados.telefone_confirmado = true;   // o próprio WhatsApp = confirmado
const cnpj = String(d.cnpj || hy.cnpj || '').replace(/\D/g, '');
if (V7 && cnpj.length === 14) dados.cnpj = cnpj;
const nasc = String(d.nascimento || hy.nascimento || '').trim();
if (V7 && nasc && nasc !== '—' && !/^null$/i.test(nasc)) dados.nascimento = nasc;
if (V7) {
  // Marcas de alerta da conversa (o termômetro e a gaveta mostram): desconto, reclamação/já cliente, "não pedi contato".
  const mAl = norm((prep.consolidado || {}).mensagem || '');
  const al = { ...(((c.dados || {}).alertas) || {}) };
  const agoraIso = new Date().toISOString();
  let novoAl = false;
  if (/descont|abaixa\w* (o |esse )?(preco|valor)|mais barat|faz (um |por )?menos/.test(mAl) && !al.desconto) { al.desconto = agoraIso; novoAl = true; }
  if (/reclama|sem internet|internet (caiu|parou|lenta|ruim|nao funciona)|tecnico nao (veio|apareceu)|ja sou cliente/.test(mAl) && !al.reclamacao) { al.reclamacao = agoraIso; novoAl = true; }
  if (/nao (pedi|solicitei|autorizei)|como (vc|voce|voces) (conseguiu|pegou|achou) meu|nao me (mande|chame|ligue)/.test(mAl) && !al.nao_pedi) { al.nao_pedi = agoraIso; novoAl = true; }
  if (/migra(cao|r)|operadora parceira|outra operadora|desligamento|(pedido|contrato|instalacao) (foi )?cancelad/.test(mAl) && !al.golpe) { al.golpe = agoraIso; novoAl = true; }
  if (novoAl) dados.alertas = al;
  // Objeção contornada (tag do modelo; sem tag, a objeção que a mensagem do cliente trouxe e que a Mari não encerrou).
  const OBJS = ['preco', 'ja_tem', 'marca', 'sem_5g', 'pensar', 'consultar_alguem'];
  const tObj = norm(tags.objecao || '').replace(/[^a-z_]/g, '');
  const objAgora = OBJS.includes(tObj) ? tObj : (!handoffYaml && objecaoDaMsg ? objecaoDaMsg : null);
  if (objAgora && !posHandoff) {
    const ob = { ...(((c.dados || {}).objecoes) || {}) };
    ob[objAgora] = Number(ob[objAgora] || 0) + 1;
    dados.objecoes = ob;
    dados.objecao = objAgora;
    dados.objecoes_n = Number(((c.dados || {}).objecoes_n) || 0) + 1;
  }
  // E-mail repetido para confirmar (Valdo, 09/11): e-mail novo na mensagem do cliente = a confirmar; "sim" depois = confirmado.
  const msgEm = String((prep.consolidado || {}).mensagem || '').match(/[^\s@<>()]+@[^\s@<>()]+\.[a-z]{2,}/i);
  const dAnt = c.dados || {};
  if (msgEm) {
    const e1 = msgEm[0].toLowerCase().replace(/[.,;]+$/, '');
    if (e1 !== String(dAnt.email || '').toLowerCase() || dAnt.email_confirmado === false) { dados.email = e1; dados.email_confirmado = false; }
  } else if (dAnt.email && dAnt.email_confirmado === false
    && /^(sim|s|ss|isso|isso mesmo|exato|correto|certo|certinho|ta certo|esta certo|esta certinho|ta certinho|confirmo|e esse|esse mesmo|pode ser|positivo|aham|uhum|ok|isso ai)\b/.test(norm((prep.consolidado || {}).mensagem || '').trim())) {
    dados.email_confirmado = true;
  }
}

const pag = norm(d.pagamento || hy.forma_pagamento || '');
if (pag) {
  if (/cart|credit/.test(pag)) upd.forma_pagamento = 'cartao';
  else if (/debit|dacc|automat/.test(pag)) upd.forma_pagamento = 'dacc';
  else if (/boleto/.test(pag)) upd.forma_pagamento = 'boleto';
}
const visita = d.visita || hy.visita_preferencia;
if (visita && visita !== '—' && !/^null$/i.test(visita)) upd.visita_preferencia = visita;   // v1–v3
const inst = d.instalacao || hy.instalacao_preferencia;
if (inst && inst !== '—' && !/^null$/i.test(inst)) upd.instalacao_preferencia = inst;           // v4+

// v7 (prompt 27): ponto de referência (o portal exige), operadora atual (A10) e a rua confirmada (A2).
if (V7) {
  const ref = d.referencia || hy.referencia || (tags.endereco ? kv(tags.endereco).referencia : null);
  if (ref && ref !== '—' && !/^null$/i.test(ref)) dados.referencia = ref;
  const op = d.operadora || d.operadora_atual || hy.operadora_atual;
  if (op && op !== '—' && !/^null$/i.test(op)) dados.operadora_atual = op;
  if (tags.pista_nio) dados.pista_nio = tags.pista_nio;
  // 07/11 (correção de raiz da conversa #1): as opções de rua mostradas ao cliente ficam guardadas na conversa — a escolha
  // do próximo turno é resolvida contra elas (4 · Preparar), nunca contra o texto que a Mari escreveu.
  const dc = c.dados || {};
  if (prep.opcoesRua) dados.opcoes_rua = prep.opcoesRua;
  else if (prep.limparOpcoes && dc.opcoes_rua) dados.opcoes_rua = null;
  if (prep.opcoesRecusadas) dados.opcoes_rua_recusadas = prep.opcoesRecusadas === true ? 'sim' : prep.opcoesRecusadas;
  if (prep.cepOrigem) dados.cep_origem = prep.cepOrigem;
  else if (prep.p_cep) dados.cep_origem = 'digitado';   // CEP que o cliente escreveu (agora ou no histórico)
}
if (tags.endereco) {
  const e = kv(tags.endereco);
  if (V7 && e.rua_confirmada) { dados.rua_confirmada = e.rua_confirmada; }
  if (V7 && e.rua_informada) { dados.rua_informada = e.rua_informada; }
  if (e.numero && e.numero !== '—' && !/^(null|nenhum)$/i.test(e.numero)) upd.numero = e.numero.toUpperCase();
  if (e.complemento !== undefined) {
    const sem = /^(nenhum|nao|não|sem|n\/a|null|—|-)?$/i.test(e.complemento.trim());
    upd.complemento = sem ? '' : e.complemento;
    dados.complemento_ok = true;
  }
}
if (prep.p_complemento) dados.complemento_ok = true;

const ELEG = ['ok', 'ja_cliente', 'cancelou_30d', 'fora_area'];
const eleg = norm(tags.elegibilidade || hy.elegibilidade || '').replace(/[^a-z_0-9]/g, '');
if (ELEG.includes(eleg)) upd.elegibilidade = eleg;

if (tags.segmento || hy.segmento) {
  const s = norm(tags.segmento || hy.segmento);
  if (s.includes('empresa')) {
    upd.segmento = 'empresas';
    if (/mei\s*=\s*sim|empresas_mei/.test(s)) upd.mei = true;
    else if (/mei\s*=\s*nao|nmei/.test(s)) upd.mei = false;
  } else if (s.includes('varejo')) upd.segmento = 'varejo';
}

// Plano: código exato do INTERNAL DATA; senão, pelo nome, dentro do segmento atual.
const seg = upd.segmento || ctx.segmento;
const pl = tags.plano_escolhido || hy.plano_escolhido;
if (pl) {
  const cod = pl.toUpperCase().match(/[VE]-[A-Z0-9]+-[A-Z]+/);
  let achado = cod && ctx.planos.find((p) => p.codigo === cod[0]);
  if (!achado) {
    const n = norm(pl);
    const fam = ['ultra', 'super', 'essencial', 'fibra'].find((f) => n.includes(f));
    const nfid = /sem fidelidade/.test(n);
    achado = fam && ctx.planos.find((p) => p.portfolio === seg && norm(p.nome).includes(fam)
      && (nfid ? /nfid/.test(p.variante) : !/nfid/.test(p.variante)));
  }
  if (achado) upd.plano_escolhido = achado.codigo;
}
// Teste real 08/11 00h35: "Quero o Essencial" e o modelo respondeu sem NENHUMA marca ([PLANO_ESCOLHIDO], [CONDICOES]) — o
// plano não foi gravado, as condições só saíram depois do CPF e o resumo dependeu do texto do modelo. Sem plano marcado e o
// cliente escolhendo um ("Quero o plano Nio X", como chega do botão ou do "Quero o X" digitado), o sistema grava a escolha.
if (V7 && !posHandoff && !upd.plano_escolhido && !(ctx.conversa || {}).plano_escolhido) {
  const msgCli = norm((prep.consolidado || {}).mensagem);
  const mq = msgCli.match(/\bquero (?:o |a )?(?:plano )?(?:nio )?(fibra|essencial|super|ultra)\b/);
  const temNfid = /sem fidelidade/.test(msgCli);
  const achadoCli = mq && (ctx.planos || []).find((p) => p.portfolio === seg && norm(p.nome).includes(mq[1])
    && (temNfid ? /nfid/.test(p.variante || '') : !/nfid/.test(p.variante || '')));
  if (achadoCli) upd.plano_escolhido = achadoCli.codigo;
}

if (/seus dados sao usados/.test(norm(texto))) upd.lgpd_enviada = true;
if (tags.upsell_oferecido || /so pra voce saber: por mais/.test(norm(texto))) upd.upsell_oferecido = true;

const ag = tags.agendamento_retorno || null;
const agm = ag && ag.match(/(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2})/);
if (agm) upd.agendamento_retorno = `${agm[1]}T${agm[2]}:00-03:00`;

if (Object.keys(dados).length) upd.dados = dados;

// ── etapa (determinística, a partir do estado + atualizações) ──
const m = { ...c, ...upd, dados: { ...(c.dados || {}), ...dados } };
const cpfOk = (v) => { const x = String(v || '').replace(/\D/g, ''); if (x.length !== 11 || /^(\d)\1{10}$/.test(x)) return false; const dv = (k) => { let s = 0; for (let i = 0; i < k; i++) s += Number(x[i]) * (k + 1 - i); const r = (s * 10) % 11; return r === 10 ? 0 : r; }; return dv(9) === Number(x[9]) && dv(10) === Number(x[10]); };
const temDados = m.dados.nome && cpfOk(m.dados.cpf) && m.dados.telefone && m.dados.email && m.forma_pagamento
  && (V4 ? m.instalacao_preferencia : m.visita_preferencia);
if (!m.cep || !m.numero || !(m.complemento || m.dados.complemento_ok)) upd.etapa = (m.cep || m.numero) ? 'endereco' : 'abertura';
else if (!m.elegibilidade) upd.etapa = 'elegibilidade';
else if (!m.plano_escolhido) upd.etapa = 'planos';
else if (!temDados) upd.etapa = 'coleta';
else upd.etapa = 'resumo';
if (upd.etapa === 'abertura' && c.etapa && c.etapa !== 'abertura') upd.etapa = 'endereco';

// ── handoff ──
const MOTIVOS = ['dados_completos', 'pedido_humano', 'objecao', 'recusa_compra', 'multiplos_decisores',
  'interesse_caindo', 'urgencia_alta', 'sem_cobertura', 'fora_de_area', 'ja_cliente_nio'];
let motivo = null;
if (handoffYaml) {
  motivo = norm(hy.motivo_handoff || '').replace(/[^a-z_]/g, '');
  if (!MOTIVOS.includes(motivo)) motivo = 'pedido_humano';
  // v7 (A10): a Mari NUNCA encerra por "já é cliente" — Nio ativa nesta unidade vira humano (com time).
  if (V7 && motivo === 'ja_cliente_nio') motivo = 'pedido_humano';
}
// v7: "já tem Nio" deixa de ser trava (é pista); a elegibilidade fica ok e a conversa segue.
if (V7 && ['ja_cliente', 'cancelou_30d'].includes(upd.elegibilidade)) upd.elegibilidade = 'ok';
if (V7 && !motivo && !erro) {
  if (upd.elegibilidade === 'fora_area') motivo = 'fora_de_area';
} else if (!motivo && !erro) {
  // v4: fora da área só depois de a Mari confirmar a cidade com o cliente (o modelo emite [ELEGIBILIDADE: fora_area]).
  if ((!V4 && ctx.dentroArea === false) || upd.elegibilidade === 'fora_area') motivo = 'fora_de_area';
  else if (upd.elegibilidade === 'ja_cliente' || upd.elegibilidade === 'cancelou_30d') motivo = 'ja_cliente_nio';
}

let handoff = null;
if (motivo) {
  const notaDfv = {
    viavel: 'DFV viável',
    viavel_predio: 'DFV viável (prédio) — conferir a unidade',
    endereco_ocupado: 'DFV indica Nio ativo no endereço — confirmar com o cliente e no portal antes de abrir o pedido',
  }[c.dfv_resultado] || (c.cidade && norm(c.cidade) === 'juiz de fora' ? 'DFV: conferir manualmente antes de abrir o pedido' : 'DFV: sem base para a cidade — conferir manualmente');
  // v7 (prompt 27 A7): a nota começa pelo PORTAL; o DFV é só pista; Nio/Oi citado vira pista para o backoffice.
  let topo = [];
  if (V7) {
    const dd = { ...(c.dados || {}), ...dados };
    const cepF = String(c.cep || '').replace(/\D/g, '').replace(/^(\d{5})(\d{3})$/, '$1-$2') || '?';
    const comp = upd.complemento !== undefined ? upd.complemento : c.complemento;
    const jf = norm(c.cidade) === 'juiz de fora';
    const pista = {
      viavel: 'Viável', viavel_predio: 'Viável prédio (a unidade o portal confirma)',
      endereco_ocupado: 'indica Nio no endereço — conferir a posse no portal',
      sem_porta_livre: 'sem porta livre na foto da Nio — o portal decide',
    }[c.dfv_resultado] || (jf ? 'Não achou o endereço — pode ser sem cobertura ou endereço fora da foto da Nio; o portal decide'
      : 'sem base do DFV para a cidade — o portal decide');
    topo = [
      `1º PASSO: consultar viabilidade no portal PAP — CEP ${cepF} · nº ${upd.numero || c.numero || '?'} · compl. ${comp || '—'} · ref. ${dd.referencia || '— (pedir ao cliente)'}`,
      `DFV (pista): ${pista}`,
      dd.rua_informada ? `Rua: o cliente escreveu «${dd.rua_informada}»${dd.rua_confirmada ? ` e confirmou «${dd.rua_confirmada}»` : ''} — conferir no portal` : null,
      dd.pista_nio ? `PISTA: cliente citou Nio/Oi (${dd.pista_nio}) — conferir posse e recompra no portal (etapa 2)` : null,
    ].filter(Boolean);
  }
  const briefing = [...topo, hy.briefing_humano, hy.resumo_perfil ? `Perfil: ${hy.resumo_perfil}` : null,
    tags.sinal_urgencia ? `Urgência: ${tags.sinal_urgencia}` : null, V7 ? null : notaDfv].filter(Boolean).join('\n');
  handoff = {
    motivo,
    lead: {
      dados, briefing,
      forma_pagamento: upd.forma_pagamento || c.forma_pagamento || null,
      visita_preferencia: upd.visita_preferencia || c.visita_preferencia || null,
      instalacao_preferencia: upd.instalacao_preferencia || c.instalacao_preferencia || null,
      nio_viab_resultado: c.nio_viab_resultado || null,
      nio_viab_velocidade: c.nio_viab_velocidade || null,
      nio_viab_interesse_id: c.nio_viab_interesse_id || null,
      agendamento_retorno: upd.agendamento_retorno || null,
      yaml: handoffYaml,
    },
  };
  // Rede de segurança: despedida vazia → fala padrão do motivo (roteiro, Bloco 6b).
  if (!texto) {
    const prazo = ctx.dentroHorario ? 'em até 2 horas' : 'no próximo horário de atendimento';
    texto = {
      dados_completos: V7
        ? 'Pronto, tudo certo por aqui!\n\nAgora o nosso time confere tudo no sistema da Nio e abre o seu pedido. Assim que ele for aberto, a própria Nio te manda o link da biometria por WhatsApp e por e-mail — é rapidinho, você faz pelo celular.\n\nDepois a gente confirma a data da instalação por aqui.'
        : V6
        ? `Pronto, anotado!\n\nAgora o nosso time abre o seu pedido, ${prazo}. Assim que ele for aberto, a própria Nio te manda o link da biometria por WhatsApp e por e-mail — é rapidinho, você faz pelo celular.\n\nDepois a gente confirma a data da instalação por aqui.`
        : V4
        ? `Pronto, anotado! Agora o nosso time abre o seu pedido e te manda aqui mesmo, ${prazo}, o link da biometria — é rapidinho, você faz pelo celular. Depois a gente confirma a data da instalação por aqui 😊`
        : `Pronto, anotado! Vou passar pro nosso consultor, que te chama aqui no WhatsApp ${prazo} pra confirmar a visita. Qualquer dúvida é só me chamar 😊`,
      recusa_compra: 'Sem problema! Se mudar de ideia, é só me chamar aqui. Foi um prazer conversar com você 😊',
      fora_de_area: 'Por enquanto a gente atende só algumas cidades de Minas 😕 Obrigada pelo contato!',
      ja_cliente_nio: 'Como o endereço já tem Nio, é direto com eles: App Nio ou 0800 001 1000 😊',
    }[motivo] || `Vou te passar pra um dos nossos consultores, que te chama aqui mesmo ${prazo} 😊`;
  }
}

// 10/11 (Ricardo, 09/11 23h46): fora da área = comunica, agradece e despede, num balão só — nada de televendas, "anotei",
// "vou passar pra Nio" ou "te aviso quando chegar". Texto fixo (não depende do modelo).
if (V7 && handoff && motivo === 'fora_de_area') {
  const dd = { ...(c.dados || {}), ...dados };
  const p1 = String(dd.nome || '').trim().split(/\s+/)[0];
  const nm = p1 && /^[A-Za-zÀ-ÿ']{2,20}$/.test(p1) ? p1.charAt(0).toUpperCase() + p1.slice(1).toLowerCase() : null;
  const cid = String(c.cidade || '').trim();
  texto = `Poxa${nm ? `, ${nm}` : ''}, por enquanto a gente atende só algumas cidades de Minas${cid ? `, e ${cid} ainda não está entre elas` : ''} 😕 Obrigada pelo contato!`;
  baloes = [texto];
}
// Balões finais: texto final (a despedida de segurança acima pode ter preenchido o texto depois do corte).
let baloesFinais = baloes.length && baloes.join('\n\n') === texto ? baloes : (texto ? [texto] : []);
// 💚 na despedida: todo handoff começa com o coração ("💚 Pronto, Ricardo, anotado!").
// v6 (prompt 19): a despedida dados_completos leva o 💚 no fim do 1º parágrafo ("Pronto, Ricardo, anotado! 💚").
if (V6 && handoff && motivo === 'dados_completos' && baloesFinais.length) {
  const ps = baloesFinais[0].split('\n\n');
  if (!ps[0].endsWith(CORACAO)) ps[0] = `${ps[0]} ${CORACAO}`;
  baloesFinais = [ps.join('\n\n'), ...baloesFinais.slice(1)];
  texto = baloesFinais.join('\n\n');
} else if (VER >= 5 && handoff && baloesFinais.length && !baloesFinais[0].startsWith(CORACAO)) {
  baloesFinais = [`${CORACAO} ${baloesFinais[0]}`, ...baloesFinais.slice(1)];
  texto = baloesFinais.join('\n\n');
}

// ── 5b. v7: trava das condições — plano escolhido e condições nunca enviadas = o sistema põe o bloco exato logo depois
// da confirmação (teste real 06/11: o modelo pulou direto para "manhã ou tarde").
// P9 (portão 08/11 22h26, cenário o): com upsell as condições ficavam "para a resposta seguinte" — o cliente ignorou a
// sugestão, mandou o CPF e as condições só chegaram depois dos dados. Agora, com ou sem upsell, saem NA MESMA resposta:
// confirmação (+ sugestão) → condições → pedido de nome/CPF ("ou me fala se prefere trocar", quando houve sugestão).
const upsellAgora = !!tags.upsell_oferecido || /so pra voce saber: por mais|por mais r\$/.test(norm(texto));
// P16 (portão 08/11 22h40): upsell entre planos de mesma velocidade (Super 1 Giga → Ultra 1 Giga) saía "vai de 1 Giga pra
// 1 Giga mesmo (a diferença é o que já vem com), com…". Sem diferença de velocidade, a frase vira "já vem com …".
const MESMA_VEL = /\s+vai de (\d+(?:[.,]\d+)?\s*(?:mega|giga|gb|mb))\s+pra\s+\1\b(?:\s+(?:tamb[eé]m|mesmo))?(?:\s*\([^)]*\))?\s*,?\s*(?:(?:mas|e)\s+)?(?:j[aá]\s+vem\s+com\s+|com\s+)?/i;
if (V7 && upsellAgora && MESMA_VEL.test(texto)) {
  baloesFinais = baloesFinais.map((b) => b.replace(MESMA_VEL, ' já vem com '));
  texto = texto.replace(MESMA_VEL, ' já vem com ');
}
if (V7 && !erro && !handoff && !ctx.condicoesEnviadas && !condicoesInseridas
  && (upd.plano_escolhido || c.plano_escolhido) && baloesFinais.length && !baloesFinais.some((b) => b.includes(COND_ABRE))) {
  // 07/11 23h11 (conversa #1): o modelo pôs confirmação + "Fechou? Me manda seu nome completo e CPF…" num balão só e as
  // condições chegavam DEPOIS do pedido de dados. O pedido (e a linha da LGPD) passa para depois do bloco.
  const ehPedidoDados = (p) => /nome completo|\bcpf\b|seus dados sao usados|^fechou\?/.test(norm(p));
  const ps0 = (upsellAgora ? baloesFinais.join('\n\n') : baloesFinais[0]).split('\n\n');
  const fica = ps0.filter((p) => !ehPedidoDados(p));
  const vai = ps0.filter(ehPedidoDados);
  // 08/11 00h36: o pedido saía como o modelo escreveu ("Fechou?" solto + "Agora preciso confirmar seus dados: me manda…" +
  // LGPD) — confuso. Depois das condições, o pedido é a frase do roteiro, e a LGPD só na primeira vez.
  const pedidoDados = [upsellAgora
    ? 'Fechou? Me manda seu nome completo e CPF que eu já adianto aqui (ou me fala se prefere trocar de plano).'
    : 'Fechou? Me manda seu nome completo e CPF que eu já adianto aqui.',
    (ctx.conversa || {}).lgpd_enviada ? null : 'Seus dados são usados só pro seu pedido com a Nio.'].filter(Boolean).join('\n\n');
  const jaTemNomeCpf = !!(((ctx.conversa || {}).dados || {}).cpf || dados.cpf);
  if (upsellAgora) {
    // confirmação + sugestão num balão só (máx. 3 balões): [confirmação e sugestão] · [condições] · [pedido de dados]
    baloesFinais = [fica.join('\n\n'), blocoCondicoes(), jaTemNomeCpf ? (vai.join('\n\n') || null) : pedidoDados].filter(Boolean);
  } else {
    baloesFinais = (fica.length && vai.length
      ? [fica.join('\n\n'), blocoCondicoes(), jaTemNomeCpf ? vai.join('\n\n') : pedidoDados, ...baloesFinais.slice(1)]
      : [baloesFinais[0], blocoCondicoes(), ...baloesFinais.slice(1)]).slice(0, 4);
  }
  texto = baloesFinais.join('\n\n');
  if (/seus dados sao usados/.test(norm(texto))) upd.lgpd_enviada = true;   // a marcação da linha 522 roda antes deste bloco
}

// ── 6. v7: CPF mascarado na fala da Mari (prompt 27 A6 — o banco guarda inteiro) ──
if (V7) {
  // Inteiro → mascarado; e a máscara que o modelo inventar ("529.XXX.XXX-25", "•••") vira o padrão.
  // 07/11 23h14 (conversa #1): o modelo copiou o EXEMPLO do prompt ("123.***.***-30") no lugar do CPF do cliente. Com o CPF
  // guardado (11 dígitos), a máscara sai SEMPRE dele — o que o modelo escreveu na linha do CPF é ignorado.
  const cpfReal = String(dados.cpf || ((c.dados || {}).cpf) || '').replace(/\D/g, '');
  const cpfMasc = cpfReal.length === 11 ? `${cpfReal.slice(0, 3)}.***.***-${cpfReal.slice(9)}` : null;
  const CPF_QQ = /\b\d{3}\.?[\dx*•]{3}\.?[\dx*•]{3}-?\d{2}\b/gi;
  const mascara = (s) => s.split('\n').map((l) => (/cpf/i.test(l)
    ? (cpfMasc ? l.replace(CPF_QQ, cpfMasc)
      : l.replace(/\b(\d{3})\.?(\d{3})\.?(\d{3})-?(\d{2})\b/g, '$1.***.***-$4')
        .replace(/\b(\d{3})\.?[x*•]{3}\.?[x*•]{3}-?(\d{2})\b/gi, '$1.***.***-$2')) : l)).join('\n');
  // Telefone do resumo no mesmo formato da confirmação ("32 98801-5161"), não "32988015161".
  // + CEP do endereço do resumo com hífen ("CEP 36035130" → "CEP 36035-130", teste real 08/11 00h37).
  const telFmt = (s) => s.replace(/^(•\s*Telefone:\s*)\(?(\d{2})\)?\s*(9?\d{4})-?\s*(\d{4})\s*$/gim, '$1$2 $3-$4')
    .replace(/^(•\s*Endere[cç]o:.*\bCEP\s*)(\d{5})(\d{3})\b/gim, '$1$2-$3');
  baloesFinais = baloesFinais.map((b) => telFmt(mascara(b)));
  texto = telFmt(mascara(texto));
}

// ── 7. v7: mensagem interativa (prompt 26) — o n8n manda pela Graph API depois dos balões ──
let interativo = null;
const inter = ctx.inter || {};
const txts = inter.textos || {};
const moeda = (v) => Number(v).toFixed(2).replace('.', ',');
function listaTexto() {
  // Fallback do carrossel: a lista em texto do Passo 3 (mesmos números do banco).
  const seg2 = upd.segmento || ctx.segmento;
  const pls = (ctx.planos || []).filter((p) => p.portfolio === seg2 && !/nfid/i.test(p.variante || '')).sort((a, b) => a.preco - b.preco).slice(0, 4);
  if (!pls.length) return '';
  return pls.map((p, i) => `${i + 1}) ${String(p.nome).replace(/\s*\(.*?\)\s*/g, ' ').trim()} — R$${moeda(p.preco).replace(',00', '')} por mês`
    + (!ctx.btu && p.preco_cartao != null ? ` (R$${moeda(p.preco_cartao).replace(',00', '')} no cartão)` : '')).join('\n\n')
    + '\n\nQual te agrada mais?';
}
if (V7 && !erro && tags.carrossel) {
  const cards = Array.isArray(inter.cartoes) ? inter.cartoes : [];
  // Trava de preço (spec §3): os dois valores do texto do cartão têm de bater com config_planos.
  const divergentes = cards.filter((k) => {
    const v = [...String(k.texto_card).matchAll(/R\$\s*([\d.]+,\d{2})/g)].map((m) => Number(m[1].replace(/\./g, '').replace(',', '.')));
    return v.length < 2 || v[0] !== Number(k.preco) || v[1] !== Number(k.preco_cartao);
  });
  if (ctx.carrossel && cards.length && !divergentes.length) {
    const resumo = `carrossel: ${cards.map((k) => `${String(k.nome_curto || k.nome).split(' ')[0]} R$${Number(k.preco)}/${Number(k.preco_cartao)}`).join(' · ')}`;
    interativo = {
      tipo: 'carrossel', corpo: txts.carrossel_corpo || 'Essas são as ofertas especiais Nio!',
      cartoes: cards.map((k) => ({ imagem: k.imagem_url, texto: k.texto_card, botoes: [
        { id: `plano:${k.plano_codigo}:quero`, title: k.titulo_quero }, { id: `plano:${k.plano_codigo}:detalhes`, title: k.titulo_detalhes }] })),
      resumo, fallbackTexto: listaTexto(),
    };
  } else {
    // Não pode carrossel (BTU, Empresas, sem config) ou preço divergente → lista em texto agora.
    const lt = listaTexto();
    if (lt) { baloesFinais = [...baloesFinais, lt]; texto = baloesFinais.join('\n\n'); }
    else if (!divergentes.length) {
      // Rede de segurança (teste real 06/11, conversa #1): o modelo pediu o carrossel mas o estado não tem cluster/planos
      // (CEP nunca confirmado). Antes a frase "Olha as opções:" saía sozinha, sem nada depois, e nada era registrado.
      // Agora: tira o convite vazio, pede o CEP e deixa o rastro em mari_erros.
      const ult = baloesFinais.length - 1;
      if (ult >= 0) baloesFinais[ult] = baloesFinais[ult].replace(/\s*Olha as op[cç][õo]es:?\s*$/i, '').trim();
      baloesFinais = [...baloesFinais.filter(Boolean), 'Só falta confirmar o seu CEP pra eu te mostrar as opções certinhas 😊 Qual é o CEP?'];
      texto = baloesFinais.join('\n\n');
      erro = erro || { no: '7 · Extrair', mensagem: 'carrossel_sem_cluster', payload: { cidade: tags.cidade_detectada || null, cep: (ctx.conversa || {}).cep || null } };
    }
    if (divergentes.length) erro = erro || { no: '7 · Extrair', mensagem: 'carrossel_preco_divergente', payload: { planos: divergentes.map((k) => k.plano_codigo) } };
  }
}
// v7: e-mail que o cliente mandou e o modelo não registrou em [DADOS_COLETADOS] (bateria 06/11) — o sistema registra.
// Idem o telefone: "é esse mesmo / este número / o do WhatsApp" = o telefone desta conversa.
if (V7 && !m.dados.telefone && /\b(esse|este) (mesmo|numero|n[uú]mero)|mesmo (numero|n[uú]mero)|do (proprio )?whats/.test(norm((prep.consolidado || {}).mensagem))) {
  const tw = String((ctx.conversa || {}).telefone || '').replace(/\D/g, '').replace(/^55(?=\d{10,11}$)/, '');
  if (tw) { dados.telefone = tw; dados.telefone_confirmado = true; upd.dados = { ...(upd.dados || {}), telefone: tw, telefone_confirmado: true }; m.dados.telefone = tw; }
}
if (V7 && !m.dados.email) {
  const em = String((prep.consolidado || {}).mensagem || '').match(/[^\s@<>()]+@[^\s@<>()]+\.[a-z]{2,}/i);
  if (em) { dados.email = em[0].toLowerCase(); upd.dados = { ...(upd.dados || {}), email: dados.email }; m.dados.email = dados.email; }
}
// 07/11 (bateria (a), 2 de 2): "Edson Teste da Silva, CPF 529.982.247-25" e o modelo não emitiu [DADOS_COLETADOS] —
// nome e CPF só apareciam no handoff, e a trava do pagamento (que exige os dois) nunca disparava. CPF com dígito
// verificador válido na mensagem do cliente = o CPF; o texto antes dele ("Nome, CPF …"), com 2+ palavras, = o nome.
if (V7 && !cpfOk(m.dados.cpf)) {
  const msgC = String((prep.consolidado || {}).mensagem || '');
  const mc = msgC.match(/(?<!\d)(\d{3})\.?(\d{3})\.?(\d{3})-?(\d{2})(?!\d)/);
  if (mc && cpfOk(mc.slice(1).join(''))) {
    dados.cpf = mc.slice(1).join(''); m.dados.cpf = dados.cpf;
    const antes = msgC.slice(0, mc.index).replace(/[,;:.\-–]+/g, ' ')
      .replace(/^\s*(?:o\s+)?meu\s+nome(?:\s+completo)?(?:\s+(?:é|e))?\s+/i, ' ')
      .replace(/\s+(?:e\s+)?(?:o\s+)?(?:meu\s+)?cpf(?:\s+(?:é|e))?\s*$/i, ' ').replace(/^\s*cpf(?:\s+(?:é|e))?\s*$/i, ' ')
      .replace(/\s+/g, ' ').trim();
    if (!m.dados.nome && /^[A-Za-zÀ-ÿ']+(?: [A-Za-zÀ-ÿ']+){1,6}$/.test(antes)) { dados.nome = antes; m.dados.nome = antes; upd.nome_confiavel = true; }
    upd.dados = { ...(upd.dados || {}), ...dados };
  }
}
// 07/11 (conversa #5): o modelo pediu o nome e confirmou o telefone sem emitir [DADOS_COLETADOS] — nome e telefone
// nunca entraram no estado e a trava do pagamento (que exige o telefone) não disparou. O sistema registra pela pergunta
// da Mari logo antes: "nome completo" + resposta só com o nome (2+ palavras) = o nome; "Só confirmando: 32 98454-2284?"
// + "sim" = o telefone.
{
  const histC = Array.isArray((prep.consolidado || {}).historico) ? prep.consolidado.historico : [];
  const ultMari = String((histC.filter((h) => h && h.papel === 'mari').pop() || {}).texto || '');
  const msgC = String((prep.consolidado || {}).mensagem || '').trim();
  if (V7 && !m.dados.nome && /nome completo|seu nome/.test(norm(ultMari))
    && /^[A-Za-zÀ-ÿ']+(?: [A-Za-zÀ-ÿ']+){1,6}$/.test(msgC) && !/\b(sim|nao|ok|isso|oi|ola)\b/.test(norm(msgC))) {
    dados.nome = msgC; m.dados.nome = msgC; upd.dados = { ...(upd.dados || {}), nome: msgC };
  }
  const telConf = ultMari.match(/confirmando:?\s*\(?(\d{2})\)?\s*(9?\d{4})[\s-]?(\d{4})\s*\?/i);
  if (V7 && !m.dados.telefone && telConf && /^(sim|s|ss|isso|isso mesmo|exato|correto|certo|confirmo|esse mesmo|e esse|e sim|positivo)\b/.test(norm(msgC))) {
    const tc = telConf.slice(1).join('');
    dados.telefone = tc; dados.telefone_confirmado = true; m.dados.telefone = tc;
    upd.dados = { ...(upd.dados || {}), telefone: tc, telefone_confirmado: true };
  }
}
// Forma de pagamento tocada no botão (ou digitada) e não registrada pelo modelo — o sistema registra.
if (V7 && !m.forma_pagamento) {
  const fm = norm((prep.consolidado || {}).mensagem).trim();
  const f = /^(cartao|cartao de credito|credito|no cartao)\b/.test(fm) ? 'cartao' : /^(boleto|boleto bancario|no boleto)\b/.test(fm) ? 'boleto'
    : /^(debito|debito automatico|dacc)\b/.test(fm) ? 'dacc' : null;
  if (f) { upd.forma_pagamento = f; m.forma_pagamento = f; }
}
// Trava do pagamento (bateria 06/11; 07/11): plano escolhido, telefone e e-mail completos e sem forma de pagamento = a
// próxima pergunta é o pagamento (ordem do Passo 4). Dispara quando a Mari não perguntou nada ("Anotado o e-mail!") ou
// pulou para "manhã ou tarde" (essa pergunta sai). Se ela está pedindo outra coisa (o CPF que falta…), não dispara.
// Resumo de conferência: "confere os dados", e também o refeito depois de "Corrigir" ("Confere de novo os dados",
// "confere os dados de novo") — 07/11 23h14 o refeito saiu sem os botões.
const RESUMO_RE = /confere\b[^\n]{0,15}\bdados/;
// P17 (portão 08/11 22h48, cenário a): o cliente mandou o e-mail e o modelo respondeu "Me falta só o e-mail — não recebi
// ele ainda. Pode mandar?". O e-mail já foi registrado acima (pela mensagem) → a frase que o pede de novo sai, e a trava
// do pagamento logo abaixo segue (sem essa frase não há "outra pergunta" segurando).
if (V7 && m.dados.email && /[^\s@<>()]+@[^\s@<>()]+\.[a-z]{2,}/i.test(String((prep.consolidado || {}).mensagem || ''))) {
  const pedeEmail = (p) => /e-?mail/.test(norm(p)) && /nao recebi|me falta|faltou|pode mandar|me manda|me passa|qual (e )?(o )?seu (melhor )?e-?mail/.test(norm(p));
  const antes = baloesFinais.length;
  baloesFinais = baloesFinais.map((b) => b.split('\n\n').filter((p) => !pedeEmail(p)).join('\n\n')).filter((b) => b.trim());
  if (baloesFinais.length !== antes || baloesFinais.join('\n\n') !== texto) texto = baloesFinais.join('\n\n');
}
const ultimaFala = norm(baloesFinais[baloesFinais.length - 1] || '');
const outraPergunta = ultimaFala.includes('?') && !/manha ou (a )?tarde|instalacao, voce prefere/.test(ultimaFala);
if (V7 && !erro && !handoff && !tags.botoes && !m.forma_pagamento && m.plano_escolhido && m.dados.telefone && m.dados.email
  && m.dados.email_confirmado !== false   // 10/11: o e-mail repetido espera o "sim" antes do pagamento
  && !outraPergunta && !baloesFinais.some((b) => RESUMO_RE.test(norm(b)))) {
  baloesFinais = baloesFinais.map((b) => b.split('\n\n').filter((p) => !/manha ou (a )?tarde|instalacao, voce prefere/.test(norm(p))).join('\n\n')).filter((b) => b.trim());
  tags.botoes = 'pagamento';
  texto = baloesFinais.join('\n\n');
}
// 07/11 (cenário (a) instável na bateria: "forma de pagamento sem os botões"): plano escolhido, sem forma de pagamento e a
// Mari PERGUNTOU a forma em texto, sem a marca → os botões de pagamento entram (a pergunta escrita sai logo abaixo).
// Pergunta de pagamento = frase com "como quer pagar"/"forma de pagamento", ou pergunta com 2 das 3 formas
// ("cartão ou boleto?"). Uma forma só ("…R$125 no cartão). Quer?", o upsell) não conta.
const ehPerguntaPag = (f) => {
  const x = norm(f);
  return /quer pagar|forma de pagamento|como (voce )?(prefere|quer|vai) pagar|prefere pagar/.test(x)
    || (x.includes('?') && ['cartao', 'boleto', 'debito'].filter((k) => x.includes(k)).length >= 2);
};
const frases = (b) => b.split(/\n\n|(?<=[.!?])\s+/);
if (V7 && !erro && !handoff && !tags.botoes && !m.forma_pagamento && m.plano_escolhido && baloesFinais.length
  && !tags.upsell_oferecido && !/por mais r\$/.test(norm(texto))
  && !baloesFinais.some((b) => RESUMO_RE.test(norm(b))) && frases(baloesFinais[baloesFinais.length - 1]).some(ehPerguntaPag)) {
  tags.botoes = 'pagamento';
}
// P17 (portão 08/11 22h48, cenário a): depois do CPF a Mari pediu o e-mail, o cliente respondeu outra coisa ("o telefone é
// esse mesmo") e ela pulou para a forma de pagamento — o e-mail ficou para trás. Ordem do Passo 4: sem e-mail, a forma de
// pagamento (pergunta ou botões) não sai; no lugar, o pedido do e-mail.
if (V7 && !erro && !handoff && !m.forma_pagamento && !m.dados.email && cpfOk(m.dados.cpf) && m.plano_escolhido
  && (tags.botoes === 'pagamento' || baloesFinais.some((b) => frases(b).some(ehPerguntaPag)))) {
  tags.botoes = null;
  baloesFinais = baloesFinais.map((b) => b.split('\n\n')
    .filter((p) => !frases(p).some(ehPerguntaPag) && !/desconto|^de: r\$|^por: r\$|💳/.test(norm(p)) && !/💳/.test(p)).join('\n\n'))
    .filter((b) => b.trim());
  baloesFinais.push('Antes da forma de pagamento, me passa seu melhor e-mail?');
  texto = baloesFinais.join('\n\n');
}
// Resumo de conferência sempre com os botões, mesmo se o modelo esquecer a marca (bateria 06/11).
if (V7 && !erro && !tags.botoes && baloesFinais.length && RESUMO_RE.test(norm(baloesFinais[baloesFinais.length - 1]))
  && /cpf:/.test(norm(baloesFinais[baloesFinais.length - 1]))) tags.botoes = 'resumo';
if (V7 && !erro && tags.botoes) {
  const chave = norm(tags.botoes).replace(/[^a-z_]/g, '');
  // Pagamento: a pergunta vem no corpo do sistema — a que o modelo escreveu sai (senão aparece duas vezes).
  if (chave === 'pagamento') {
    // Só a FRASE da pergunta sai (a reação "Show, anotado o e-mail." fica).
    baloesFinais = baloesFinais.map((b) => b.split('\n\n').map((p) => p.split(/(?<=[.!?])\s+/).filter((f) => !ehPerguntaPag(f)).join(' ').trim())
      .filter(Boolean).join('\n\n')).filter((b) => b.trim());
  }
  const BOT = {
    sim_nao: [{ id: 'sim', title: 'Sim' }, { id: 'nao', title: 'Não' }],
    resumo: [{ id: 'resumo:ok', title: 'Sim, está certo' }, { id: 'resumo:corrigir', title: 'Corrigir' }],
    pagamento: [{ id: 'pg:cartao', title: 'Cartão de crédito' }, { id: 'pg:boleto', title: 'Boleto bancário' }, { id: 'pg:debito', title: 'Débito automático' }],
  }[chave];
  if (BOT) {
    let corpo = '';
    if (chave === 'pagamento') {
      const cod = upd.plano_escolhido || (c.plano_escolhido || null);
      const pl = (ctx.planos || []).find((p) => p.codigo === cod);
      corpo = pl && !ctx.btu && pl.preco_cartao != null && txts.pagamento_corpo
        ? txts.pagamento_corpo.replace('{de}', moeda(pl.preco)).replace('{por}', moeda(pl.preco_cartao))
        : (txts.pagamento_corpo_sem_desconto || 'Como você quer pagar?');
    } else if (baloesFinais.length) {
      corpo = baloesFinais[baloesFinais.length - 1];     // a pergunta vira o corpo da mensagem com botões
      baloesFinais = baloesFinais.slice(0, -1);
    }
    if (corpo) interativo = { tipo: 'botoes', chave, corpo: corpo.slice(0, 1024), botoes: BOT,
      resumo: `botões: ${BOT.map((x) => x.title).join(' / ')}`, fallbackTexto: corpo };
  }
}
// O histórico (mari_turnos) guarda o que o cliente viu: texto + corpo interativo + resumo legível.
// Janela pós-handoff (0061, Ricardo 07/11 23h30): a venda já está com o nosso time. A Mari responde e só — nada de botões,
// de novo handoff (a venda já existe) ou de mudar a conversa (etapa, dados). Pedido de mudança de dado o backoffice lê aqui.
if (posHandoff) {
  // O corpo que ia nos botões volta a ser balão de texto (senão o cliente fica sem resposta).
  if (interativo && interativo.tipo === 'botoes' && interativo.chave !== 'pagamento' && interativo.corpo) baloesFinais = [...baloesFinais, interativo.corpo];
  interativo = null;
  delete tags.botoes; delete tags.carrossel; delete tags.handoff;
  handoff = null;
  Object.keys(upd).forEach((k) => { delete upd[k]; });
  texto = baloesFinais.join('\n\n');
}
// Despedida repetida (teste real 08/11 00h20): "Entendi!" e "Minha filha receberá o técnico" chegaram com 6 s de diferença
// (a 2ª, 0,13 s depois da checagem do 7b) e saíram duas despedidas quase iguais ("Qualquer coisa é só me chamar aqui" /
// "Qualquer dúvida, é só chamar por aqui"). Se a última fala da Mari já se despediu assim, a frase não se repete. Na janela
// pós-handoff, se não sobrar nada, a Mari fica calada (um humano não responde "Entendi!" com outra despedida).
let silencioIntencional = false;
const FECHO = /qualquer (coisa|duvida)[^.!?\n]{0,40}\b(chamar|chama|falar|fala)\b/;
const histC = Array.isArray((prep.consolidado || {}).historico) ? prep.consolidado.historico : [];
const ultimaMari = [...histC].reverse().find((h) => h && h.papel === 'mari');
if (!erro && !handoff && !interativo && ultimaMari && FECHO.test(norm(ultimaMari.texto)) && baloesFinais.some((b) => FECHO.test(norm(b)))) {
  const sem = baloesFinais.map((b) => b.split('\n\n').map((p) => {
    const fr = p.split(/(?<=[.!?])[ \t]+/);
    return fr.some((f) => FECHO.test(norm(f))) ? fr.filter((f) => !FECHO.test(norm(f))).join(' ').trim() : p;
  }).filter(Boolean).join('\n\n')).filter((b) => b.trim());
  if (sem.length) { baloesFinais = sem; texto = sem.join('\n\n'); }
  else if (posHandoff) { baloesFinais = []; texto = ''; silencioIntencional = true; }
}
if (interativo) texto = [...baloesFinais, interativo.corpo, `[${interativo.resumo}]`].filter(Boolean).join('\n\n');
// Rede de segurança (conversa #5, 07/11): nada para mandar (sem texto, sem interativo, sem handoff) = cliente no vácuo.
// Deixa o rastro em mari_erros com o que o modelo escreveu.
if (!erro && !handoff && !interativo && !silencioIntencional && !String(texto || '').trim()) {
  erro = { no: '7 · Extrair', mensagem: 'resposta_vazia', payload: { bruto: String(bruto || '').slice(0, 300) } };
}

return [{ json: {
  corrigir: false,
  conversaId: ctx.conversaId,
  interativo,
  texto, tags, upd, handoff, erro,
  // Balões: texto final (a despedida de segurança acima pode ter preenchido o texto depois do corte).
  baloes: baloesFinais,
  emojiAjustes: emojiAjustes.length ? emojiAjustes : null,
  modelo: resp.model || motor.model,
  tokensIn, tokensOut,
  // @ensaio-inicio
  uso,
  // @ensaio-fim
  latenciaMs: Date.now() - ctx.t0,
  turnoIds: ctx.turnoIds,
  promptVersao: ctx.promptVersao,
  violacoes: null,
  violacoesCorrigidas,
  // 07/11 (conversa #1): o "digitando" do 1º balão acontece no 7w, ANTES da checagem de mensagem nova (7b/7c) — uma
  // mensagem que chega nesse intervalo agora aborta esta resposta e entra junto na próxima. Rota de teste: sem espera.
  esperaAntes: (() => {
    let modo = null;
    try { modo = ($('2 · Entrada').first().json || {}).modo; } catch (e) { modo = null; }
    if (modo !== 'chatwoot' || !baloesFinais.length) return 0.1;
    return Math.min(6, Math.max(2, Math.round(baloesFinais[0].length / 60)));
  })(),
} }];
