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
// 21/11 (conversas L-222 "Am n entende" e L-40 "Moro acima do bar"): frase do cliente gravada como nome. Nome = só letras,
// de min a 7 palavras, nenhuma delas palavra de frase (negação, verbo, pergunta, lugar, cumprimento). "da/de/dos/e" valem.
const NAO_NOME = new Set(('n nao num nem entendi entende entendo entender entendeu sei sabe quero queria quer tem tenho temos moro '
  + 'pode posso podia qual quais como quando onde porque pq por pra pro para com sem mas ok sim isso eu meu minha voce vc ta to '
  + 'esta estou acho aqui acima abaixo perto lado bar rua apto ap bloco plano internet chip oi ola bom boa dia tarde noite obrigado '
  + 'obrigada valeu blz beleza certo favor o a os as um uma que se ja so mais menos muito agora depois hoje amanha fala falar ver '
  + 'vou vai fica fico quero gostaria preciso tambem nada tudo alguem ninguem '
  // 26/11 (L-272 "Pera ai"): frase de espera e interjeição também não são nome.
  + 'pera perai peraia espera espere esperai calma momento momentinho minuto minutinho instante aguarda aguarde volto '
  + 'ai eita vixe opa hum hmm ue kkk tipo assim entao pronto pressa apressa').split(' '));
