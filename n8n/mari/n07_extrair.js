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
  handoff: handoffYaml,
};
Object.keys(tags).forEach((k) => { if (tags[k] === null) delete tags[k]; });

// ── 3. limpeza ──
const NOMES_TAG = 'CIDADE_DETECTADA|ENDERECO|ELEGIBILIDADE|SEGMENTO|PLANO_ESCOLHIDO|UPSELL_OFERECIDO|DADOS_COLETADOS|SINAL_URGENCIA|AGENDAMENTO_RETORNO|AVALIACAO';
let texto = bruto
  .replace(/\[HANDOFF\][\s\S]*?(\[\/HANDOFF\]|$)/gi, '')
  .replace(new RegExp(`\\[(?:${NOMES_TAG})(?:\\s*:[^\\]]*)?\\]`, 'gi'), '')
  .replace(/^\s*\[?(INTERNAL DATA|ESTADO_ATUAL[^\]]*)\]?.*$/gim, '')
  .replace(/[ \t]+\n/g, '\n')
  .replace(/\n{3,}/g, '\n\n')
  .trim();

// ── 4. filtro de saída ──
// O nome da revendedora é montado por partes: o export do workflow não pode conter a palavra.
const PROIBIDAS = [
  ['dh' + 'arma', 'o nome da empresa revendedora'], ['gratis', '"grátis"'], ['gratuit', '"gratuito"'], ['combo', '"combo"'], ['pacote', '"pacote"'],
  ['bundle', '"bundle"'], ['nio 5g', '"Nio 5G"'], ['nio movel', '"Nio Móvel"'], ['nio cel', '"Nio Cel"'], ['nio mobile', '"Nio Mobile"'],
  ['chip da nio', '"chip da Nio"'], ['2028', '"2028"'], ['cobertura confirmada', '"cobertura confirmada"'],
];
// v3 (Bloco 2, itens 4 e 5) — só para o prompt v3 (a v2 usa ✅ 🎯 📍 💰 1️⃣ de propósito).
// Expressão de robô → pede reescrita. Emoji → o motor corrige sozinho (sem gastar outra chamada) e conta.
const V3 = String(ctx.promptVersao || '').startsWith('mari_v3');
const FRASES_ROBO = [['prezad', '"Prezado"'], ['informamos', '"Informamos"'], ['gostaria de', '"Gostaria de"'],
  ['fico a disposicao', '"Fico à disposição"'], ['estou aqui para ajudar', '"Estou aqui para ajudar"'],
  ['como posso te ajudar hoje', '"Como posso te ajudar hoje?"'], ['certamente', '"Certamente"'], ['excelente pergunta', '"Excelente pergunta"']];

function violacoesDe(t) {
  const n = norm(t);
  const v = PROIBIDAS.filter(([k]) => n.includes(k)).map(([, r]) => `usou a palavra proibida ${r}`);
  if (V3) FRASES_ROBO.filter(([k]) => n.includes(k)).forEach(([, r]) => v.push(`usou a expressão de robô ${r}`));
  // Guard-rail 23 (afrouxado 05/11): a sugestão de upgrade vem DEPOIS da confirmação da escolha com o valor do plano
  // (a confirmação sorteada da conversa) — o 1º "R$" da resposta tem de vir antes do "por mais R$".
  if (V3 && temTag('UPSELL_OFERECIDO') && /por mais r\$/.test(n) && n.indexOf('r$') >= n.indexOf('por mais r$')) {
    v.push('sugestão de upgrade sem antes confirmar a escolha com o plano e o valor (guard-rail 23)');
  }
  if (t.includes('*')) v.push('usou asterisco (markdown aparece cru no WhatsApp)');
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
if (tel) dados.telefone = tel;
if (email && email !== '—') dados.email = email.toLowerCase();

const pag = norm(d.pagamento || hy.forma_pagamento || '');
if (pag) {
  if (/cart|credit/.test(pag)) upd.forma_pagamento = 'cartao';
  else if (/debit|dacc|automat/.test(pag)) upd.forma_pagamento = 'dacc';
  else if (/boleto/.test(pag)) upd.forma_pagamento = 'boleto';
}
const visita = d.visita || hy.visita_preferencia;
if (visita && visita !== '—') upd.visita_preferencia = visita;

if (tags.endereco) {
  const e = kv(tags.endereco);
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

if (/seus dados sao usados/.test(norm(texto))) upd.lgpd_enviada = true;
if (tags.upsell_oferecido || /so pra voce saber: por mais/.test(norm(texto))) upd.upsell_oferecido = true;

const ag = tags.agendamento_retorno || null;
const agm = ag && ag.match(/(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2})/);
if (agm) upd.agendamento_retorno = `${agm[1]}T${agm[2]}:00-03:00`;

if (Object.keys(dados).length) upd.dados = dados;

// ── etapa (determinística, a partir do estado + atualizações) ──
const m = { ...c, ...upd, dados: { ...(c.dados || {}), ...dados } };
const cpfOk = (v) => { const x = String(v || '').replace(/\D/g, ''); if (x.length !== 11 || /^(\d)\1{10}$/.test(x)) return false; const dv = (k) => { let s = 0; for (let i = 0; i < k; i++) s += Number(x[i]) * (k + 1 - i); const r = (s * 10) % 11; return r === 10 ? 0 : r; }; return dv(9) === Number(x[9]) && dv(10) === Number(x[10]); };
const temDados = m.dados.nome && cpfOk(m.dados.cpf) && m.dados.telefone && m.dados.email && m.forma_pagamento && m.visita_preferencia;
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
}
if (!motivo && !erro) {
  if (ctx.dentroArea === false || upd.elegibilidade === 'fora_area') motivo = 'fora_de_area';
  else if (upd.elegibilidade === 'ja_cliente' || upd.elegibilidade === 'cancelou_30d') motivo = 'ja_cliente_nio';
}

