// NIOGEN | n8n/mari/n05b_motor.js — nó "5b · Motor" do mari_principal (04/11/2026)
// Monta o payload do Claude: preenche {{ESTADO_ATUAL}}, {{INTERNAL_DATA}}, {{HORARIO_COMERCIAL}} e
// {{DATA_HORA_ATUAL}} no texto do nó "5a · Conteúdo Mari" a partir do BANCO (mari_contexto: conversa,
// área/cluster, config_planos do cluster, DFV). Normaliza a alternância user/assistant.
// O motor não tem texto de comportamento: só rótulos de estado e formatação dos planos.

const MODEL = 'claude-sonnet-5';
const MAX_TOKENS = 1536;

const db = $('4b · Supabase contexto').first().json;
const prep = $('4 · Preparar').first().json;
const conteudo = $('5a · Conteúdo Mari').first().json;
// Versão do prompt (mari_v3, mari_v4…): v3+ = jeito de falar/balões/emoji; v4+ = venda remota (instalação no lugar da visita).
const VER = Number((String(conteudo.promptVersao || '').match(/mari_v(\d+)/) || [])[1] || 0);
const V4 = VER >= 4;
const conv = db.conversa || {};
const planos = Array.isArray(db.planos) ? db.planos : [];
const cons = prep.consolidado || {};
const dados = conv.dados || {};

// ── relógio de Brasília e horário do contrato (seg–sex 9–21, sáb 10–16, nunca domingo) ──
const agora = new Date();
const partes = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
  timeZone: 'America/Sao_Paulo', weekday: 'short', hour: 'numeric', hour12: false,
}).formatToParts(agora).map((p) => [p.type, p.value]));
const hora = Number(partes.hour) % 24;
const dia = partes.weekday; // Mon..Sun
const dentroHorario = (['Mon', 'Tue', 'Wed', 'Thu', 'Fri'].includes(dia) && hora >= 9 && hora < 21)
  || (dia === 'Sat' && hora >= 10 && hora < 16);
const dataHora = agora.toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', weekday: 'long', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });
const horarioTxt = dentroHorario
  ? 'HORARIO_COMERCIAL: true — prazo do consultor: "em até 2 horas"'
  : 'HORARIO_COMERCIAL: false — prazo do consultor: "no próximo horário de atendimento"';

// ── validações determinísticas ──
function cpfValido(v) {
  const d = String(v || '').replace(/\D/g, '');
  if (d.length !== 11 || /^(\d)\1{10}$/.test(d)) return false;
  const dv = (n) => { let s = 0; for (let i = 0; i < n; i++) s += Number(d[i]) * (n + 1 - i); const r = (s * 10) % 11; return r === 10 ? 0 : r; };
  return dv(9) === Number(d[9]) && dv(10) === Number(d[10]);
}
const emailValido = (e) => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(String(e || ''));
const telValido = (t) => /^\d{10,11}$/.test(String(t || '').replace(/\D/g, '').replace(/^55(?=\d{10,11}$)/, ''));

// ── formatação dos planos (INTERNAL DATA) ──
const R = (v) => {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isInteger(n) ? `R$${n}` : `R$${n.toFixed(2).replace('.', ',')}`;
};
const nomeCurto = (n) => String(n || '').replace(/\s*\(.*?\)\s*/g, ' ').replace(/^Nio Empresas /, 'Nio ').replace(/\s+\d.*$/, '').trim();
function txt5g(p) {
  const s = String(p.internet_5g || '');
  if (!s) return null;
  const gb = (s.match(/(\d+\s*GB)/i) || [])[1] || s;
  const cham = /chamadas/i.test(s) ? ' com chamadas ilimitadas' : '';
  return /2\s*chips/i.test(s) ? `2 chips com ${gb} de internet 5G cada${cham}` : `${gb} de internet 5G${cham}`;
}
function inclusos(p) {
  return (p.inclusos || [])
    .filter((i) => !/ponto extra mesh/i.test(i))
    .map((i) => i.replace(/\s(\d+)\s*meses$/i, ' por $1 meses'));
}
const seg = conv.segmento === 'empresas' ? 'empresas' : 'varejo';
const cluster = conv.cluster || null;
const btu = cluster === 'btu';
const principais = planos.filter((p) => p.portfolio === seg && ['regular', 'oferta50'].includes(p.variante)).sort((a, b) => a.preco - b.preco);