function pareceNome(s, min) {
  const t = String(s || '').trim();
  const n = Math.max(1, min || 2) - 1;
  if (!new RegExp(`^[A-Za-zÀ-ÿ']+(?: [A-Za-zÀ-ÿ']+){${n},6}$`).test(t)) return false;
  return !norm(t).split(' ').some((w) => NAO_NOME.has(w));
}

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
  // 12/11: o n8n põe o motivo real (ex.: "credit balance is too low") na descrição; o message é só "Bad request".
  erroApi = String([resp.error?.message, resp.error?.description].filter(Boolean).join(' — ') || resp.message || JSON.stringify(resp).slice(0, 300));
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
  if (/^\s*(pagamento|resumo|sim_nao|data|turno|credito|unidade)\s*$/.test(t)) return m;
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
  // Portão 10/11 08h59 (cenário j): o modelo copiou o bloco de estado ("[ESTADO_INTERNO] etapa: … [/ESTADO_INTERNO]")
  // para a fala. Bloco [X]…[/X] em maiúsculas sai inteiro; marca solta [X] / [/X] numa linha também.
  .replace(/\[([A-Z][A-Z_]{3,})\][\s\S]*?\[\/\1\]/g, '')
  .replace(/^[ \t]*\[\/?(?:ESTADO|INTERNAL|INTERNO|CONTEXTO)[A-Z_ ]*\][ \t]*$/gim, '')
  .replace(new RegExp(`\\[(?:${NOMES_TAG})(?:\\s*:[^\\]]*)?\\]`, 'gi'), '')
  .replace(/^\s*\[?(INTERNAL DATA|ESTADO_ATUAL[^\]]*)\]?.*$/gim, '')
  // 24/11 (L-82, Michele, 16/11 17h17): o motor manda a fala do consultor como "[Mensagem do consultor da equipe, enviada enquanto ele
  // atendia]" e o modelo copiou a marca E as falas do consultor para a resposta. A marca nunca sai; parágrafo igual a uma fala do time sai.
  .replace(/\[Mensagem do consultor[^\]\n]*\]/gi, '')
  .replace(/[ \t]+\n/g, '\n')
  .replace(/\n{3,}/g, '\n\n')
  .trim();
{
  const _nh = (t) => String(t || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9 ]+/g, ' ').replace(/\s+/g, ' ').trim();
  const _hist = Array.isArray((prep.consolidado || {}).historico) ? prep.consolidado.historico : [];
  const _doTime = new Set(_hist.filter((h) => h.papel === 'humano').map((h) => _nh(h.texto)).filter((t) => t.length >= 8));
  if (_doTime.size) texto = texto.split(/\n\s*\n/).filter((p) => !_doTime.has(_nh(p))).join('\n\n').trim();
}

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
  // 23/11 (L-270, Ricardo: "Tirar a linha"): plano com fidelidade não tem mais linha de taxa no quadro — taxa e fidelidade
  // só se o cliente perguntar. A versão sem fidelidade (que o cliente pediu) continua dizendo a taxa na 1ª fatura.
  const linhaTaxa = meses ? null
    : `• Taxa de instalação (${taxaTxt}) cobrada na 1ª fatura (versão sem fidelidade)`;
  const wifi = pl && pl.wifi ? String(pl.wifi).trim() : 'Wi-Fi';
  return [COND_ABRE, '',
    '• Preço fixo até janeiro/2030',
    ...(linhaTaxa ? [linhaTaxa] : []),
    `• Roteador ${wifi} incluído, sem custo`,
    '• 1ª fatura 25 dias depois da instalação (no cartão, no dia da instalação)',
    '', 'A velocidade real depende do aparelho e do Wi-Fi.'].join('\n');
}
// 24/11 (L-82, Michele: "Oiii" → o quadro de condições de novo, 2 vezes): o quadro já saiu nesta conversa e o cliente não perguntou de
// condição, fidelidade, taxa, fatura, roteador ou preço → a marca sai sem o quadro (o resto da fala fica).
{
  const _h = Array.isArray((prep.consolidado || {}).historico) ? prep.consolidado.historico : [];
  const _jaSaiu = _h.some((h) => h.papel === 'mari' && /As condições do seu plano:|Antes de fechar, rapidinho as condições/.test(String(h.texto || '')));
  const _cli = String((prep.consolidado || {}).mensagem || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  if (_jaSaiu && !/condic|fidelid|multa|taxa|instala|fatura|roteador|wi-?fi|mesh|preco|valor|quanto|plano/.test(_cli)) {
    texto = texto.replace(/\[CONDI[CÇ][OÕ]ES\]/gi, '').replace(/(^|\n)[^\n]*condi[cç][oõ]es[^\n]*:[ \t]*(?=\n|$)/gi, '$1').replace(/\n{3,}/g, '\n\n').trim();
  }
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
  ['chip da nio', '"chip da Nio"'], ['5g da nio', '"5G da Nio"'], ['internet 5g nio', '"Internet 5G Nio"'], ['2028', '"2028"'], ['cobertura confirmada', '"cobertura confirmada"'],
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
  // 27/11 (L-437, #269): "Me passa o CEP e o número da casa que eu já vejo o que chega aí pra você" caiu aqui nas duas
  // tentativas e virou "Só um instante…" + handoff. "Ver/mostrar o que chega aí" é intenção de consultar (o roteiro do
  // prompt usa a frase), não promessa — a afirmação ("já vi que chega aí", "a fibra chega aí") continua barrada.
  const VAI_VER = /\b(ver|vejo|vendo|conferir|confiro|consultar|consulto|checar|checo|olhar|olho|saber|mostrar|mostro|falar|falo|dizer|digo) o que (chega|atende|tem|pega)\b/;
  return n.split(/(?<=[.?!\n])/).filter((f) => !f.includes('?') && !VAI_VER.test(f) && !/\b(ver|saber|confirmar|checar|conferir|olhar) se\b|\bse (a nio |a fibra |ela )?(chega|atende)\b/.test(f)).some((f) =>
    // 07/11 23h10: "atende o seu endereço" (sem o "no") passava pela trava.
    /\b(atende|chega|tem cobertura|tem fibra|tem disponibilidade)\s+(a[ií]\b|na sua rua|no seu endereco|(o )?seu endereco|(a )?sua rua|na sua casa|(a )?sua casa|no seu predio|no seu bairro)/.test(f)
    || /\btem cobertura\b|\bcobertura (no|na|pro|pra) (seu|sua)\b|(seu endereco|sua rua|sua casa) (e|esta|ta|fica) (atendid|coberto|coberta)/.test(f)
    || (/\bboa noticia\b/.test(f) && /atende|cobertura|chega|disponivel/.test(f))
    // 24/11 (L-287, #248): "Aqui chega fibra de vcs?" → "Chega sim! … o endereço já deu certinho aqui no nosso sistema"
    // (o portal ainda estava consultando). "Chega sim" em resposta à pergunta da cobertura e "o endereço deu certo" são promessa.
    || (/^\W*(sim\W+)?(chega|atende|tem|pega|passa) sim\b/.test(f.trim())
        && (() => { const c = norm(String((prep.consolidado || {}).mensagem || ''));
          return /cobertura|tem fibra|disponib/.test(c)
            || (/\b(chega|atende|pega|passa)\b/.test(c) && /\b(fibra|aqui|ai|rua|casa|endereco|bairro|predio|internet|nio|vcs|voces)\b/.test(c)); })())
    || /\b(o |seu |teu )?endereco (ja )?(deu|esta|ta|foi|ficou) (certo|certinho|ok|aprovad|confirmad|liberad|viavel|atendid)/.test(f)
    || /\bdeu (certo|certinho|ok)\b.{0,30}\bsistema\b/.test(f));
}
// 24/11 (L-287, #248): o carrossel já tinha saído e, ao "Aqui chega fibra de vcs?", o modelo mandou de novo. O estado dizia
// "planos_mostrados: SIM — repita só se ele pedir ou disser que não viu"; esta é a trava. Mesma regra do 5b (o resumo
// "[carrossel: …]" fica no histórico).
function carrosselRepetido() {
  const hist = Array.isArray((prep.consolidado || {}).historico) ? prep.consolidado.historico : [];
  if (!hist.some((h) => h.papel === 'mari' && /\[carrossel:/i.test(String(h.texto || '')))) return false;
  const cli = norm(String((prep.consolidado || {}).mensagem || ''));
  // Endereço novo (outro CEP ou outra cidade) pode mudar a tabela: aí mandar de novo é certo.
  const cidN = norm(String(tags.cidade_detectada || '')), cidC = norm(String((ctx.conversa || {}).cidade || ''));
  if (/\b\d{5}-?\d{3}\b/.test(cli) || (cidN && cidC && cidN !== cidC)) return false;
  return !/\bplanos?\b|\bopc|\bofertas?\b|\bvalores\b|\bprecos?\b|\bquais\b|\boutr[oa]s?\b|\bmais (op|planos)|nao (vi|recebi|chegou|apareceu|abriu|carregou)|de novo|reenvi|manda(r)? (as|os|de)|\bver\b/.test(cli);
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

// 23/11 (L-270): taxa de instalação só quando o cliente pergunta. Devolve o texto da violação ou null.
function taxaSemPergunta(t) {
  const semBloco = String(t || '').replace(/As condições do seu plano:[\s\S]*?A velocidade real depende do aparelho e do Wi-Fi\./g, ' ');
  const n = norm(semBloco);
  const cli = norm(String((prep.consolidado || {}).mensagem || ''));
  const perguntouFid = /fidelid|multa|cancel|sair antes|sai antes|desist|permanen|contrato|compromisso|carencia|quebr|tempo minimo|prazo minimo|ficar preso|obrigad/.test(cli);
  // 24/11 (L-287, Ricardo: "todos os planos possuem fidelidade de 12 meses, com multa de 540, que a Nio chama de taxa de
  // instalação"; "Sem o valor"): perguntou de fidelidade → a Mari diz que TEM fidelidade (meses do plano) e o proporcional, sem o
  // R$; o valor só se ele pedir ("quanto?") ou logo depois de ela ter explicado a fidelidade. Nunca "não tem multa/fidelidade".
  const hist = Array.isArray((prep.consolidado || {}).historico) ? prep.consolidado.historico : [];
  const ultMari = [...hist].reverse().find((h) => h.papel === 'mari');
  const falouFid = !!ultMari && /fidelid|proporcional/.test(norm(ultMari.texto));
  if (perguntouFid || falouFid) {
    const temNfid = (ctx.planos || []).some((p) => /nfid/.test(p.variante || '') && p.codigo === (ctx.conversa || {}).plano_escolhido);
    if (!temNfid && /\bnao tem (multa|fidelidade)|\bsem (multa|fidelidade)\b|\bnao (tem|ha) (prazo|carencia)/.test(n.replace(/versao sem fidelidade/g, ' '))) {
      return 'disse que não tem multa ou fidelidade: os planos TÊM fidelidade (os meses de isenção do [INTERNAL DATA]) — se cancelar antes, paga só a parte proporcional da taxa de instalação. O preço fixo até janeiro de 2030 é garantia de preço, não prazo de contrato (Bloco 4, fidelidade)';
    }
    const pediuValor = /quanto|valor|\bpreco\b|\br\$/.test(cli);
    const citaValorF = [...n.matchAll(/r\$\s*(\d+)/g)].some((m) => new Set([540, ...(ctx.planos || []).map((p) => Number(p.taxa_habilitacao)).filter(Boolean)].map((x) => String(Math.round(x)))).has(m[1]));
    if (citaValorF && !pediuValor && !falouFid) {
      return 'deu o valor da taxa de instalação na primeira resposta sobre fidelidade: diga só que tem fidelidade (os meses do plano) e que, cancelando antes, paga a parte proporcional da taxa de instalação — o valor em R$ só se o cliente perguntar quanto (Bloco 4, fidelidade)';
    }
    return null;
  }
  const perguntouInst = /\btaxa|instala|adesao|habilita/.test(cli);
  const taxas = new Set([540, ...(ctx.planos || []).map((p) => Number(p.taxa_habilitacao)).filter(Boolean)].map((x) => String(Math.round(x))));
  const citaValor = [...n.matchAll(/r\$\s*(\d+)/g)].some((m) => taxas.has(m[1]));
  const citaRegra = /\bmulta\b|proporcional|fidelidade|\bisent\w*[^.?!\n]{0,40}\bmeses\b|\bmeses\b[^.?!\n]{0,40}\bisent/.test(n);
  const citaTaxa = /\btaxa\b/.test(n);
  if (!perguntouInst && (citaTaxa || citaValor || citaRegra)) {
    return 'falou de taxa de instalação, multa ou fidelidade sem o cliente perguntar — tire isso: responda só o preço do plano e o que vem incluso (Bloco 4, TAXA DE INSTALAÇÃO)';
  }
  if (perguntouInst && (citaValor || citaRegra)) {
    return 'o cliente perguntou só da instalação: diga "A instalação é isenta 😊", sem valor em R$, sem meses, multa ou fidelidade, e siga a venda (o valor e a regra só se ele perguntar de fidelidade, multa ou de sair antes)';
  }
  return null;
}

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
// Portão 10/11 (cenário p, 2 rodadas seguidas): "por mais R$30 tem o Nio Super, que já vem com 20 GB…" sem dizer que vai
// de 800 Mega pra 1 Giga. O parágrafo do upsell tem de trazer a velocidade — exceto Super → Ultra (mesma velocidade, P16).
function upsellSemVelocidade(t) {
  const paras = norm(t).split(/\n\s*\n/);
  const par = paras.find((p) => /por mais r\$/.test(p));
  if (!par || /\b\d+\s*(mega|giga)\b/.test(par)) return false;
  const codTag = String(tags.plano_escolhido || '').toUpperCase().match(/[VE]-[A-Z0-9]+-[A-Z]+/);
  const cod = (codTag && codTag[0]) || (ctx.conversa || {}).plano_escolhido;
  const ch = (ctx.planos || []).find((p) => p.codigo === cod);
  const nomeCh = norm((ch && ch.nome) || par.slice(0, par.indexOf('por mais r$')));
  return !/\b(super|ultra)\b/.test(nomeCh);
}
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
  // 13/11 (Ricardo; conversa #88, portão P33 e P34): "darei uma nova chance à Leopoldina net" e "esse atendimento eu dispenso,
  // e sim com a Empresa" não estavam na lista — a Mari se despediu sem um argumento.
  concorrente: /\b(vou|irei|prefiro|decidi|resolvi|quero) (ficar|continuar|permanecer|seguir|fechar) (com|na|no) (?!((o|a|os|as) )?(plano|esse|essa|este|esta|ess[ea] mesmo|nio|fibra|essencial|super|ultra|giga|de \d|\d))|\b(nova|outra|mais uma|segunda) chance\b|\b(fechei|fiquei) com (a|o|outra)\b/,
  confianca: /\bdispenso\b|\bnao confio\b|\bnada com voce\b|\b(falar|tratar|resolver) (direto )?com a empresa\b|\b(tenho|fico com|to com|estou com) (medo|receio|o pe atras)\b/,
};
const NAO_QUERO_RE = /\bnao (tenho|tem) interesse\b|\bnao quero\b|\bpode parar\b|\bnao me (mand|cham|lig)\w*\b|\bpara de me\b|\bchega\b|\bvou bloquear\b|\bme (tira|remove) da lista\b|\bsem interesse\b/;
const msgObj = norm((prep.consolidado || {}).mensagem || '');
const objecaoDaMsg = Object.keys(OBJ_RE).find((k) => OBJ_RE[k].test(msgObj)) || null;
const naoQuero = NAO_QUERO_RE.test(msgObj);
// 13/11 (P33/P34): recusa com motivo fora da lista também ganha UMA tentativa — desde que não seja "não quero" explícito
// e a Mari ainda não tenha contornado nada nesta conversa. Chave "outra".
const contornosAntes = Object.values((((ctx.conversa || {}).dados || {}).objecoes) || {}).reduce((a, b) => a + Number(b || 0), 0);
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
  if (V4 && !(V7 && ((ctx.conversa || {}).cobertura_decisao === 'sem_cobertura')) && /nao atende (o seu|seu|esse|aí|ai)|ainda nao chegou|nao chegou (a )?fibra|sem viabilidade|sem cobertura|nao tem (cobertura|fibra)|fibra .{0,20}chegar na sua rua/.test(n)) {
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
  // 24/11 (teste L-288, Ricardo + texto da Nio de 01/10/2026): o 5G tem franquia; o chip se pede pelo App Nio depois da
  // instalação (o técnico não leva); a rede é da TIM (parceria com a Surf), nunca "rede própria".
  if (V7) {
    const frases = n.split(/[.!?\n]+/);
    if (frases.some((f) => /\b(chip|5g|celular|linha movel|movel)\b/.test(f) && /\binternet (e (as )?(chamadas|ligacoes) )?ilimitad/.test(f))) {
      v.push('disse que a internet do chip/5G é ilimitada: tem franquia (os GB do [INTERNAL DATA]); ilimitadas são só as ligações e as mensagens');
    }
    if (frases.some((f) => /\bchip\b/.test(f) && /\b(tecnico|instalacao|instalar)\b/.test(f) && /\b(leva|levam|entrega|entregam|traz|trazem|junto|combinad)\w*/.test(f) && !/\bdepois d[ae] instala/.test(f))) {
      v.push('disse que o chip vem na instalação: o técnico NÃO leva o chip — depois da instalação, o cliente pede pelo App Nio (chip físico entregue no endereço ou eSIM) e ativa pelo app');
    }
    if (/\brede propria\b/.test(n)) v.push('disse "rede própria" para o celular: a linha móvel usa a rede da TIM, por uma parceria da Nio com a Surf Telecom (só se o cliente perguntar)');
  }
  // 24/11 (teste L-288: "Me confirma: sua casa tem complemento…" no fim de 13 respostas seguidas): a pergunta pendente
  // volta no máximo 1 vez a cada 3 respostas — se uma das 2 últimas falas da Mari já perguntou, esta não pergunta.
  if (V7) {
    const pergComp = (s) => /\btem complemento\b|complemento[^.!?\n]{0,80}\?/.test(norm(String(s || '')));
    const histC = Array.isArray((prep.consolidado || {}).historico) ? prep.consolidado.historico : [];
    const ultimas = histC.filter((h) => h.papel === 'mari').slice(-2);
    const cliC = norm(String((prep.consolidado || {}).mensagem || ''));
    const falouDoEndereco = /complement|\bapto\b|apartamento|\bbloco\b|\bcasa [a-z0-9]\b|\bnao tem\b|\bnao\b$|\bsim\b|\bloja\b/.test(cliC);
    if (pergComp(n) && ultimas.length && ultimas.some((h) => pergComp(h.texto)) && !falouDoEndereco) {
      v.push('repetiu a pergunta do complemento — você já perguntou numa das 2 últimas respostas: responda só o que o cliente perguntou, sem pedir o complemento de novo agora (ele volta depois, com outras palavras)');
    }
  }
  if (V7 && tags.carrossel && carrosselRepetido()) v.push('mandou o carrossel de novo sem o cliente pedir — ele já recebeu os planos: responda só ao que ele perguntou, sem [CARROSSEL_PLANOS] e sem "olha as opções", e termine com uma pergunta leve sobre qual plano ele prefere');
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
    if (upsellSemVelocidade(t)) v.push('upsell sem as velocidades: diga os números da tabela ("por mais R$30 o Super vai de 800 Mega pra 1 Giga e já vem com 20 GB de internet 5G e Globoplay por 12 meses")');
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
  } else if (V7 && handoffYaml && !objecaoDaMsg && !naoQuero && !posHandoff && contornosAntes === 0 && msgObj.replace(/[^a-z]/g, '').length >= 3
    && ['recusa_compra', 'interesse_caindo'].includes(norm(handoffYaml.motivo_handoff || '').replace(/[^a-z_]/g, ''))) {
    v.push('aceitou o primeiro "não" do cliente sem nenhum argumento — ele não disse "não quero" nem pediu para parar: tire o [HANDOFF], valide em meia frase, responda ao motivo que ele deu com UM argumento do Bloco 4b (sem motivo claro: preço fixo até janeiro/2030), termine com uma pergunta leve e emita [OBJECAO: outra]. Se ele recusar de novo, aí sim despedida recusa_compra');
  }
  // 23/11 (L-270, Ricardo: "falar nisso espanta o cliente"): a Mari não puxa a taxa de instalação. Fora do bloco de
  // condições, taxa/multa/proporcional/fidelidade só se o cliente perguntou de fidelidade, multa ou de sair antes; se ele
  // perguntou só da instalação, vale "a instalação é isenta", sem valor nem meses.
  if (V7) {
    const vTaxa = taxaSemPergunta(t);
    if (vTaxa) v.push(vTaxa);
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
  // 12/11 (portão, cenário a): 2ª tentativa ainda com violação só num parágrafo (ex.: upsell sem as velocidades) → manda o
  // resto, sem o parágrafo, e a Mari segue; o texto de emergência (com handoff) fica para quando nada se salva.
  let resgatado = null;
  if (v.length) {
    const ps = String(texto || '').split('\n\n');
    const bons = ps.filter((p) => !violacoesDe(p).length);
    const cand = bons.join('\n\n').trim();
    if (bons.length < ps.length && cand && !violacoesDe(cand).length) resgatado = cand;
  }
  if (v.length && resgatado) {
    // Sem "erro" (ele desliga as travas de botões deste turno): o rastro fica na tag do turno (a auditoria lê).
    tags.filtro_resgate = `parágrafo retirado: ${v.join('; ')}`.slice(0, 300);
    texto = resgatado;
  } else if (v.length) {
    erro = { no: '7r · Extrair (correção)', mensagem: `filtro de saída: ${v.join('; ')}`, payload: { texto_bloqueado: texto, prompt: ctx.promptVersao } };
    texto = 'Só um instante, vou confirmar essa informação com nosso time e já te respondo 😊';
    // 12/11 (achado 4 da auditoria — Cristiano, 10/11 22h45): esta frase promete o time, mas sem [HANDOFF] ninguém era
    // chamado — o cliente esperou até a cadência do dia seguinte. Agora a promessa vira handoff pedido_humano de verdade
    // (na janela pós-handoff o bloco de lá zera o handoff: a venda já está com o time).
    if (!handoffYaml) {
      handoffYaml = {
        motivo_handoff: 'pedido_humano',
        briefing_humano: `A Mari travou no filtro de saída (${v.join('; ').slice(0, 220)}) e disse ao cliente que o time confirma e já responde. `
          + `Responder a última mensagem dele: «${String((prep.consolidado || {}).mensagem || '').slice(0, 200)}».`,
      };
      tags.handoff = handoffYaml;
    }
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
// 12/11 (Ricardo; portão P27): o operador decidiu SEM COBERTURA (portal sem viabilidade + DFV sem fachada no CEP) → a Mari
// avisa, registra o interesse e encerra (handoff sem_cobertura) — determinístico: o modelo tendia a seguir para os planos.
// 13/11 (0167, Ricardo; conversa #86, portão P30): a Mari convidou a mandar o CEP certo e o cliente voltou (mari_entrada reabriu
// a conversa e marcou dados.sem_cobertura_avisado = hora do veredito). Endereço novo neste turno → segue o fluxo (a consulta
// sai de novo); mesmo endereço → vai a fala do modelo (pede o CEP/número certo), sem repetir o aviso, e a conversa volta a sair.
const scC = ctx.conversa || {};
const scAv = (scC.dados || {}).sem_cobertura_avisado;
const scVoltou = V7 && scC.cobertura_decisao === 'sem_cobertura' && scAv != null && !!scC.cobertura_em
  && Number(scAv) === Math.floor(new Date(scC.cobertura_em).getTime() / 1000);
const scE = tags.endereco ? kv(tags.endereco) : {};
const scDig = (x) => String(x || '').replace(/\D/g, '');
const scNum = (x) => String(x || '').trim().toUpperCase();
const scMudou = scVoltou && ((scDig(d.cep).length === 8 && scDig(d.cep) !== scDig(scC.cep))
  || (scDig(scE.cep).length === 8 && scDig(scE.cep) !== scDig(scC.cep))
  || (!!scE.numero && scE.numero !== '—' && !/^(null|nenhum)$/i.test(scE.numero) && scNum(scE.numero) !== scNum(scC.numero)));
const scNega = (t) => /nao chega|ainda nao chegou|nao atende|sem cobertura|nao tem (cobertura|fibra)/.test(norm(t || ''));
if (scVoltou && !posHandoff && !erro) {
  delete tags.carrossel; delete tags.botoes;
  if (scMudou) {
    if (!String(texto || '').trim() || scNega(texto)) texto = 'Deixa comigo, vou conferir esse endereço e já te falo 😊';
    if (handoffYaml && norm(handoffYaml.motivo_handoff || '').replace(/[^a-z_]/g, '') === 'sem_cobertura') { handoffYaml = null; delete tags.handoff; }
  } else {
    if (!String(texto || '').trim() || scNega(texto)) texto = 'Sem problema! Qual é o CEP (são 8 números) e o número da casa certos? Eu confiro de novo pra você.';
    handoffYaml = { motivo_handoff: 'sem_cobertura',
      briefing_humano: 'O cliente voltou a escrever depois do aviso de sem cobertura e não mandou um endereço diferente; a Mari respondeu (pediu o CEP e o número certos). '
        + 'Se ele mandar outro CEP/número, a Mari consulta de novo sozinha (até 3 voltas). Sem cobertura pelo operador (portal sem viabilidade e DFV sem fachada viável no CEP).' };
    tags.handoff = handoffYaml;
  }
}
if (V7 && !scVoltou && !posHandoff && !erro && (ctx.conversa || {}).cobertura_decisao === 'sem_cobertura'
  && !(handoffYaml && norm(handoffYaml.motivo_handoff || '').replace(/[^a-z_]/g, '') === 'sem_cobertura')) {
  const nd = ((ctx.conversa || {}).dados || {}).nome;
  const pn = String((pareceNome(nd, 1) && nd) || (ctx.conversa || {}).nome_contato || '').trim().split(/\s+/)[0];
  texto = `Poxa${pn && (ctx.conversa || {}).nome_confiavel !== false ? `, ${pn}` : ''}, infelizmente a fibra da Nio ainda não chega no seu endereço 😕\n\n`
    + 'Deixei seu interesse registrado e te aviso por aqui assim que a rede chegar aí. Se o número ou o CEP estiver diferente do que você me passou, me manda que eu confiro de novo.';
  handoffYaml = { motivo_handoff: 'sem_cobertura',
    briefing_humano: 'Sem cobertura pelo operador (portal sem viabilidade e DFV sem fachada viável no CEP). A Mari avisou e registrou o interesse. Se o cliente mandar outro número/CEP, consultar na Cobertura.' };
  tags.handoff = handoffYaml;
  delete tags.carrossel; delete tags.botoes;
}
// 0138: a análise de crédito da Nio NEGOU (consulta autorizada) → a Mari avisa e chama o time (determinístico).
{
  const cc = ctx.conversa || {};
  // 15/11 (Ricardo, caso Lucas 17:31): com o lead já em Saída (o time tratou e encerrou), o roteiro NÃO roda — a Mari responde pelo
  // modelo, sabendo da Saída (motor: "situacao_lead"). Antes ela oferecia de novo o CPF de um parente depois do time ter testado 2.
  const naSaida = !!cc.funil_destino && !['em_andamento', 'instalada'].includes(cc.funil_destino);
  if (V7 && !posHandoff && !erro && !handoffYaml && !naSaida && cc.credito_resultado === 'negado' && !((cc.dados || {}).credito_negado_avisado)) {
    const pn = String(((cc.dados || {}).nome) || '').trim().split(/\s+/)[0];
    if (Number(cc.credito_consultas || 0) < 2) {
      // 12/11 ~10h (Ricardo): avisa com gentileza e oferece o CPF de um parente/familiar como titular.
      // 15/11 (Ricardo, caso Grace): o pedido no CPF de outra pessoa tem passos do portal que o robô não conhece (biometria antes da
      // OS, "Salvar Interesse") → a Mari avisa e PASSA PARA O BKO, que faz a consulta e o pedido à mão. Sem 2ª consulta automática.
      texto = `Poxa${pn ? `, ${pn}` : ''}, a análise de crédito da Nio não aprovou o pedido neste CPF 😕\n\n`
        + 'Mas dá pra fazer no CPF de um parente ou familiar — ele fica como titular do pedido e é ele quem faz a biometria (o link chega no celular e no e-mail que ficarem no pedido). '
        + 'Pode já me mandar o nome completo, o CPF e o parentesco dele: vou passar pro nosso time, que segue com você por aqui.';
      handoffYaml = { motivo_handoff: 'pedido_humano',
        briefing_humano: 'Crédito NEGADO no CPF do cliente. A Mari ofereceu um parente como titular e pediu nome completo, CPF e parentesco.' };
      tags.handoff = handoffYaml;
      delete tags.carrossel; delete tags.botoes;
    } else {
      texto = `Poxa${pn ? `, ${pn}` : ''}, a análise da Nio também não aprovou neste CPF 😕\n\n`
        + 'Vou te passar pro nosso time, que vê com você as outras opções.';
      handoffYaml = { motivo_handoff: 'pedido_humano',
        briefing_humano: 'Crédito NEGADO nas 2 consultas automáticas (titular e parente). A Mari avisou. Ver outras opções com o cliente.' };
      tags.handoff = handoffYaml; delete tags.carrossel; delete tags.botoes;
    }
    dados.credito_negado_avisado = true;
  }
  // 0327 (Ricardo, 19/11: "a notícia, seja qual for, deve ser automática"): o NIOGEN já avisou o cliente do negado na hora em que
  // o portal respondeu (bo_credito_negado, oferecendo um parente como titular) e marcou credito_negado_avisado + credito_negado_sistema.
  // O bloco acima não roda de novo; aqui, na 1ª fala do cliente depois do aviso, a Mari passa ao time (o pedido no CPF de outra pessoa
  // é do BKO — 15/11, caso Grace) sem repetir o aviso. Uma vez só (credito_negado_passado).
  const ddN = cc.dados || {};
  if (V7 && !posHandoff && !erro && !handoffYaml && !naSaida && cc.credito_resultado === 'negado' && ddN.credito_negado_sistema
    && !ddN.credito_negado_passado && !dados.credito_negado_passado && Number(cc.credito_consultas || 0) < 2) {
    texto = 'Combinado! Já passei pro nosso time, que segue com você por aqui pra fazer o pedido no CPF do novo titular 😊';
    handoffYaml = { motivo_handoff: 'pedido_humano',
      briefing_humano: 'Crédito NEGADO no CPF do cliente. O NIOGEN avisou na hora e ofereceu um parente como titular; o cliente respondeu (ver a conversa: nome, CPF e parentesco do novo titular).' };
    tags.handoff = handoffYaml;
    delete tags.carrossel; delete tags.botoes;
    dados.credito_negado_passado = true;
  }
}
// 0212 (15/11, caso Helton): "Negado - Critérios Antifraude" — a Nio vê Nio no endereço. NUNCA oferecer outro CPF (num endereço
// com Nio isso é o que a Nio lê como fraude/recompra). A Mari avisa sem falar em fraude e passa para o BKO, que confere com o cliente
// se a Nio é dele ou de outro morador (defesa na Nio). Determinístico, uma vez só.
{
  const cc = ctx.conversa || {};
  const naSaidaAf = !!cc.funil_destino && !['em_andamento', 'instalada'].includes(cc.funil_destino);   // 15/11: idem
  if (V7 && !posHandoff && !erro && !handoffYaml && !naSaidaAf && cc.credito_resultado === 'negado_antifraude' && !((cc.dados || {}).credito_antifraude_avisado)) {
    const pn = String(((cc.dados || {}).nome) || '').trim().split(/\s+/)[0];
    texto = `${pn ? `${pn}, ` : ''}a Nio pediu uma conferência do seu endereço antes de seguir com o pedido 🔎

`
      + 'Vou passar pro nosso time, que confere com você por aqui. Uma pergunta já adianta: a internet Nio que aparece nesse endereço é sua (ou de alguém da casa) ou de um morador que já se mudou?';
    handoffYaml = { motivo_handoff: 'pedido_humano',
      briefing_humano: 'Crédito NEGADO por "Critérios Antifraude" (a Nio vê Nio no endereço). NÃO consultar outro CPF. A Mari perguntou se a Nio é do cliente/da casa ou de outro morador. Ficha › Crédito › Antifraude.' };
    tags.handoff = handoffYaml; delete tags.carrossel; delete tags.botoes;
    dados.credito_antifraude_avisado = true;
  }
}
// 0380 (24/11, L-70 — Ricardo: "Vamos deixar a Mari seguir o atendimento normal, sem negar a venda e conduz ao humano,
// para que ele entre no mérito e tente conduzir de forma mais natural"): o portal negou por "CPF/CNPJ com débito na Nio". A Mari NÃO
// fala de crédito nem de débito: na próxima fala do cliente, passa ao consultor como num passo normal da venda. O time recebe a nota
// do banco (ver o valor da negociação no portal, oferecer quitar hoje, consultar de novo). Determinístico, uma vez só.
{
  const cc = ctx.conversa || {};
  const naSaidaDb = !!cc.funil_destino && !['em_andamento', 'instalada'].includes(cc.funil_destino);
  if (V7 && !posHandoff && !erro && !handoffYaml && !naSaidaDb && cc.credito_resultado === 'negado_debito' && !((cc.dados || {}).credito_debito_passado)) {
    const pn = String(((cc.dados || {}).nome) || '').trim().split(/\s+/)[0];
    const prazoD = ctx.dentroHorario ? 'já te chama por aqui' : 'te chama por aqui no próximo horário de atendimento';
    texto = `Perfeito${pn ? `, ${pn}` : ''}! 😊\n\nPra seguir com o seu pedido, vou te passar pro nosso consultor, que ${prazoD} e finaliza com você.`;
    handoffYaml = { motivo_handoff: 'pedido_humano',
      briefing_humano: 'Crédito NEGADO por "CPF/CNPJ com débito na Nio" (fatura antiga em aberto). O cliente NÃO sabe do negado: a Mari só disse que o consultor segue o pedido. Ver no portal o valor da negociação (a Nio dá desconto), oferecer quitar hoje e consultar o crédito de novo; não quis → outra pessoa da casa como titular.' };
    tags.handoff = handoffYaml; delete tags.carrossel; delete tags.botoes;
    dados.credito_debito_passado = true;
  }
}
// 23/11 (L-259, P48 — Ricardo: "Sim, corrigir"): o cliente NÃO SABE o CEP e a rua que ele escreveu não foi achada pelo nome.
// A Mari pediu o CEP 3 vezes, disse que "só com o nome da rua não consigo" e seguiu para nome, CPF, e-mail e pagamento sem
// endereço, sem cobertura e sem plano — e o time recebeu "VENDA PRONTA". Agora ela passa NA HORA ao consultor, que localiza o
// endereço (Google/Correios), grava na ficha e segue a venda. Determinístico; a fala do modelo é trocada.
{
  const cc = ctx.conversa || {};
  const ddS = cc.dados || {};
  if (prep.ruaNaoAchada) dados.rua_nao_achada = String(prep.ruaNaoAchada).slice(0, 120);
  const ruaNA = prep.ruaNaoAchada || ddS.rua_nao_achada || null;
  const naSaidaS = !!cc.funil_destino && !['em_andamento', 'instalada'].includes(cc.funil_destino);
  if (V7 && !posHandoff && !erro && !handoffYaml && !naSaidaS && !cc.cep && !prep.p_cep && prep.naoSabeCep && ruaNA
    && !prep.opcoesRua && !prep.ruaPedeNumero && !prep.ruaSemCidade) {
    const pn = cc.nome_confiavel ? String(cc.nome_contato || '').trim().split(/\s+/)[0] : '';
    const prazoS = ctx.dentroHorario ? 'em até 2 horas' : 'no próximo horário de atendimento';
    const cidS = cc.cidade || ddS.planos_cidade || '';
    texto = `Sem problema${pn ? `, ${pn}` : ''}! 😊\n\n`
      + `Vou pedir pro nosso consultor localizar o seu endereço por aqui, e ele te chama ${prazoS} pra seguir com você.`;
    handoffYaml = { motivo_handoff: 'pedido_humano',
      briefing_humano: `RESUMO: Cliente não sabe o CEP e a rua «${String(ruaNA).slice(0, 80)}»${cidS ? ` (${cidS})` : ''} não foi achada pelo nome. `
        + 'SUGESTÃO: Achar o CEP da rua (Google ou Correios), gravar na ficha, consultar a cobertura e seguir a venda com o cliente.' };
    tags.handoff = handoffYaml; delete tags.carrossel; delete tags.botoes;
  }
}
// 25/11 (L-377, P54 — Ricardo: "A Mari deveria imediatamente ter falado que acionaria um atendente para tentar encaixar a
// instalação dele pra hoje e entrado como prioridade 1 na fila da Live. É oportunidade de venda"): com o plano já escolhido, o
// cliente perguntou "Teria para hoje?" e a Mari respondeu "pra hoje não vai rolar"; ele disse "Então pode deixar obg" e ela
// repetiu a pergunta do período duas vezes. Agora, com o plano escolhido: PRESSA na instalação (hoje, agora, o quanto antes,
// urgente) ou AMEAÇA DE DESISTIR (pode deixar, deixa pra lá, esquece, não quero mais) → a Mari aciona o atendente NA HORA
// (handoff urgencia_alta, que a Live 2.0 põe em 1º — 0401). Determinístico: a fala do modelo é trocada. "Tentar encaixar" não é
// promessa de data. Textos trocáveis sem deploy em config_mari_textos (risco_pressa_fala, risco_desiste_fala; {nome} e {prazo}).
let riscoVenda = null;
{
  const cc = ctx.conversa || {};
  const naSaidaR = !!cc.funil_destino && !['em_andamento', 'instalada'].includes(cc.funil_destino);
  const msgR = norm(String((prep.consolidado || {}).mensagem || '')).replace(/\s+/g, ' ').trim();
  // "hoje/agora/antes" só contam na hora de marcar a instalação (forma de pagamento já escolhida) ou se a fala cita a instalação:
  // "hoje mesmo te mando o CPF" não é pressa. Urgência dita com todas as letras vale em qualquer ponto depois do plano.
  const naInstalacao = !!cc.forma_pagamento || /\binstal|\btecnico\b|\bagend/.test(msgR);
  const HOJE_RE = /\b(pra|para|pro|p) hoje\b|\bhoje (mesmo|ainda)\b|\bainda hoje\b|\b(tem|teria|da|daria|dava|consegue|conseguem|conseguiria|rola|instala|instalam|instalar|instalacao|pode ser|podia ser) (como )?(pra |para |pro )?(ser )?(pra |para |pro )?(hoje|agora|ja)\b|\b(nao )?(tem|teria|da|daria) (pra |para )?(antes|mais cedo)\b/;
  const URG_RE = /\bquanto antes\b|\bmais rapido possivel\b|\burgent|\burgencia\b|\b(tenho|to com|estou com|com muita) pressa\b/;
  const PRESSA_RE = { test: (s) => URG_RE.test(s) || (naInstalacao && HOJE_RE.test(s)) };
  const DESISTE_RE = /\bpode deixar\b(?! (de|pra|para|pro|no|na|nesse|nessa|que|como|assim|a|o|as|os|esse|essa|qualquer|tanto|marcad\w*|agendad\w*)\b)|\bdeixa (pra la|para la|quieto|isso pra la)\b|\besquece\b|\bdesist\w+\b|\bnao (quero|vou querer|preciso) mais\b|\bentao nao (quero|vou querer|precisa|da)\b|\b(assim|desse jeito) nao (da|quero|serve|vou querer)\b|\bfica pra (proxima|outra hora|depois)\b|\bvou (ver|procurar|fechar com) outr[ao]\b/;
  const motivoModelo = handoffYaml ? norm(handoffYaml.motivo_handoff || '').replace(/[^a-z_]/g, '') : null;
  if (V7 && !posHandoff && !erro && !naSaidaR && cc.plano_escolhido && msgR && msgR.length <= 200
    && !['dados_completos', 'fora_de_area', 'sem_cobertura', 'ja_cliente_nio'].includes(motivoModelo || '')) {
    // a ameaça de desistir só vale na hora de marcar a instalação; antes disso é objeção (Bloco 4b) e o "não quero" é respeitado
    riscoVenda = PRESSA_RE.test(msgR) ? 'pressa' : (cc.forma_pagamento && DESISTE_RE.test(msgR) ? 'desiste' : null);
  }
  if (riscoVenda) {
    const txR = (ctx.inter || {}).textos || {};
    const p1 = String(((cc.dados || {}).nome) || '').trim().split(/\s+/)[0];
    const nm = p1 && /^[A-Za-zÀ-ÿ']{2,20}$/.test(p1) ? p1.charAt(0).toUpperCase() + p1.slice(1).toLowerCase() : '';
    const prazoR = ctx.dentroHorario ? 'Ele já te chama aqui mesmo' : 'Ele te chama aqui mesmo no próximo horário de atendimento';
    const quando = ctx.dentroHorario ? 'pra hoje' : 'pro quanto antes';
    const padrao = riscoVenda === 'pressa'
      ? `Entendi{nome}! Vou acionar agora um atendente do nosso time pra tentar encaixar a sua instalação ${quando}.\n\n{prazo} 😊`
      : 'Calma{nome}, não quero que você fique sem a sua internet por causa da data 😊\n\nVou acionar agora um atendente do nosso time pra ver com você o melhor dia e horário da instalação. {prazo}.';
    const modelo = String(txR[riscoVenda === 'pressa' ? 'risco_pressa_fala' : 'risco_desiste_fala'] || '').trim() || padrao;
    texto = modelo.replace('{nome}', nm ? `, ${nm}` : '').replace('{prazo}', prazoR);
    const falaCli = String((prep.consolidado || {}).mensagem || '').replace(/\s+/g, ' ').trim().slice(0, 120);
    handoffYaml = { motivo_handoff: 'urgencia_alta',
      briefing_humano: riscoVenda === 'pressa'
        ? `RESUMO: VENDA EM RISCO — o cliente quer a instalação para já («${falaCli}»). A Mari disse que um atendente vai tentar encaixar. SUGESTÃO: Assumir AGORA, seguir o pedido no portal e tentar a data mais próxima na agenda da Nio.`
        : `RESUMO: VENDA EM RISCO — o cliente falou em desistir na hora de marcar a instalação («${falaCli}»). A Mari disse que um atendente vai ver o melhor dia e horário. SUGESTÃO: Assumir AGORA, entender o que não serviu na data e combinar outra.` };
    tags.handoff = handoffYaml; tags.sinal_urgencia = tags.sinal_urgencia || (riscoVenda === 'pressa' ? 'quer instalar já' : 'falou em desistir');
    delete tags.carrossel; delete tags.botoes;
    dados.risco_venda = riscoVenda;
  }
}
const hy = handoffYaml || {};
const nome = d.nome || hy.nome;
const cpf = (d.cpf || hy.cpf || '').replace(/\D/g, '');
let tel = (d.telefone || hy.telefone || '').replace(/\D/g, '');
if (/^55\d{10,11}$/.test(tel)) tel = tel.slice(2);
const email = (d.email || hy.email || '').trim();
if (nome && nome !== '—' && pareceNome(nome, 1)) { dados.nome = nome; upd.nome_confiavel = true; }
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
const pedAb = String(d.pedido_aberto || '').trim();   // 12/11 (0133): o que o cliente disse sobre o pedido Nio em andamento
if (V7 && pedAb && pedAb !== '—' && !/^null$/i.test(pedAb)) dados.pedido_aberto_resposta = pedAb.slice(0, 200);
// Portão P28: a Mari perguntou do pedido em andamento e o modelo não anotou a resposta → a mensagem do cliente é a resposta.
if (V7 && !dados.pedido_aberto_resposta && ['sim', 'endereco'].includes((ctx.conversa || {}).nio_pedido_aberto) && !(((ctx.conversa || {}).dados || {}).pedido_aberto_resposta)) {
  const hist = Array.isArray((prep.consolidado || {}).historico) ? prep.consolidado.historico : [];
  const ultMari = [...hist].reverse().find((h) => h.papel === 'mari');
  const msgCli = String((prep.consolidado || {}).mensagem || '').trim();
  if (ultMari && /pedido[^.?!]{0,60}(andamento|aberto)/.test(norm(ultMari.texto)) && msgCli) dados.pedido_aberto_resposta = msgCli.slice(0, 200);
}
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
  const OBJS = ['preco', 'ja_tem', 'marca', 'sem_5g', 'pensar', 'consultar_alguem', 'concorrente', 'confianca', 'outra'];
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
if (inst && inst !== '—' && !/^null$/i.test(inst)) {
  // 12/11 (Ricardo): a data vem dos botões D+1/D+2/D+3 (dados.instalacao_data); o modelo emite só o período → junta os dois.
  const dtEsc = (c.dados || {}).instalacao_data;
  upd.instalacao_preferencia = V7 && dtEsc && !/\d{1,2}\/\d{1,2}/.test(inst) ? `${dtEsc}, ${inst}` : inst;           // v4+
}
// 21/11 (conversas L-236 e L-217): o período que o cliente respondeu fica gravado pelo próprio código — antes só valia a marca do
// modelo, e quando ele se ocupava de outra coisa (a lista de unidades que chegou, o pedido do nome) o sistema perguntava de novo.
// "Manhã"/"Tarde" valem com a data já escolhida ou logo depois da pergunta do período; "Tanto faz", só depois da pergunta do período.
if (V7 && !upd.instalacao_preferencia && !c.instalacao_preferencia) {
  const histP = Array.isArray((prep.consolidado || {}).historico) ? prep.consolidado.historico : [];
  const ultP = [...histP].reverse().find((h) => h.papel === 'mari');
  const pergPer = !!ultP && /qual (turno|periodo)|periodo voce prefere|botoes: manha \/ tarde/.test(norm(ultP.texto));
  const linhas = String((prep.consolidado || {}).mensagem || '').split(/\n+/).map((l) => norm(l).replace(/[^a-z ]/g, ' ').replace(/\s+/g, ' ').trim());
  const dtMsg = String((prep.consolidado || {}).mensagem || '').split(/\n+/).map((l) => l.trim())
    .find((l) => /^(dom|seg|ter|qua|qui|sex|s[aá]b)[a-zçá-]*,?\s*\d{1,2}\/\d{1,2}$/i.test(l));
  const dtP = (c.dados || {}).instalacao_data || dtMsg;
  let per = null;
  for (const l of linhas) {
    const mm = l.match(/^(?:(?:de|pela|a|na|no|periodo da|parte da|turno da)\s+)?(manha|tarde)(?:\s+(?:mesmo|por favor|pfv|pf|obrigad[oa]))*$/);
    if (mm && (dtP || pergPer)) per = mm[1] === 'manha' ? 'manhã' : 'tarde';
    else if (pergPer && /^(tanto faz|qualquer( um| uma| periodo| horario| turno)?|qualquer um dos dois|os dois|tanto faz o periodo)$/.test(l)) per = 'tanto faz';
  }
  if (per) upd.instalacao_preferencia = dtP && dtP !== 'qualquer data' ? `${dtP}, ${per}` : per;
}

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
// 16/11 (0233, Ricardo; caso "CS 1" × "Casa A"): unidade a confirmar. O cliente tocou/escreveu uma unidade da lista da Nio →
// é ela (o operador consulta de novo com a unidade dele). "Nenhuma dessas" (botão, texto ou [ENDERECO: unidade=nenhuma]) →
// dados.unidade_fora_lista = 'nenhuma' (o gatilho da 0233 manda o time pedir o cadastro à Nio). Nunca escolhe pelo cliente.
const UNIDADES = (() => {
  const det = c.cobertura_detalhe || {};
  if (!V7 || !det.unidade_a_confirmar || !Array.isArray(det.unidades) || !c.unidade_conferir_em
    || (c.unidade_conferir || {}).motivo !== 'escolher') return [];
  const lista = det.unidades.map((u) => (typeof u === 'string' ? u : (u && (u.texto || u.nome)) || '')).filter(Boolean);
  // 21/11 (L-222): a unidade que o cliente já deu está na lista → nada a escolher.
  const k = (x) => norm(x).replace(/[^a-z0-9]/g, '');
  if (k(c.complemento) && lista.some((u) => k(u) === k(c.complemento))) return [];
  return lista;
})();
if (UNIDADES.length && !posHandoff) {
  const msgU = String((prep.consolidado || {}).mensagem || '').trim();
  const kU = (x) => norm(x).replace(/[^a-z0-9]/g, '');
  const escolhida = UNIDADES.find((u) => kU(u) === kU(msgU));
  const eU = tags.endereco ? kv(tags.endereco) : {};
  if (escolhida && upd.complemento === undefined) { upd.complemento = escolhida; dados.complemento_ok = true; }
  else if (/^(nenhuma|nenhum|nao e nenhuma)( dessas| delas| desses| deles)?$/.test(norm(msgU).replace(/[^a-z ]/g, '').trim())
    || /^nenhum/.test(norm(eU.unidade || ''))) dados.unidade_fora_lista = 'nenhuma';
}

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

// 21/11 (Ricardo; conversa L-222, #202): a sugestão do plano de cima saía junto com "me manda seu nome completo e CPF" — o
// cliente não tinha como dizer se aceitava, ficou perdido ("Am n entende") e a explicação seguinte pediu o CPF de novo.
// Agora a sugestão termina na pergunta "fica ou troca" (botões) e os dados só vêm depois da resposta. Enquanto ela não vem,
// nenhuma fala pede nome/CPF; na 3ª fala sem resposta (ou se o cliente manda o CPF) vale "fica".
const famPlano = (p) => String((p && p.nome) || '').replace(/\s*\(.*?\)\s*/g, ' ').replace(/^Nio (Empresas )?/, '').replace(/\s+\d.*$/, '').trim();
function planoAcima(cod) {
  const p = (ctx.planos || []).find((x) => x.codigo === cod);
  if (!p) return null;
  const acima = (ctx.planos || []).filter((o) => o.portfolio === p.portfolio && o.variante === p.variante && Number(o.preco) > Number(p.preco)
    && Number(o.preco) - Number(p.preco) <= 40).sort((a, b) => Number(a.preco) - Number(b.preco))[0];
  return acima ? { atual: p, acima, nAtual: famPlano(p), nAcima: famPlano(acima) } : null;
}
const UPS_DADOS = c.dados || {};
const upsPendente = V7 && !posHandoff && !!c.upsell_oferecido && !UPS_DADOS.upsell_resposta && !cpfOk(UPS_DADOS.cpf) && !!c.plano_escolhido;
let upsResposta = null;
if (upsPendente) {
  const par = planoAcima(c.plano_escolhido);
  const msgU = norm((prep.consolidado || {}).mensagem).trim();
  const fam = (p) => norm(famPlano(p));
  const cpfMsg = (msgU.match(/(?<!\d)(\d{3})\.?(\d{3})\.?(\d{3})-?(\d{2})(?!\d)/) || []).slice(1).join('');
  if (upd.plano_escolhido && upd.plano_escolhido !== c.plano_escolhido) upsResposta = 'troca';
  else if (par && (/^up:troca$/.test(msgU) || new RegExp(`\\b(quero|prefiro|vou de|manda|pode ser)\\b[^?]{0,15}\\b${fam(par.acima)}\\b`).test(msgU))) {
    upsResposta = 'troca'; upd.plano_escolhido = par.acima.codigo;
  } else if (/^up:fica$/.test(msgU) || (par && new RegExp(`\\b(fico|fica|mantenho|continuo|quero|prefiro|pode ser|vou de)\\b[^?]{0,15}\\b${fam(par.atual)}\\b`).test(msgU))
    || /^(esse mesmo|este mesmo|so esse|fico com esse|pode ser esse|nao,? obrigad[oa]|nao precisa|t[aá] bom assim)\b/.test(msgU)
    || (cpfMsg && cpfOk(cpfMsg))) upsResposta = 'fica';
  else if (Number(UPS_DADOS.upsell_perguntas || 0) >= 2) upsResposta = 'fica';
  if (upsResposta) dados.upsell_resposta = upsResposta;
}

if (/seus dados sao usados/.test(norm(texto))) upd.lgpd_enviada = true;
if (tags.upsell_oferecido || /so pra voce saber: por mais/.test(norm(texto))) upd.upsell_oferecido = true;

const ag = tags.agendamento_retorno || null;
// 21/11 (caso L-199, 0348): a data sem horário também vale (09:00) — o banco marca a espera com ela no C3.
const agm = ag && ag.match(/(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}:\d{2}))?/);
if (agm) upd.agendamento_retorno = `${agm[1]}T${agm[2] || '09:00'}:00-03:00`;
// Rede de segurança (L-199: "temos até dia 18/12 para tomar decisões" e a Mari não emitiu a tag): no C3 (múltiplos decisores /
// interesse caindo), se o cliente escreveu um DD/MM futuro nesta fala, é essa a data de retorno.
{
  const mC3 = handoffYaml && ['multiplos_decisores', 'interesse_caindo'].includes(norm(hy.motivo_handoff || '').replace(/[^a-z_]/g, ''));
  const msgC = String((prep.consolidado || {}).mensagem || '');
  const dm = !upd.agendamento_retorno && mC3 && msgC.match(/\b([0-3]?\d)\s*\/\s*([01]?\d)(?:\s*\/\s*(\d{2,4}))?\b/);
  if (dm) {
    const hojeSP = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date());
    const [ah] = hojeSP.split('-').map(Number);
    const d = Number(dm[1]); const mes = Number(dm[2]);
    let ano = dm[3] ? Number(dm[3].length === 2 ? `20${dm[3]}` : dm[3]) : ah;
    const iso = (a) => `${a}-${String(mes).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
    if (d >= 1 && d <= 31 && mes >= 1 && mes <= 12) {
      if (!dm[3] && iso(ano) <= hojeSP) ano += 1;
      if (iso(ano) > hojeSP) { upd.agendamento_retorno = `${iso(ano)}T09:00:00-03:00`; tags.retorno_da_fala = iso(ano); }
    }
  }
}

// 0138 (regra 5 revista, 12/11): resposta à pergunta da autorização do crédito → grava quando e com qual frase (dados → gatilho
// 0139 copia para as colunas que o n8n mari_credito lê).
{
  const cc = ctx.conversa || {};
  const histA = Array.isArray((prep.consolidado || {}).historico) ? prep.consolidado.historico : [];
  const ultMA = [...histA].reverse().find((h) => h.papel === 'mari');
  const pediuAut = ultMA && /autoriza/.test(norm(ultMA.texto)) && /credito/.test(norm(ultMA.texto));
  const msgOrig = String((prep.consolidado || {}).mensagem || '').trim();
  const msgA = norm(msgOrig);
  if (V7 && !posHandoff && pediuAut && !cc.credito_autorizado_em && !cc.credito_recusado_em && msgA) {
    if (/^n(ao)?\b|nao autorizo|prefiro nao|nao quero/.test(msgA)) dados.credito_recusado_em = new Date().toISOString();
    else if (/^(sim|s|pode|claro|ok|okay|autorizo|com certeza|beleza|blz|tudo bem)\b|\bautorizo\b|pode consultar/.test(msgA)) {
      dados.credito_autorizado_em = new Date().toISOString();
      dados.credito_autorizacao_frase = msgOrig.slice(0, 200);
    }
  }
}
if (Object.keys(dados).length) upd.dados = dados;

// ── etapa (determinística, a partir do estado + atualizações) ──
const m = { ...c, ...upd, dados: { ...(c.dados || {}), ...dados } };
// 18/11 (Ricardo: "Remove da Mari a pergunta de qual operadora… Está travando venda"): a operadora não é mais perguntada.
// Endereço completo e dentro da área → elegibilidade ok sem depender da tag do modelo; a etapa nunca para em "elegibilidade".
if (V7 && !m.elegibilidade && m.cep && m.numero && (m.complemento || m.dados.complemento_ok) && ctx.dentroArea !== false) {
  upd.elegibilidade = 'ok';
  m.elegibilidade = 'ok';
}
// 21/11: função içada — o upsell pendente (acima) usa antes desta linha.
function cpfOk(v) { const x = String(v || '').replace(/\D/g, ''); if (x.length !== 11 || /^(\d)\1{10}$/.test(x)) return false; const dv = (k) => { let s = 0; for (let i = 0; i < k; i++) s += Number(x[i]) * (k + 1 - i); const r = (s * 10) % 11; return r === 10 ? 0 : r; }; return dv(9) === Number(x[9]) && dv(10) === Number(x[10]); }
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
  // 17/11 (Ricardo): cliente que já é Nio, em qualquer situação, é encerrado com os canais oficiais — somos revenda.
  // (Antes, v7/A10: ja_cliente_nio virava pedido_humano.)
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
let faltaDespedida = [];   // 23/11 (L-259): o que falta numa venda "dados_completos" (cobertura, plano) — muda a despedida
if (motivo) {
  const notaDfv = {
    viavel: 'DFV viável',
    viavel_predio: 'DFV viável (prédio) — conferir a unidade',
    endereco_ocupado: 'DFV indica Nio ativo no endereço — confirmar com o cliente e no portal antes de abrir o pedido',
  }[c.dfv_resultado] || (c.cidade && norm(c.cidade) === 'juiz de fora' ? 'DFV: conferir manualmente antes de abrir o pedido' : 'DFV: sem base para a cidade — conferir manualmente');
  // 15/11 (Ricardo: "o handoff deve ser objetivo e orientar em poucas linhas o resumo e a orientação para o BKO"):
  // nota curta — título · viabilidade · crédito (o que a Mari já consultou, com o resultado) · 👉 Fazer agora (calculado
  // aqui, não pelo modelo) · ⚠️ alertas · Resumo (1–2 frases da Mari). O "1º PASSO: consultar viabilidade" saiu: a Mari já
  // consulta sozinha. A MESMA tabela do "Fazer agora" está em docs/assets/ficha.js (handoffFazer) e no SQL do crédito que
  // chega depois (0206) — mudou uma, muda as três.
  let topo = [];
  let resumoMari = String(hy.briefing_humano || '').trim();
  if (V7) {
    const dd = { ...(c.dados || {}), ...dados };
    const cepF = String(c.cep || '').replace(/\D/g, '').replace(/^(\d{5})(\d{3})$/, '$1-$2') || '?';
    const comp = upd.complemento !== undefined ? upd.complemento : c.complemento;
    const ender = `CEP ${cepF} · nº ${upd.numero || c.numero || '?'}${comp ? ` · ${comp}` : ''}`;
    // briefing do modelo: RESUMO / SUGESTÃO / ATENÇÃO (o antigo "NÃO FAZER" fica de fora).
    const bh = resumoMari.replace(/\s+/g, ' ');
    const ROT = '(?:RESUMO|SUGEST[ÃA]O|N[ÃA]O FAZER|ATEN[ÇC][ÃA]O)';
    const parte = (rot) => { const m = bh.match(new RegExp(`${rot}\\s*:\\s*(.*?)(?=\\s*${ROT}\\s*:|$)`, 'i')); return m ? m[1].trim() : ''; };
    const temRot = new RegExp(`${ROT}\\s*:`, 'i').test(bh);
    const resumo = (temRot ? parte('RESUMO') : bh).slice(0, 300);
    const sugestao = temRot ? parte('SUGEST[ÃA]O').slice(0, 220) : '';
    const atencaoMari = temRot ? parte('ATEN[ÇC][ÃA]O').slice(0, 220) : '';
    resumoMari = resumo;

    // viabilidade (operador: portal decide, DFV resgata — 0133)
    const dec = c.cobertura_decisao || ({ viavel: 'viavel', sem_viabilidade: 'sem_cobertura', nao_encontrado: 'unidade_fora_lista' }[c.nio_viab_resultado]) || null;
    const vel = c.nio_viab_velocidade ? ` até ${c.nio_viab_velocidade}` : '';
    const VIAB = {
      viavel: `✅ Viabilidade: VIÁVEL${vel} (portal) — ${ender}`,
      elegivel_200m: `⚠️ Viabilidade: só pelos 200 m (portal sem viabilidade, DFV com fachada viável) — ${ender}`,
      unidade_fora_lista: `⚠️ Viabilidade: unidade fora da lista do portal — ${ender}`,
      sem_cobertura: `❌ Viabilidade: SEM cobertura (portal e DFV) — ${ender}`,
      indefinida: `❔ Viabilidade: o portal não decidiu — ${ender}`,
    };
    const viabLinha = VIAB[dec] || `❔ Viabilidade: não consultada — ${ender}`;

    // crédito (0138/0141/0205: automático, só com o endereço do cliente e depois de viável)
    const FORMA = { BOLETO: 'boleto', CREDITO: 'cartão', DACC: 'débito em conta' };
    const formasCod = (Array.isArray(c.credito_formas) ? c.credito_formas : []).map((f) => String(f).toUpperCase());
    const formas = formasCod.map((f) => FORMA[f] || f.toLowerCase());
    const cr = c.credito_resultado || null;
    const nCons = Number(c.credito_consultas || 0);
    const padrao = c.credito_endereco === 'padrao' && /^aprovado/.test(cr || '');
    const CRED = {
      aprovado_todas: 'APROVADO — todas as formas', aprovado_parcial: `APROVADO — ${formas.join(', ') || 'formas: ?'}`,
      aprovado_cartao: 'APROVADO SÓ NO CARTÃO', pendente: 'PENDENTE (a Nio responde em até 24 h)',
      negado: nCons >= 2 ? 'NEGADO nos 2 CPFs (titular e parente)' : 'NEGADO neste CPF',
      negado_debito: 'NEGADO — CPF COM DÉBITO NA NIO (o cliente não sabe)', negado_antifraude: 'NEGADO — CRITÉRIOS ANTIFRAUDE',
      pedido_em_andamento: 'já existe PEDIDO NIO EM ANDAMENTO no CPF', nao_decidiu: 'o portal não decidiu',
    };
    const cpfOk = String(dd.cpf || '').replace(/\D/g, '').length === 11;
    const mailOk = /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(dd.email || '')) && String(dd.email_confirmado || '') !== 'false';
    const falta = [!cpfOk ? 'CPF' : null, !mailOk ? 'e-mail confirmado' : null].filter(Boolean);
    let credLinha;
    if (cr) credLinha = `💳 Crédito: ${CRED[cr] || cr}${nCons >= 2 && cr !== 'negado' ? ' (2ª consulta — CPF do parente)' : ''}${padrao ? ' · ⚠ lido no endereço PADRÃO, não no do cliente' : ''}`;
    else if (c.credito_em) credLinha = '💳 Crédito: consulta automática em andamento — o resultado chega como nota';
    else if (dec !== 'viavel') credLinha = '💳 Crédito: não consultado (a Mari só consulta depois de viável)';
    else credLinha = `💳 Crédito: não consultado${falta.length ? ` — faltou ${falta.join(' e ')}` : ''}`;

    // 👉 Fazer agora — uma linha: a primeira trava que vale
    const fp = upd.forma_pagamento || c.forma_pagamento || null;
    const fpCod = { boleto: 'BOLETO', cartao: 'CREDITO', debito: 'DACC' }[fp] || null;
    const fpTxt = { boleto: 'boleto', cartao: 'cartão', debito: 'débito em conta' }[fp] || null;
    const venda = motivo === 'dados_completos';
    const pl = (ctx.planos || []).find((p) => p.codigo === (upd.plano_escolhido || c.plano_escolhido)) || null;
    let fazer;
    if (c.nio_pedido_aberto === 'endereco' || cr === 'pedido_endereco') fazer = 'NÃO abrir outro pedido: já existe pedido Nio em andamento NO ENDEREÇO (vale até para outro CPF). Perguntar ao cliente de quem é; não for cancelar → Saída › Já tem pedido Nio no endereço.';   // 0383
    else if (c.nio_pedido_aberto === 'sim' || cr === 'pedido_em_andamento') fazer = 'NÃO abrir outro pedido: conferir no portal o pedido que já existe no CPF (recompra = multa R$ 500).';
    else if (dec === 'sem_cobertura') fazer = 'Conferir o CEP e o número com o cliente; se estiverem certos, encerrar pela Saída (sem cobertura).';
    else if (dec === 'elegivel_200m') fazer = 'Na Cobertura: conferir os 200 m no mapa e pedir a liberação ANTES de abrir o pedido.';
    else if (dec === 'unidade_fora_lista') fazer = 'Na Cobertura: escolher a unidade certa ou pedir o cadastro pelo formulário.';
    else if (cr === 'negado_antifraude') fazer = 'Antifraude (a Nio vê Nio no endereço): NÃO consultar outro CPF. Confirmar com o cliente se a Nio é dele/da casa (→ Já é cliente Nio) ou de outro morador (→ defesa na Nio); gravar em ficha › Crédito.';
    else if (cr === 'negado_debito') fazer = 'Débito na Nio: NÃO consultar outro CPF de cara. Ver no portal o valor da negociação (a Nio dá desconto) e oferecer quitar hoje; pagou → consultar o crédito de novo (ficha › Crédito) e fazer o pedido. Não quis → outra pessoa da casa como titular.';
    else if (cr === 'negado' && nCons < 2) fazer = 'Titular parente: consultar o crédito do CPF do parente; no portal, celular e e-mail DO TITULAR (a biometria vai para ele) → Continuar → Salvar Interesse; na ficha ⋯ › Trocar o titular e Gravar o Interesse. A Live avisa quando a biometria aprovar.';
    else if (!venda) fazer = (sugestao ? sugestao.charAt(0).toUpperCase() + sugestao.slice(1) : '') || {
      pedido_humano: 'Responder o cliente agora e entender o que ele precisa.',
      objecao: 'Responder a objeção com o que o plano entrega — o preço é o da tabela, sem desconto.',
      urgencia_alta: 'Responder o cliente agora.',
      multiplos_decisores: 'Combinar com o cliente quando falar com quem decide.',
    }[motivo] || 'Responder o cliente e seguir a venda.';
    else if (dec !== 'viavel') fazer = 'Consultar a viabilidade na ficha (Cobertura) antes de tudo.';
    else if (padrao) fazer = 'Consultar o crédito de novo no endereço do cliente (ficha › Crédito) antes de abrir o pedido.';
    else if (!cr && c.credito_em) fazer = 'Aguardar o resultado do crédito (chega como nota) e então abrir o pedido.';
    else if (!cr || cr === 'nao_decidiu') fazer = `Consultar o crédito na ficha (Crédito)${falta.length ? ` — antes, pedir ao cliente o ${falta.join(' e o ')}` : ''}.`;
    else if (cr === 'pendente') fazer = 'Aguardar a resposta da Nio (até 24 h) e avisar o cliente; não abrir o pedido antes.';
    else if (cr === 'negado') fazer = nCons >= 2 ? 'Ver com o cliente outra pessoa da casa como titular; sem saída, encerrar pela Saída.'
      : 'Titular parente: consultar o crédito do CPF do parente, pedido no portal com o contato DO TITULAR, Salvar Interesse; na ficha ⋯ › Trocar o titular.';
    else if (cr === 'aprovado_cartao' && fp !== 'cartao') fazer = 'Só o cartão foi liberado: confirmar se o cliente paga no cartão; se não, outra pessoa da casa como titular.';
    else if (cr === 'aprovado_parcial' && fpCod && !formasCod.includes(fpCod))
      fazer = `A forma escolhida (${fpTxt}) não foi liberada: combinar com o cliente uma das liberadas (${formas.join(', ')}).`;
    // 23/11 (L-259): sem plano escolhido não se abre pedido — a mesma trava está em docs/assets/ficha.js (handoffLinhas).
    else if (!pl) fazer = 'Combinar o plano com o cliente e gravar na ficha antes de abrir o pedido.';
    else fazer = `Abrir o pedido no portal${fpTxt ? ` no ${fpTxt}` : ''} e avisar o cliente do link da biometria que a Nio manda.`;

    // alertas: só os que mudam o que o BKO faz
    const alertas = [];
    const falasCliente = norm([(prep.consolidado || {}).mensagem, ...(Array.isArray((prep.consolidado || {}).historico) ? prep.consolidado.historico : [])
      .filter((h) => h.papel === 'lead').map((h) => h.texto)].join(' \n '));
    // 12/11 (Edvaldo, Andriene): sem cartão → crédito antes da biometria; só cartão → outra pessoa da casa titular.
    if (/\bn(ao|um)\b[^.?!\n]{0,25}\b(tenho|uso|possuo|tem)\b[^.?!\n]{0,25}\bcart(ao|oes)\b|\bsem cart(ao|oes)\b/.test(falasCliente)) alertas.push('cliente disse que não tem/não usa cartão');
    if (['sim', 'endereco'].includes(c.nio_pedido_aberto) && dd.pedido_aberto_resposta) alertas.push(`sobre o pedido aberto, o cliente disse «${String(dd.pedido_aberto_resposta).slice(0, 120)}»`);
    if (dd.pista_nio) alertas.push(`cliente citou Nio/Oi (${String(dd.pista_nio).slice(0, 80)}) — conferir posse no portal`);
    if (dd.rua_informada && dd.rua_confirmada && norm(dd.rua_informada) !== norm(dd.rua_confirmada)) alertas.push(`rua: escreveu «${dd.rua_informada}», confirmou «${dd.rua_confirmada}»`);
    // 23/11 (L-259): "VENDA PRONTA" só com cobertura viável E plano escolhido. Sem um dos dois, o título diz o que falta.
    const faltaVenda = venda ? [dec !== 'viavel' ? 'cobertura' : null, !pl ? 'plano' : null].filter(Boolean) : [];
    if (venda && !pl && !/^Combinar o plano/.test(fazer)) alertas.unshift('sem plano escolhido');
    faltaDespedida = faltaVenda;
    if (venda && !dd.referencia) alertas.push('sem ponto de referência — pedir ao cliente');
    if (tags.sinal_urgencia) alertas.push(`urgência: ${String(tags.sinal_urgencia).slice(0, 80)}`);
    if (atencaoMari) alertas.push(atencaoMari);

    // título
    const nomeT = String(dd.nome || c.nome_contato || '').trim().split(/\s+/).slice(0, 2).join(' ');
    const NOMEM = { pedido_humano: 'PEDIU ATENDIMENTO', objecao: 'OBJEÇÃO', urgencia_alta: 'URGENTE', recusa_compra: 'RECUSOU',
      fora_de_area: 'FORA DA ÁREA', sem_cobertura: 'SEM COBERTURA', interesse_caindo: 'ESFRIANDO', multiplos_decisores: 'OUTRO DECIDE', ja_cliente_nio: 'JÁ É CLIENTE NIO' };
    const titulo = venda && faltaVenda.length
      ? `🟡 DADOS COLETADOS${nomeT ? ` · ${nomeT}` : ''} · falta ${faltaVenda.join(' e ')}`
      : venda
      ? `🟢 VENDA PRONTA${nomeT ? ` · ${nomeT}` : ''}${pl ? ` · ${pl.nome}` : ''}${fpTxt ? ` · ${fpTxt}` : ''}`
      : `${['pedido_humano', 'objecao', 'urgencia_alta'].includes(motivo) ? '🟡' : '⚪'} ${NOMEM[motivo] || 'HANDOFF'}${nomeT ? ` · ${nomeT}` : ''}`;
    topo = [titulo, viabLinha, credLinha, `👉 Fazer agora: ${fazer}`, alertas.length ? `⚠️ ${alertas.slice(0, 3).join(' · ')}` : null].filter(Boolean);
  }
  const briefing = V7
    ? [...topo, resumoMari ? `Resumo: ${resumoMari}` : null].filter(Boolean).join('\n')
    : [hy.briefing_humano, hy.resumo_perfil ? `Perfil: ${hy.resumo_perfil}` : null,
      tags.sinal_urgencia ? `Urgência: ${tags.sinal_urgencia}` : null, notaDfv].filter(Boolean).join('\n');
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
      fora_de_area: 'Por enquanto a gente atende só algumas das cidades onde a Nio tem fibra 😕 Obrigada pelo contato!',   // 26/11: área nacional, sem "Minas"
      ja_cliente_nio: 'Entendi! Como você já é cliente Nio, quem te atende é a própria Nio — pelo App Nio ou no 0800 001 1000 eles resolvem bem mais rápido. Nós somos uma revenda e só cuidamos de contratação nova, tá? Obrigada pelo contato 😊',
    }[motivo] || `Vou te passar pra um dos nossos consultores, que te chama aqui mesmo ${prazo} 😊`;
  }
}

// 23/11 (L-259): dados completos sem cobertura viável ou sem plano = a despedida não promete pedido nem biometria. Texto fixo.
if (V7 && handoff && motivo === 'dados_completos' && faltaDespedida.length) {
  const dd = { ...(c.dados || {}), ...dados };
  const p1 = String(dd.nome || '').trim().split(/\s+/)[0];
  const nm = p1 && /^[A-Za-zÀ-ÿ']{2,20}$/.test(p1) ? p1.charAt(0).toUpperCase() + p1.slice(1).toLowerCase() : null;
  const prazoF = ctx.dentroHorario ? 'em até 2 horas' : 'no próximo horário de atendimento';
  const oQue = faltaDespedida.map((f) => (f === 'cobertura' ? 'a cobertura no seu endereço' : 'o plano')).join(' e ');
  texto = `Pronto${nm ? `, ${nm}` : ''}, anotei tudo por aqui!\n\nAntes de abrir o seu pedido, o nosso consultor confirma com você ${oQue}. Ele te chama aqui mesmo ${prazoF}.`;
  baloes = [texto];
}
// 10/11 (Ricardo, 09/11 23h46): fora da área = comunica, agradece e despede, num balão só — nada de televendas, "anotei",
// "vou passar pra Nio" ou "te aviso quando chegar". Texto fixo (não depende do modelo).
if (V7 && handoff && motivo === 'fora_de_area') {
  const dd = { ...(c.dados || {}), ...dados };
  const p1 = String(dd.nome || '').trim().split(/\s+/)[0];
  const nm = p1 && /^[A-Za-zÀ-ÿ']{2,20}$/.test(p1) ? p1.charAt(0).toUpperCase() + p1.slice(1).toLowerCase() : null;
  const cid = String(c.cidade || '').trim();
  texto = `Poxa${nm ? `, ${nm}` : ''}, por enquanto a gente atende só algumas das cidades onde a Nio tem fibra${cid ? `, e ${cid} ainda não está entre elas` : ''} 😕 Obrigada pelo contato!`;
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
} else if (VER >= 5 && handoff && motivo !== 'fora_de_area' && baloesFinais.length && !baloesFinais[0].startsWith(CORACAO)) {
  // fora_de_area (rodada única 10/11): texto literal da Parte 2, já com 😕 — sem o 💚 na frente.
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
// 24/11 (L-82, Michele): em conversa longa o histórico do motor não alcança o quadro de 12 dias atrás e ele saía de novo num "Oiii".
// Lead que já tem venda já viu as condições: o quadro só volta se o cliente pedir (marca [CONDICOES], com a trava acima).
if (V7 && !erro && !handoff && !ctx.condicoesEnviadas && !condicoesInseridas && !c.venda_id
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
    // confirmação + sugestão num balão só (máx. 3 balões): [confirmação e sugestão] · [condições] · [pergunta fica/troca]
    // 21/11 (L-222): o pedido de nome/CPF NÃO vai aqui — a pergunta "fica ou troca" entra mais abaixo (upsell sem resposta).
    baloesFinais = [fica.join('\n\n'), blocoCondicoes(), jaTemNomeCpf ? (vai.join('\n\n') || null) : null].filter(Boolean);
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
// 12/11 (portão, cenário k — 3 vezes em 4 rodadas): em cidade com carrossel o modelo escreveu a lista "1) Nio Fibra… R$" em
// texto, sem a marca. A lista sai e vira o carrossel (mesmos números do banco, com as imagens e os botões).
if (V7 && !erro && !posHandoff && !tags.carrossel && ctx.carrossel && !(upd.plano_escolhido || (ctx.conversa || {}).plano_escolhido)) {
  const paras = baloesFinais.join('\n\n').split('\n\n');
  const ehItem = (p) => /^\s*\d\)\s[^\n]*R\$\s*\d/.test(p);
  if (paras.filter(ehItem).length >= 2) {
    const iPrim = paras.findIndex(ehItem);
    baloesFinais = paras.slice(0, iPrim).filter((p) => p.trim());   // fica a abertura ("A Nio atende… Olha as opções:")
    texto = baloesFinais.join('\n\n');
    tags.carrossel = true;
  }
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
    if (!pareceNome(m.dados.nome, 1) && pareceNome(antes)) { dados.nome = antes; m.dados.nome = antes; upd.nome_confiavel = true; }
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
  // 21/11 (L-40): "…ativa hoje, no seu nome?" não é pedido de nome — só "nome completo" ou "qual/me diz… seu nome". E a
  // resposta tem de parecer nome (L-222: "Am n entende" virou o nome e a Mari passou a chamar a cliente de "Am").
  const pediuNome = /nome completo|\b(qual|me (diz|fala|passa|manda|conta)|preciso)\b[^?.!]{0,20}\bseu nome\b/.test(norm(ultMari));
  // 26/11 (L-272, P55): "Pera ai" respondeu ao pedido de nome e virou o nome. O atalho agora só aceita nome completo de verdade
  // (pelo menos 2 palavras com 3+ letras, sem contar "dos/das"; "Edson J dos Santos" vale) e entra PROVISÓRIO (dados.nome_provisorio):
  // o 5b manda a Mari confirmar de passagem; com o CPF válido na conversa, deixa de ser provisório. Nome curto de verdade
  // ("Rui Sá") continua entrando pela tag do modelo ou junto do CPF.
  const nomeSolto = (s) => pareceNome(s) && String(s).trim().split(/\s+/)
    .filter((w) => w.replace(/'/g, '').length >= 3 && !/^(dos|das|del|van|von)$/i.test(w)).length >= 2;
  if (V7 && !pareceNome(m.dados.nome, 1) && pediuNome && nomeSolto(msgC)) {
    const prov = !cpfOk(m.dados.cpf);
    dados.nome = msgC; m.dados.nome = msgC; upd.dados = { ...(upd.dados || {}), nome: msgC, ...(prov ? { nome_provisorio: true } : {}) };
    if (prov) dados.nome_provisorio = true;
  }
  // Nome ruim já gravado (frase de antes desta correção) e nada para pôr no lugar: sai, e a Mari pede de novo.
  if (V7 && m.dados.nome && !pareceNome(m.dados.nome, 1)) {
    dados.nome = null; m.dados.nome = null; upd.dados = { ...(upd.dados || {}), nome: null };
  }
  const telConf = ultMari.match(/confirmando:?\s*\(?(\d{2})\)?\s*(9?\d{4})[\s-]?(\d{4})\s*\?/i);
  if (V7 && !m.dados.telefone && telConf && /^(sim|s|ss|isso|isso mesmo|exato|correto|certo|confirmo|esse mesmo|e esse|e sim|positivo)\b/.test(norm(msgC))) {
    const tc = telConf.slice(1).join('');
    dados.telefone = tc; dados.telefone_confirmado = true; m.dados.telefone = tc;
    upd.dados = { ...(upd.dados || {}), telefone: tc, telefone_confirmado: true };
  }
}
// 21/11 (Ricardo; conversa L-222, #202): upsell sugerido agora, ou sugerido antes e sem resposta → nenhuma fala pede nome/CPF;
// a resposta termina na pergunta "fica ou troca" com os botões. Respondeu (ou vale "fica") → o pedido de nome e CPF vem já.
{
  const temCpf = cpfOk((m.dados || {}).cpf);
  const PED_F = /nome completo|\bcpf\b|seus dados sao usados|^fechou\??$|pode me mandar\??$|me passa\??$/;
  const parU = planoAcima(upd.plano_escolhido || c.plano_escolhido);
  const perguntarUps = V7 && !erro && !handoff && !posHandoff && !temCpf && parU
    && ((upsellAgora && !c.upsell_oferecido) || (upsPendente && !upsResposta));
  if (perguntarUps) {
    const fA = norm(parU.nAtual); const fB = norm(parU.nAcima);
    baloesFinais = baloesFinais.map((b) => b.split('\n\n').map((p) => {
      const x = norm(p);
      if (x.includes('?') && x.includes(fA) && x.includes(fB) && !/por mais r\$/.test(x)) return '';   // a pergunta do modelo: sai (entra a do sistema)
      if (!PED_F.test(x) && !/nome completo|\bcpf\b/.test(x)) return p;
      return p.split(/(?<=[.!?])\s+/).filter((f) => !PED_F.test(norm(f).trim())).join(' ').trim();
    }).filter(Boolean).join('\n\n')).filter((b) => b.trim());
    baloesFinais.push(`Fica no ${parU.nAtual} ou prefere o ${parU.nAcima}?`);
    tags.botoes = 'upsell';
    texto = baloesFinais.join('\n\n');
    dados.upsell_perguntas = Number(UPS_DADOS.upsell_perguntas || 0) + 1;
    upd.dados = { ...(upd.dados || {}), upsell_perguntas: dados.upsell_perguntas };
  } else if (V7 && !erro && !handoff && !posHandoff && upsResposta && !temCpf
    && !baloesFinais.some((b) => /nome completo|\bcpf\b/.test(norm(b)))) {
    const lg = c.lgpd_enviada || upd.lgpd_enviada ? null : 'Seus dados são usados só pro seu pedido com a Nio.';
    baloesFinais.push(['Me manda seu nome completo e CPF que eu já adianto aqui.', lg].filter(Boolean).join('\n\n'));
    if (lg) upd.lgpd_enviada = true;
    texto = baloesFinais.join('\n\n');
  }
  if (upsResposta) upd.dados = { ...(upd.dados || {}), upsell_resposta: upsResposta };
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
// 0138: antes da forma de pagamento, a autorização do crédito (botões). Sem ela, segue o pagamento como antes.
{
  const cc = ctx.conversa || {};
  const autorizou = cc.credito_autorizado_em || dados.credito_autorizado_em;
  const recusou = cc.credito_recusado_em || dados.credito_recusado_em;
  const perguntaPag = tags.botoes === 'pagamento' || baloesFinais.some((b) => frases(b).some(ehPerguntaPag));
  // 12/11 ~10h (Ricardo): "nem o WhatsApp oficial da Nio pede autorização" — o crédito roda sozinho (0141); a pergunta saiu.
  const PEDIR_AUTORIZACAO = false;
  if (PEDIR_AUTORIZACAO && V7 && !posHandoff && !erro && !handoff && !m.forma_pagamento && !autorizou && !recusou && perguntaPag
    && cpfOk(m.dados.cpf) && m.dados.email && m.dados.email_confirmado !== false) {
    baloesFinais = baloesFinais.map((b) => b.split('\n\n').map((p) => p.split(/(?<=[.!?])\s+/).filter((f) => !ehPerguntaPag(f)).join(' ').trim())
      .filter((p) => p && !/desconto|^de: r\$|^por: r\$/.test(norm(p)) && !/💳/.test(p)).join('\n\n')).filter((b) => b.trim());
    texto = baloesFinais.join('\n\n');
    tags.botoes = 'credito';
  }
}
// 0138: crédito aprovado SÓ NO CARTÃO e o cliente não está no cartão → avisa uma vez (cartão ou outro titular da casa).
{
  const cc = ctx.conversa || {};
  const fp = upd.forma_pagamento || m.forma_pagamento;
  if (V7 && !posHandoff && !erro && !handoff && cc.credito_resultado === 'aprovado_cartao' && fp !== 'cartao'
    && !((cc.dados || {}).credito_cartao_avisado) && !dados.credito_cartao_avisado) {
    baloesFinais = ['Uma informação importante: a análise de crédito da Nio liberou o seu pedido só no cartão de crédito. '
      + 'Se preferir, seguimos no cartão — e, se você não usa cartão, outra pessoa da casa pode ser a titular do pedido.', ...baloesFinais];
    texto = baloesFinais.join('\n\n');
    dados.credito_cartao_avisado = true;
    upd.dados = { ...(upd.dados || {}), credito_cartao_avisado: true };
  }
}
// 12/11 (portão P28, determinístico): há pedido Nio em andamento no CPF e a Mari ainda não perguntou → a pergunta fixa sai
// nesta resposta (as outras perguntas do modelo ficam para depois: uma pergunta por vez). O atendimento segue.
{
  const cc = ctx.conversa || {};
  const histP = Array.isArray((prep.consolidado || {}).historico) ? prep.consolidado.historico : [];
  const jaPerguntou = histP.some((h) => h.papel === 'mari' && /pedido[^.?!]{0,60}(andamento|aberto)/.test(norm(h.texto)));
  if (V7 && !posHandoff && !erro && !handoff && ['sim', 'endereco'].includes(cc.nio_pedido_aberto) && !jaPerguntou
    && !dados.pedido_aberto_resposta && !((cc.dados || {}).pedido_aberto_resposta)) {
    const pn = String((cc.dados || {}).nome || '').trim().split(/\s+/)[0];
    const semPerg = baloesFinais.join('\n\n').split('\n\n').filter((p) => p.trim() && !p.includes('?'));
    // 0383 (L-82): o portal pode ter achado o pedido no ENDEREÇO (de qualquer CPF) — a pergunta diz onde
    baloesFinais = [...semPerg, cc.nio_pedido_aberto === 'endereco'
      ? `Uma coisa${pn ? `, ${pn}` : ''}: já existe um pedido de internet da Nio em andamento no seu endereço. Foi você ou alguém da casa que fez? Ele ainda está valendo?`
      : `Uma coisa${pn ? `, ${pn}` : ''}: já existe um pedido de internet da Nio em andamento no seu CPF. Foi você que fez? Ele ainda está valendo?`];
    texto = baloesFinais.join('\n\n');
    delete tags.botoes; delete tags.carrossel;
  }
}
// 12/11 (Ricardo): depois da forma de pagamento, a preferência de DATA em botões (D+1, D+2, D+3 — sem domingo) e depois o
// PERÍODO (Manhã · Tarde). Sempre preferência: quem confirma a data é o nosso time, pela agenda da Nio (contrato: nunca prometer).
const DIAS_SEM = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];
const datasInstalacao = () => {
  const hoje = new Date(new Date().toLocaleString('en-US', { timeZone: 'America/Sao_Paulo' }));
  const out = [];
  for (let i = 1; out.length < 3 && i < 8; i++) {
    const x = new Date(hoje.getFullYear(), hoje.getMonth(), hoje.getDate() + i);
    if (x.getDay() === 0) continue;   // domingo não
    const dd = String(x.getDate()).padStart(2, '0'); const mm = String(x.getMonth() + 1).padStart(2, '0');
    const iso = `${x.getFullYear()}-${mm}-${dd}`;
    if ((inter.feriados || []).some((f) => String(f.data).slice(0, 10) === iso && (!f.cidade || norm(f.cidade) === norm(c.cidade)))) continue;   // feriado não (0134)
    out.push({ id: `dt:${x.getFullYear()}-${mm}-${dd}`, title: `${DIAS_SEM[x.getDay()]}, ${dd}/${mm}` });
  }
  return out;
};
const msgDt = String((prep.consolidado || {}).mensagem || '').trim();
const ehRespostaData = /^(dom|seg|ter|qua|qui|sex|s[aá]b)[a-zçá-]*,?\s*\d{1,2}\/\d{1,2}$/i.test(msgDt);
// "tanto faz"/"qualquer dia" logo depois da pergunta da data (portão, cenário o) = qualquer data → segue para o período.
const histDt = Array.isArray((prep.consolidado || {}).historico) ? prep.consolidado.historico : [];
const ultMariDt = [...histDt].reverse().find((h) => h.papel === 'mari');
const ehQualquerData = !ehRespostaData && !(c.dados || {}).instalacao_data && ultMariDt && /qual destas datas|botoes: (dom|seg|ter|qua|qui|sex|sab)/.test(norm(ultMariDt.texto))
  && /^(tanto faz|qualquer|qualquer (um|uma|dia|data)|pode ser qualquer( um| uma| dia| data)?|tanto faz o dia|o (dia|que) (for )?(melhor|mais rapido)[a-z ]*|o mais rapido( possivel)?)!?\.?$/.test(norm(msgDt));
if (V7 && !posHandoff && (ehRespostaData || ehQualquerData) && !c.instalacao_preferencia && !upd.instalacao_preferencia) {
  const dtv = ehQualquerData ? 'qualquer data' : msgDt;
  dados.instalacao_data = dtv; m.dados.instalacao_data = dtv;
  upd.dados = { ...(upd.dados || {}), instalacao_data: dtv };
}
// Pergunta de data/período que o modelo escreveu (às vezes copia o corpo dos botões, com as datas em texto): ela e o que vem
// depois saem — o sistema manda os botões (portão 12/11, cenário a).
const PERG_TURNO = /manha ou (a |de |pela |a de )?tarde|manha\b[^?\n]{0,25}\btarde\b[^\n]{0,40}\?|qual (turno|periodo)|instalacao, voce prefere|(qual|quais) (destas |dessas |das )?datas?\b|qual (data|dia)\b[^?]{0,40}instala|data[^?]{0,30}instala|periodo voce prefere/;
if (V7 && !posHandoff && !erro && !handoff && m.forma_pagamento && !m.instalacao_preferencia && !upd.instalacao_preferencia
  && tags.botoes !== 'pagamento' && !baloesFinais.some((b) => RESUMO_RE.test(norm(b)))
  // 21/11 (L-236): a fala que pergunta a unidade (a lista da Nio chegou agora) vai sozinha — data e período ficam para a próxima.
  && !(UNIDADES.length && UNIDADES.some((u) => norm(baloesFinais.join(' ')).includes(norm(u).replace(/^(apartamento|apto|casa|bloco|loja) /, ''))))) {
  const paras = baloesFinais.join('\n\n').split('\n\n');
  const iPerg = paras.findIndex((p) => PERG_TURNO.test(norm(p)));
  const semTurno = (iPerg >= 0 ? paras.slice(0, iPerg) : paras).filter((p) => p.trim());
  const ult = norm(semTurno[semTurno.length - 1] || '');
  if (!ult.includes('?')) {            // outra pergunta pendente (ex.: um dado que faltou) vem antes
    baloesFinais = semTurno;
    texto = baloesFinais.join('\n\n');
    tags.botoes = m.dados.instalacao_data ? 'turno' : 'data';
  }
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
    data: datasInstalacao(),
    credito: [{ id: 'cred:sim', title: 'Sim, autorizo' }, { id: 'cred:nao', title: 'Não autorizo' }],
    turno: [{ id: 'turno:manha', title: 'Manhã' }, { id: 'turno:tarde', title: 'Tarde' }, { id: 'turno:qualquer', title: 'Tanto faz' }],
    pagamento: [{ id: 'pg:cartao', title: 'Cartão de crédito' }, { id: 'pg:boleto', title: 'Boleto bancário' }, { id: 'pg:debito', title: 'Débito automático' }],
    // 16/11 (0233): até 2 unidades da lista da Nio (título do WhatsApp ≤ 20) + "Nenhuma dessas"; mais que isso fica no texto.
    unidade: UNIDADES.length && UNIDADES.length <= 2 && UNIDADES.every((u) => u.length <= 20)
      ? [...UNIDADES.map((u, i) => ({ id: `un:${i + 1}`, title: u })), { id: 'un:nenhuma', title: 'Nenhuma dessas' }] : null,
    // 21/11 (L-222): a resposta do upsell — fica no escolhido ou troca pelo de cima (título ≤ 20).
    upsell: (() => {
      const par = planoAcima(upd.plano_escolhido || c.plano_escolhido);
      return par ? [{ id: 'up:fica', title: `Fico no ${par.nAtual}`.slice(0, 20) }, { id: 'up:troca', title: `Quero o ${par.nAcima}`.slice(0, 20) }] : null;
    })(),
  }[chave];
  if (BOT) {
    let corpo = '';
    if (chave === 'pagamento') {
      const cod = upd.plano_escolhido || (c.plano_escolhido || null);
      const pl = (ctx.planos || []).find((p) => p.codigo === cod);
      corpo = pl && !ctx.btu && pl.preco_cartao != null && txts.pagamento_corpo
        ? txts.pagamento_corpo.replace('{de}', moeda(pl.preco)).replace('{por}', moeda(pl.preco_cartao))
        : (txts.pagamento_corpo_sem_desconto || 'Como você quer pagar?');
    } else if (chave === 'credito') {
      corpo = txts.credito_autorizacao_corpo || 'Antes da forma de pagamento: você autoriza a gente a consultar o seu CPF na análise de crédito da Nio? É ela que diz quais formas de pagamento ficam liberadas pro seu pedido.';
    } else if (chave === 'data') {
      corpo = txts.instalacao_data_corpo || 'Qual destas datas você prefere para a instalação? É só a sua preferência: o nosso time confirma a data pela agenda da Nio 😊';
    } else if (chave === 'turno') {
      corpo = txts.instalacao_turno_corpo || 'E qual período você prefere nesse dia?';
    } else if (baloesFinais.length) {
      corpo = baloesFinais[baloesFinais.length - 1];     // a pergunta vira o corpo da mensagem com botões
      baloesFinais = baloesFinais.slice(0, -1);
    }
    if (corpo) interativo = { tipo: 'botoes', chave, corpo: corpo.slice(0, 1024), botoes: BOT,
      resumo: `botões: ${BOT.map((x) => x.title).join(' / ')}`,
      fallbackTexto: ['data', 'turno'].includes(chave) ? `${corpo}

${BOT.map((x) => x.title).join(' · ')}` : corpo };
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
// 26/11 (P56): trava do vocativo. O 5b não manda mais o nome do WhatsApp ao modelo, mas ele ainda aparece no histórico (aberturas
// antigas, falas do time). Se a resposta chamar o cliente pelo 1º nome do WhatsApp e esse não for o nome que ele informou, o
// vocativo sai: "Sem pressa, Mamãe! Fico aqui" → "Sem pressa! Fico aqui"; "Mamãe, o preço…" → "O preço…". Nunca mexe no resto.
// 26/11 22h (L-397): a cliente escreveu "A minha prima me passou seu contato keroly" e a Mari respondeu "Que bom, Keroly!" — o nome
// era da prima. Sem nome informado pelo cliente (nem [DADOS_COLETADOS] neste turno), palavra com cara de nome que o CLIENTE escreveu
// também não vale como vocativo: sai do mesmo jeito. Ficam de fora as palavras do endereço, da cidade e dos planos.
if (!erro && !(resp.fixo && (resp.fixo.texto || resp.fixo.interativo))) {
  const cz = ctx.conversa || {};
  const zap = String(cz.nome_contato || '').trim().split(/\s+/)[0] || '';
  const real = String(m.dados.nome || '').trim().split(/\s+/)[0] || '';
  const cand = [];
  if (/^[A-Za-zÀ-ÿ']{2,}$/.test(zap) && norm(zap) !== norm(real) && !(cz.nome_confiavel && !real)) cand.push({ re: zap, fl: 'gim', nome: zap });
  if (!real && !cz.nome_confiavel) {
    const ec = cz.endereco_cep || {};
    const fora = new Set(norm([cz.cidade, cz.complemento, ec.logradouro, ec.bairro, ec.localidade, ...(ctx.planos || []).map((p) => p.nome),
      'sim nao obrigada obrigado claro beleza combinado perfeito fibra essencial super ultra nio mari mariana casa apto centro '
      + 'olha veja show legal entendi imagina poxa tranquilo otimo maravilha bacana joia fechado fechou prazer opa'].filter(Boolean).join(' '))
      .split(/[^a-z']+/).filter(Boolean));
    const hl = Array.isArray((prep.consolidado || {}).historico) ? prep.consolidado.historico : [];
    const ditas = [String((prep.consolidado || {}).mensagem || ''), ...hl.filter((h) => h && h.papel === 'lead').map((h) => String(h.texto || ''))].join(' ');
    const vistas = new Set();
    for (const w of ditas.split(/[^A-Za-zÀ-ÿ']+/)) {
      const k = norm(w);
      if (w.length < 3 || w.length > 14 || vistas.has(k) || fora.has(k) || k === norm(zap) || !pareceNome(w, 1)) continue;
      vistas.add(k);
      cand.push({ re: `${w.charAt(0).toUpperCase()}${w.slice(1).toLowerCase()}`, fl: 'gm', nome: w });   // só com inicial maiúscula na resposta
    }
  }
  const antesV = baloesFinais.join('\n\n');
  const tirados = [];
  for (const c of cand) {
    const meio = new RegExp(`,[ \\t]*${c.re}(?=[ \\t]*(?:[,!.?…]|$))`, c.fl);
    const ini = new RegExp(`^${c.re}[ \\t]*[,!][ \\t]*(\\S)?`, c.fl);
    const tira = (s) => (typeof s === 'string' ? s.replace(meio, '').replace(ini, (_, c1) => (c1 ? c1.toUpperCase() : '')) : s);
    const antesC = baloesFinais.join('\n\n') + ((interativo && interativo.corpo) || '');
    baloesFinais = baloesFinais.map(tira).filter((b) => String(b || '').trim());
    if (interativo && interativo.corpo) interativo.corpo = tira(interativo.corpo);
    if (baloesFinais.join('\n\n') + ((interativo && interativo.corpo) || '') !== antesC) tirados.push(c.nome);
  }
  if (tirados.length) { tags.vocativo_tirado = tirados.join(', '); if (baloesFinais.join('\n\n') !== antesV) texto = baloesFinais.join('\n\n'); }
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