let handoff = null;
if (motivo) {
  const notaDfv = {
    viavel: 'DFV viável',
    viavel_predio: 'DFV viável (prédio) — conferir a unidade',
    endereco_ocupado: 'DFV indica Nio ativo no endereço — confirmar com o cliente e no APP antes da visita',
  }[c.dfv_resultado] || (c.cidade && norm(c.cidade) === 'juiz de fora' ? 'DFV: conferir manualmente antes da visita' : 'DFV: sem base para a cidade — conferir manualmente');
  const briefing = [hy.briefing_humano, hy.resumo_perfil ? `Perfil: ${hy.resumo_perfil}` : null,
    tags.sinal_urgencia ? `Urgência: ${tags.sinal_urgencia}` : null, notaDfv].filter(Boolean).join('\n');
  handoff = {
    motivo,
    lead: {
      dados, briefing,
      forma_pagamento: upd.forma_pagamento || c.forma_pagamento || null,
      visita_preferencia: upd.visita_preferencia || c.visita_preferencia || null,
      agendamento_retorno: upd.agendamento_retorno || null,
      yaml: handoffYaml,
    },
  };
  // Rede de segurança: despedida vazia → fala padrão do motivo (roteiro, Bloco 6b).
  if (!texto) {
    const prazo = ctx.dentroHorario ? 'em até 2 horas' : 'no próximo horário de atendimento';
    texto = {
      dados_completos: `Pronto, anotado! Vou passar pro nosso consultor, que te chama aqui no WhatsApp ${prazo} pra confirmar a visita. Qualquer dúvida é só me chamar 😊`,
      recusa_compra: 'Sem problema! Se mudar de ideia, é só me chamar aqui. Foi um prazer conversar com você 😊',
      fora_de_area: 'Por enquanto a gente atende só algumas cidades de Minas 😕 Pra sua cidade, o televendas da Nio ajuda: 0800 031 0453.',
      ja_cliente_nio: 'Como o endereço já tem Nio, é direto com eles: App Nio ou 0800 001 1000 😊',
    }[motivo] || `Vou te passar pra um dos nossos consultores, que te chama aqui mesmo ${prazo} 😊`;
  }
}

return [{ json: {
  corrigir: false,
  conversaId: ctx.conversaId,
  texto, tags, upd, handoff, erro,
  // Balões: texto final (a despedida de segurança acima pode ter preenchido o texto depois do corte).
  baloes: baloes.length && baloes.join('\n\n') === texto ? baloes : (texto ? [texto] : []),
  emojiAjustes: emojiAjustes.length ? emojiAjustes : null,
  modelo: resp.model || motor.model,
  tokensIn, tokensOut,
  latenciaMs: Date.now() - ctx.t0,
  turnoIds: ctx.turnoIds,
  promptVersao: ctx.promptVersao,
  violacoes: null,
  violacoesCorrigidas,
} }];