// preco_dia (v3, "achei caro"): preço da forma / 30, arredondado PARA CIMA no centavo, e o "menos de R$N" seguro
// (N = parte inteira + 1, sempre maior que o valor por dia). Calculado aqui — o modelo só copia.
const formaConv = conv.forma_pagamento || null;
const porDia = (v) => {
  if (v === null || v === undefined || v === '') return null;
  const c = Math.ceil(Math.round(Number(v) * 100) / 30);          // centavos, para cima
  const reais = (c / 100).toFixed(2).replace('.', ',');
  return `R$${reais} por dia (dá pra dizer "menos de R$${Math.floor(c / 100) + 1} por dia")`;
};
function linhaDia(p) {
  const cartao = !btu && p.preco_cartao != null;
  if (formaConv === 'cartao' && cartao) return `preco_dia (no cartão, a forma escolhida): ${porDia(p.preco_cartao)}`;
  if (formaConv) return `preco_dia (na forma escolhida): ${porDia(p.preco)}`;
  return cartao ? `preco_dia: ${porDia(p.preco)} · no cartão ${porDia(p.preco_cartao)}` : `preco_dia: ${porDia(p.preco)}`;
}

function linhaPlano(p, semFidelidade) {
  const campos = [
    `codigo: ${p.codigo}`,
    `nome: ${nomeCurto(p.nome)}${semFidelidade ? ' (versão sem fidelidade)' : ''}`,
    `internet: ${p.velocidade_mb >= 1000 ? `${p.velocidade_mb / 1000} Giga` : `${p.velocidade_mb} Mega`}`,
    `wifi: ${p.wifi || '—'}`,
  ];
  const vem = [txt5g(p), ...inclusos(p)].filter(Boolean);
  if (vem.length) campos.push(`já vem com: ${vem.join(' + ')}`);
  campos.push(`preco: ${R(p.preco)}/mês`);
  if (!btu) campos.push(p.preco_cartao != null ? `preco_cartao: ${R(p.preco_cartao)}/mês` : 'preco_cartao: — (mesmo preço no cartão)');
  if (!semFidelidade) campos.push(linhaDia(p));
  if (semFidelidade) campos.push(`taxa_instalacao: ${R(p.taxa_habilitacao)} inteira na 1ª fatura`);
  else campos.push(`taxa_instalacao: ${R(p.taxa_habilitacao)}, isenta com ${p.isencao_meses} meses`);
  return '- ' + campos.join(' | ');
}

let internalData;
if (conv.dentro_area === false) {
  internalData = `(A cidade ${conv.cidade || 'do cliente'} está FORA da área de atuação — não há planos. Siga o Passo 2: fora_de_area.)`;
} else if (!cluster) {
  internalData = '(Cidade ainda não identificada pelo CEP — NÃO apresente planos nem preços; peça o CEP e o número.)';
} else if (!principais.length) {
  internalData = '(Nenhum plano ativo para esta cidade e segmento — não invente; handoff pedido_humano.)';
} else {
  // As duas tabelas da cidade vão sempre: se o cliente disser NESTA mensagem que é empresa (CNPJ/MEI),
  // a Mari já usa a de Empresas no mesmo turno (o segmento só é gravado depois da resposta).
  const doPortfolio = (pf, variantes) => planos.filter((p) => p.portfolio === pf && variantes.includes(p.variante)).sort((a, b) => a.preco - b.preco);
  const secao = (pf, titulo) => {
    const pr = doPortfolio(pf, ['regular', 'oferta50']);
    const sf = doPortfolio(pf, ['nfid', 'oferta50_nfid']);
    if (!pr.length) return [`${titulo}: (não há planos nesta cidade)`];
    return [
      `${titulo} — apresente nesta ordem, até 3 por bloco:`,
      ...pr.map((p) => linhaPlano(p, false)),
      `${titulo} — versão sem fidelidade (NÃO oferecer; só se o cliente pedir zero compromisso):`,
      ...(sf.length ? sf.map((p) => linhaPlano(p, true)) : ['- (não há versão sem fidelidade)']),
    ];
  };
  internalData = [
    `tabela_cidade: ${btu ? 'BTU — preço ÚNICO em todos os meios de pagamento (não fale em cartão mais barato nem em desconto)' : 'REGULAR — dois preços: boleto/débito (preco) e cartão de crédito (preco_cartao)'}`,
    `segmento_atual: ${seg === 'empresas' ? 'Empresas (CNPJ)' : 'Varejo (pessoa física, CPF)'} — use SÓ a seção do segmento do cliente; se ele acabou de dizer que é para empresa/CNPJ/MEI, use já a seção PLANOS EMPRESAS`,
    '',
    ...secao('varejo', 'PLANOS VAREJO (pessoa física, CPF)'),
    '',
    ...secao('empresas', 'PLANOS EMPRESAS (CNPJ, MEI ou não)'),
  ].join('\n');
}

// ── ESTADO_ATUAL ──
const historico = Array.isArray(cons.historico) ? cons.historico : [];
const primeira = historico.length === 0;
const end = conv.endereco_cep || null;
const planoSel = planos.find((p) => p.codigo === conv.plano_escolhido) || null;
const cpfOk = dados.cpf ? cpfValido(dados.cpf) : null;
const faltando = [];
if (!dados.nome) faltando.push('nome');
if (!dados.cpf || !cpfOk) faltando.push('cpf');
if (!dados.telefone || !telValido(dados.telefone)) faltando.push('telefone');
if (!dados.email || !emailValido(dados.email)) faltando.push('email');
if (!conv.forma_pagamento) faltando.push('pagamento');
if (!(conv.instalacao_preferencia || conv.visita_preferencia)) faltando.push(V4 ? 'instalacao' : 'visita');
const formaTxt = { boleto: 'boleto', dacc: 'débito automático', cartao: 'cartão de crédito' }[conv.forma_pagamento] || null;

const L = [];
L.push(`primeira_mensagem: ${primeira ? 'sim' : 'nao'}`);
L.push(`status_conversa: ${conv.status}`);
L.push(`etapa: ${conv.etapa}`);
L.push(`telefone_whatsapp: ${String(conv.telefone || '').replace(/^55/, '')}`);
L.push(`nome_contato: ${conv.nome_contato || '—'} | nome_confiavel: ${conv.nome_confiavel ? 'sim' : 'nao (não chame por esse nome)'}`);
L.push(`cep: ${conv.cep || '—'}${prep.cepInvalido ? ' | cep_invalido: sim (ViaCEP não achou)' : ''}${prep.viacepFalhou ? ' | endereco_do_cep indisponível agora — pergunte rua e bairro' : ''}`);
L.push(`numero: ${conv.numero || '—'} | complemento: ${conv.complemento || (dados.complemento_ok ? 'não tem' : '—')} | complemento_respondido: ${conv.complemento || dados.complemento_ok ? 'sim' : 'nao'}`);
L.push(`endereco_do_cep: ${end ? [end.logradouro, end.bairro, `${end.localidade}/${end.uf}`].filter(Boolean).join(', ') + (end.logradouro ? '' : ' (CEP geral da cidade — pergunte rua e bairro)') : '—'}`);
L.push(`cidade: ${conv.cidade || '—'} | dentro_area: ${conv.dentro_area === true ? 'SIM' : conv.dentro_area === false ? 'NAO' : 'ainda não sabemos'} | tabela_cidade: ${cluster ? cluster.toUpperCase() : '—'}`);
L.push(`dfv_resultado (uso interno, nunca citar): ${conv.dfv_resultado || '—'}`);
if (V4) {
  // Viabilidade oficial do portal da Nio (nível A). Em espera desde 05/11 (login BO = SSO Microsoft): sem consulta,
  // o estado diz "indisponivel" e a Mari segue a fala por cidade + DFV (Bloco 9 do prompt v4).
  const nv = conv.nio_viab_resultado || 'indisponivel';
  L.push(`nio_viab_resultado (viabilidade oficial do endereço, uso interno, nunca citar): ${nv}${conv.nio_viab_velocidade ? ` | velocidade_maxima: ${conv.nio_viab_velocidade}` : ''}`
    + (['viavel', 'posse'].includes(nv) ? '' : ' (fluxo normal: planos e cobertura pela cidade — nunca diga nem insinue que o endereço não é atendido)'));
}
if (!conv.elegibilidade || conv.elegibilidade === 'cancelou_30d') {
  // Trava do contrato (reativação ≤ 30 d = estorno 100 %): a data de retorno é calculada aqui, nunca pelo modelo.
  // Retorno = data do cancelamento + 31 dias = hoje + (31 − N), no calendário de Brasília.
  const hojeSP = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(agora); // AAAA-MM-DD
  const base = new Date(`${hojeSP}T12:00:00Z`);
  const tabela = [];
  for (let n = 0; n <= 30; n++) {
    const d = new Date(base.getTime() + (31 - n) * 86400000).toISOString().slice(0, 10);
    tabela.push(`${n}→${d.slice(8, 10)}/${d.slice(5, 7)} (${d})`);
  }
  L.push(`tabela_retorno_cancelamento (cancelou há N dias → nova adesão a partir de; já calculada — copie, não faça conta): ${tabela.join(' · ')}`);
}
L.push(`elegibilidade: ${conv.elegibilidade || 'não perguntada'}`);
L.push(`segmento: ${seg}${seg === 'empresas' ? ` | mei: ${conv.mei === true ? 'sim' : conv.mei === false ? 'nao' : 'não perguntado'}` : ''}`);
L.push(`plano_escolhido: ${planoSel ? `${planoSel.codigo} — ${nomeCurto(planoSel.nome)} — ${R(planoSel.preco)}${!btu && planoSel.preco_cartao != null ? ` (cartão ${R(planoSel.preco_cartao)})` : ''}` : '—'}`);
if (planoSel && conv.forma_pagamento) {
  // Preço da forma já escolhida (cartão em cidade Regular = preco_cartao), calculado aqui — o modelo só copia.
  const noCartao = conv.forma_pagamento === 'cartao' && !btu && planoSel.preco_cartao != null;
  L.push(`valor_mensal_na_forma: ${R(noCartao ? planoSel.preco_cartao : planoSel.preco)}/mês no ${formaTxt} — use SÓ este valor na confirmação e no resumo`);
}
L.push(`upsell_oferecido: ${conv.upsell_oferecido ? 'sim' : 'nao'} | lgpd_enviada: ${conv.lgpd_enviada ? 'sim' : 'nao'}`);
L.push(`dados: nome=${dados.nome || '—'}; cpf=${dados.cpf || '—'}${dados.cpf ? ` (cpf_valido: ${cpfOk ? 'SIM' : 'NAO'})` : ''}; telefone=${dados.telefone || '—'}; email=${dados.email || '—'}; pagamento=${formaTxt || '—'}; ${V4 ? `instalacao=${conv.instalacao_preferencia || '—'}` : `visita=${conv.visita_preferencia || '—'}`}`);
L.push(`dados_faltando: ${faltando.length ? faltando.join(', ') : 'nenhum'}`);
// v3 (regra de emoji): quantos emojis a Mari já usou e se o cliente usa — o 7 · Extrair aplica o teto.
const EMOJI_RE = /\p{Extended_Pictographic}/gu;
const nEmoji = (s) => (String(s || '').match(EMOJI_RE) || []).length;
const emojiMari = historico.filter((h) => h.papel === 'mari').reduce((a, h) => a + nEmoji(h.texto), 0);
const emojiCliente = historico.filter((h) => h.papel === 'lead').reduce((a, h) => a + nEmoji(h.texto), 0) + nEmoji(cons.mensagem);
const v3 = VER >= 3;
if (v3) {
  // Variação fixa por conversa (1–6), do id: conversas independentes não sabem umas das outras e, sem isto,
  // o modelo abre e confirma sempre pelo exemplo nº 1 (bateria 04/11: 7/10 aberturas e 9/10 confirmações iguais).
  // Sorteio por conversa, guardado para os turnos seguintes (até 2000 conversas). Abertura = cumprimento (6) ×
  // pedido do CEP (6) = 36 combinações — com 6 opções só, 10 conversas repetem quase sempre (bateria 04/11).
  // (Rodízio por contador não serve: execuções simultâneas leem o mesmo contador.)
  const sdv = $getWorkflowStaticData('global');
  sdv._variacoes = sdv._variacoes || {};
  const cid = String(conv.id || '');
  if (!sdv._variacoes[cid]) {
    const d6 = () => 1 + Math.floor(Math.random() * 6);
    sdv._variacoes[cid] = [d6(), d6(), d6()];
    const chaves = Object.keys(sdv._variacoes);
    if (chaves.length > 2000) chaves.slice(0, chaves.length - 2000).forEach((k) => delete sdv._variacoes[k]);
  }
  const [vCump, vPed, variacao] = sdv._variacoes[cid];
  // O modelo não segue "use a nº N" (bateria 04/11: 6/10 no mesmo cumprimento, que ele achou mais simpático).
  // Então o motor copia do PRÓPRIO prompt (as listas moram no .md) as frases sorteadas e manda prontas no estado.
  const listaDoPrompt = (titulo) => {
    const pb = String(conteudo.promptBase || '');
    const i = pb.indexOf(titulo);
    if (i < 0) return [];
    const out = [];
    for (const l of pb.slice(i + titulo.length).split('\n').slice(1)) {
      const m = l.match(/^\s*\d\.\s+"(.+)"\s*$/);
      if (m) out.push(m[1]); else if (out.length) break;
    }
    return out;
  };
  const cump = listaDoPrompt('Cumprimentos:')[vCump - 1];
  const ped = listaDoPrompt('Pedidos do CEP')[vPed - 1];
  const conf = listaDoPrompt('Com ou sem upsell — confirmações')[variacao - 1];
  if (primeira && cump && ped) L.push(`abertura_da_conversa (use estas duas frases quase como estão): «${cump}» + «${ped}»`);
  if (conf) L.push(`confirmacao_da_conversa (com ou sem upsell; troque [plano] e [valor]): «${conf}»`);
  L.push(`emoji: você já usou ${emojiMari} na conversa | cliente usa emoji: ${emojiCliente > 0 ? `sim (${emojiCliente})` : 'nao — no máximo 2 na conversa inteira'}`);
}
if (cons.n_mensagens > 1) L.push(`mensagens_agrupadas: ${cons.n_mensagens} (o cliente mandou várias mensagens seguidas — responda tudo numa resposta só)`);
const estadoTxt = L.join('\n');

// ── system: parte fixa (cacheável) + parte dinâmica ──
const corte = conteudo.promptBase.indexOf('## AGORA E HORARIO_COMERCIAL');
const fixo = corte > 0 ? conteudo.promptBase.slice(0, corte) : conteudo.promptBase;
const dinamico = (corte > 0 ? conteudo.promptBase.slice(corte) : '')
  .replace('{{DATA_HORA_ATUAL}}', dataHora)
  .replace('{{HORARIO_COMERCIAL}}', horarioTxt)
  .replace('{{ESTADO_ATUAL}}', estadoTxt)
  .replace('{{INTERNAL_DATA}}', internalData);
const system = [{ type: 'text', text: fixo, cache_control: { type: 'ephemeral' } }];
if (dinamico) system.push({ type: 'text', text: dinamico });

// ── mensagens: histórico do banco + mensagem nova; alternância user/assistant ──
const msgs = [];
const push = (role, content) => {
  const t = String(content || '').trim();
  if (!t) return;
  const last = msgs[msgs.length - 1];
  if (last && last.role === role) last.content += '\n' + t;
  else msgs.push({ role, content: t });
};
// Fala do consultor humano (atendimento pelo Chatwoot) entra como 'assistant', marcada, para a Mari saber o que
// a equipe já disse ao cliente quando a conversa volta para ela.
for (const h of historico) {
  if (h.papel === 'lead') push('user', h.texto);
  else if (h.papel === 'humano') push('assistant', `[Mensagem do consultor da equipe, enviada enquanto ele atendia]\n${h.texto}`);
  else push('assistant', h.texto);
}
push('user', cons.mensagem);
while (msgs.length && msgs[0].role !== 'user') msgs.shift();

return [{ json: {
  model: MODEL, maxTokens: MAX_TOKENS, system, messages: msgs,
  ctx: {
    conversaId: conv.id, t0: Date.now(), promptVersao: conteudo.promptVersao,
    cluster, btu, dentroArea: conv.dentro_area, dentroHorario, segmento: seg,
    planos: planos.map((p) => ({ codigo: p.codigo, nome: p.nome, portfolio: p.portfolio, variante: p.variante, preco: p.preco, preco_cartao: p.preco_cartao })),
    conversa: { etapa: conv.etapa, cep: conv.cep, numero: conv.numero, complemento: conv.complemento, cidade: conv.cidade,
      elegibilidade: conv.elegibilidade, plano_escolhido: conv.plano_escolhido, forma_pagamento: conv.forma_pagamento,
      visita_preferencia: conv.visita_preferencia, instalacao_preferencia: conv.instalacao_preferencia,
      nio_viab_resultado: conv.nio_viab_resultado, nio_viab_velocidade: conv.nio_viab_velocidade, nio_viab_interesse_id: conv.nio_viab_interesse_id,
      dados, dfv_resultado: conv.dfv_resultado, lgpd_enviada: conv.lgpd_enviada,
      nome_contato: conv.nome_contato, telefone: conv.telefone, mei: conv.mei },
    turnoIds: cons.turno_ids || [],
    estado: estadoTxt,
    emojiMari, emojiCliente,
  },
} }];
