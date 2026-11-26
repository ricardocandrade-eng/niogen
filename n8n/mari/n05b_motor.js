// NIOGEN | n8n/mari/n05b_motor.js — nó "5b · Motor" do mari_principal (04/11/2026)
// Monta o payload do Claude: preenche {{ESTADO_ATUAL}}, {{INTERNAL_DATA}}, {{HORARIO_COMERCIAL}} e
// {{DATA_HORA_ATUAL}} no texto do nó "5a · Conteúdo Mari" a partir do BANCO (mari_contexto: conversa,
// área/cluster, config_planos do cluster, DFV). Normaliza a alternância user/assistant.
// O motor não tem texto de comportamento: só rótulos de estado e formatação dos planos.

const MODEL = __MODELO__;
const MAX_TOKENS = 1536;

const db = $('4b · Supabase contexto').first().json;
const prep = $('4 · Preparar').first().json;
const conteudo = $('5a · Conteúdo Mari').first().json;
// Versão do prompt (mari_v3, mari_v4…): v3+ = jeito de falar/balões/emoji; v4+ = venda remota (instalação no lugar da visita).
const VER = Number((String(conteudo.promptVersao || '').match(/mari_v(\d+)/) || [])[1] || 0);
const V4 = VER >= 4;
const V7 = VER >= 7;   // prompts 26 + 27: carrossel/botões, sem promessa de cobertura, rua divergente, referência, operadora
// Carrossel e textos interativos (0047, nó 4c). Falhou a leitura → {} e a Mari cai na lista em texto.
let inter = {};
try { inter = $('4c · Supabase interativo').first().json || {}; } catch (e) { inter = {}; }
const cartoes = Array.isArray(inter.cartoes) ? inter.cartoes : [];
const conv = db.conversa || {};
const planos = Array.isArray(db.planos) ? db.planos : [];
const cons = prep.consolidado || {};
const dados = { ...(conv.dados || {}) };
// 21/11 (L-222 "Am n entende", L-40 "Moro acima do bar"): nome que é frase não é nome — a Mari não chama o cliente por ele e
// pede o nome de novo. Mesma regra do 7 · Extrair (pareceNome).
{
  const NAO_NOME = new Set(('n nao num nem entendi entende entendo entender entendeu sei sabe quero queria quer tem tenho temos moro '
    + 'pode posso podia qual quais como quando onde porque pq por pra pro para com sem mas ok sim isso eu meu minha voce vc ta to '
    + 'esta estou acho aqui acima abaixo perto lado bar rua apto ap bloco plano internet chip oi ola bom boa dia tarde noite obrigado '
    + 'obrigada valeu blz beleza certo favor o a os as um uma que se ja so mais menos muito agora depois hoje amanha fala falar ver '
    + 'vou vai fica fico quero gostaria preciso tambem nada tudo alguem ninguem '
    // 26/11 (L-272 "Pera ai"): frase de espera e interjeição também não são nome.
    + 'pera perai peraia espera espere esperai calma momento momentinho minuto minutinho instante aguarda aguarde volto '
    + 'ai eita vixe opa hum hmm ue kkk tipo assim entao pronto pressa apressa').split(' '));
  const t = String(dados.nome || '').trim();
  const n = t.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
  if (t && (!/^[A-Za-zÀ-ÿ']+(?: [A-Za-zÀ-ÿ']+){0,6}$/.test(t) || n.split(' ').some((w) => NAO_NOME.has(w)))) delete dados.nome;
}

// ── relógio de Brasília e horário do contrato (seg–sex 9–21, sáb 10–16, nunca domingo) ──
const agora = new Date();
const partes = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
  timeZone: 'America/Sao_Paulo', weekday: 'short', hour: 'numeric', hour12: false,
}).formatToParts(agora).map((p) => [p.type, p.value]));
const hora = Number(partes.hour) % 24;
const dia = partes.weekday; // Mon..Sun
// 10/11 (rodada única, 0099): o banco diz se agora é horário de contato COM feriado (mari_no_horario pela cidade); sem a
// chave (banco antigo), a conta da semana de sempre. A Mari responde igual — muda só o prazo do consultor.
const dentroHorario = typeof db.no_horario === 'boolean' ? db.no_horario
  : ((['Mon', 'Tue', 'Wed', 'Thu', 'Fri'].includes(dia) && hora >= 9 && hora < 21) || (dia === 'Sat' && hora >= 10 && hora < 16));
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
// 08/11 (Ricardo): o telefone de contato é o do WhatsApp da conversa — a Mari não pergunta. O WhatsApp entrega celular
// sem o 9 ("553288015161"): sem DDI e com o 9 de volta quando é celular (8 dígitos começando por 6–9).
const foneWa = (t) => {
  let x = String(t || '').replace(/\D/g, '').replace(/^55(?=\d{10,11}$)/, '');
  if (/^\d{2}[6-9]\d{7}$/.test(x)) x = `${x.slice(0, 2)}9${x.slice(2)}`;
  return x;
};

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

// upsell (Passo 3b): a diferença vem calculada — portão 09/11 (p): "Essencial R$140… por mais R$15 tem o Super" (o 15 era
// o desconto do cartão; o certo é R$30). Plano seguinte do mesmo segmento, até R$40 a mais; o modelo só copia.
function linhaUpsell(p) {
  const acima = planos.filter((o) => o.portfolio === p.portfolio && o.variante === p.variante && Number(o.preco) > Number(p.preco)
    && Number(o.preco) - Number(p.preco) <= 40).sort((a, b) => a.preco - b.preco)[0];
  if (!acima) return 'upsell: — (não há plano acima até R$40; não ofereça upgrade)';
  const dif = Number(acima.preco) - Number(p.preco);
  const difC = !btu && p.preco_cartao != null && acima.preco_cartao != null ? Number(acima.preco_cartao) - Number(p.preco_cartao) : null;
  return `upsell: ${nomeCurto(acima.nome)} (${acima.codigo}) por mais ${R(dif)}/mês`
    + (difC != null && difC !== dif ? ` (no cartão, por mais ${R(difC)})` : '')
    + ' — use EXATAMENTE este valor em "por mais R$…"';
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
  if (!semFidelidade) campos.push(linhaUpsell(p));
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
  // 09/11 (conversa #40, Timóteo): com as duas tabelas sempre no contexto, a Mari copiou a de Empresas para um cliente
  // pessoa física (mesmos preços BTU, mesmos nomes, velocidades e inclusos diferentes). Agora vai SÓ a tabela do segmento
  // gravado; a outra entra só no turno em que a mensagem do cliente fala do outro segmento (o segmento é gravado depois
  // da resposta, então a Mari ainda precisa da outra tabela nesse turno).
  const msgCli = String(cons.mensagem || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  const falaEmpresa = /\b(cnpj|mei|empresa|empresas|empresarial|pj|pessoa juridica|comercio|comercial|loja|escritorio|negocio)\b/.test(msgCli);
  const falaCasa = /\b(cpf|pessoa fisica|residencia|residencial|pra casa|para casa|minha casa|nao e empresa|nao tenho cnpj)\b/.test(msgCli);
  const comOutra = seg === 'varejo' ? falaEmpresa : falaCasa;
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
    comOutra
      ? `segmento_atual: ${seg === 'empresas' ? 'Empresas (CNPJ)' : 'Varejo (pessoa física, CPF)'} — vão as duas tabelas só porque a mensagem do cliente fala do outro segmento: use a do segmento que ele disse AGORA; na dúvida, pergunte se é para casa ou para empresa (CNPJ/MEI) antes de mostrar planos. Nunca misture linhas das duas seções.`
      : `segmento_atual: ${seg === 'empresas' ? 'Empresas (CNPJ)' : 'Varejo (pessoa física, CPF)'} — esta é a ÚNICA tabela deste cliente; copie velocidade, inclusos e preço exatamente destas linhas.`,
    '',
    ...((seg === 'varejo' || comOutra) ? secao('varejo', 'PLANOS VAREJO (pessoa física, CPF)') : []),
    ...(comOutra ? [''] : []),
    ...((seg === 'empresas' || comOutra) ? secao('empresas', 'PLANOS EMPRESAS (CNPJ, MEI ou não)') : []),
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
// 08/11: sem telefone guardado, vale o do WhatsApp (o 7 · Extrair grava) — telefone só "falta" se nem esse servir.
if (!(dados.telefone && telValido(dados.telefone)) && !telValido(foneWa(conv.telefone))) faltando.push('telefone');
if (!dados.email || !emailValido(dados.email) || dados.email_confirmado === false) faltando.push('email');
if (!conv.forma_pagamento) faltando.push('pagamento');
if (!(conv.instalacao_preferencia || conv.visita_preferencia)) faltando.push(V4 ? 'instalacao' : 'visita');
if (V7 && !dados.referencia) faltando.push('referencia');   // o portal exige na etapa 2 (prompt 27 A5)
const formaTxt = { boleto: 'boleto', dacc: 'débito automático', cartao: 'cartão de crédito' }[conv.forma_pagamento] || null;

const L = [];
L.push(`primeira_mensagem: ${primeira ? 'sim' : 'nao'}`);
L.push(`status_conversa: ${conv.status}`);
L.push(`etapa: ${conv.etapa}`);
// 0061 (Ricardo, 07/11 23h30): só chega aqui com status handoff_realizado quem está na janela pós-handoff.
if (conv.status === 'handoff_realizado') {
  L.push('pos_handoff: sim — a venda acabou de ser passada ao nosso time (o pedido já está com eles). Siga a regra PÓS-HANDOFF (Bloco 3): '
    + 'agradecimento → só "Imagina[, nome]! 💚" e, se quiser, "Qualquer coisa é só chamar aqui."; dúvida final → responda curto pelas '
    + 'regras de sempre (sem prazo, link é da Nio); não venda, não peça nem refaça dados, não faça resumo, não emita tags nem [HANDOFF].');
}
if (conv.ciclo_anterior && typeof conv.ciclo_anterior === 'object') {
  // Prompt 18 (A, migration 0030): a conversa foi resolvida pelo nosso time e o cliente voltou a escrever.
  const ca = conv.ciclo_anterior;
  const MOT = { dados_completos: 'dados completos — o pedido já foi passado ao nosso time', pedido_humano: 'pediu um consultor',
    objecao: 'objeção', urgencia_alta: 'urgência', recusa_compra: 'recusou', multiplos_decisores: 'ia decidir com mais alguém',
    interesse_caindo: 'interesse caindo', fora_de_area: 'fora da área', ja_cliente_nio: 'já é cliente Nio' };
  L.push(`retomada: sim — esta conversa já passou pelo nosso time e foi encerrada; o cliente voltou a escrever agora. `
    + `Handoff anterior: ${MOT[ca.motivo] || ca.motivo || '?'}${ca.venda_id ? ' | venda_ja_registrada: sim' : ''}. Siga a regra RETOMADA (Bloco 3).`);
}
L.push(`telefone_whatsapp: ${foneWa(conv.telefone)} (é o telefone de contato: não pergunte)`);
// 26/11 (P56 — Ricardo: "Mari ainda continua chamando o cliente por nomes estranhos"): a linha levava SEMPRE o nome do WhatsApp.
// Com o cliente já identificado, saía "nome_contato: Cidinha 🥰 | nome_confiavel: sim" e a Mari fechava com "Pronto, Cidinha" (L-220,
// Maria Aparecida); sem identificação, o apelido ia com o aviso "não chame" e saía assim mesmo (L-269 "Tudo certo, Mamãe!").
// Agora só vai o nome que o CLIENTE informou (dados.nome); o do WhatsApp só quando nome_confiavel e for só letras. Sem isso, nada.
{
  const p1 = (s) => String(s || '').trim().split(/\s+/)[0] || '';
  const doZap = conv.nome_confiavel && /^[A-Za-zÀ-ÿ']{2,12}$/.test(p1(conv.nome_contato)) ? p1(conv.nome_contato) : '';
  const chamar = p1(dados.nome) || doZap;
  L.push(chamar
    ? `nome_cliente: ${chamar} | nome_confiavel: sim (é o único nome pelo qual você pode chamar o cliente)`
    : 'nome_cliente: — | nome_confiavel: nao (o cliente ainda não disse o nome: não chame por nome nenhum, nem por um que apareça no histórico; use "você")');
  if (dados.nome && dados.nome_provisorio && !(dados.cpf && cpfOk)) {
    L.push(`nome_a_confirmar: SIM — «${dados.nome}» veio de uma resposta solta do cliente. Ao pedir o CPF, confirme de passagem, uma vez só `
      + `("${dados.nome}, certo?"). Se ele disser que não é o nome, peça o nome completo de novo e emita [DADOS_COLETADOS] com o nome certo.`);
  }
}
L.push(`cep: ${conv.cep || '—'}${prep.cepInvalido ? ' | cep_invalido: sim (ViaCEP não achou)' : ''}${prep.viacepFalhou ? ' | endereco_do_cep indisponível agora — pergunte rua e bairro' : ''}`);
L.push(`numero: ${conv.numero || '—'} | complemento: ${conv.complemento || (dados.complemento_ok ? 'não tem' : '—')} | complemento_respondido: ${conv.complemento || dados.complemento_ok ? 'sim' : 'nao'}`);
L.push(`endereco_do_cep: ${end ? [end.logradouro, end.bairro, `${end.localidade}/${end.uf}`].filter(Boolean).join(', ') + (end.logradouro ? '' : ' (CEP geral da cidade — pergunte rua e bairro)') : '—'}`);
L.push(`cidade: ${conv.cidade || '—'} | dentro_area: ${conv.dentro_area === true ? 'SIM' : conv.dentro_area === false ? 'NAO' : 'ainda não sabemos'} | tabela_cidade: ${cluster ? cluster.toUpperCase() : '—'}`);
L.push(`dfv_resultado (uso interno, nunca citar): ${conv.dfv_resultado || '—'}`);
if (V7) {
  if (prep.ruaDivergente) L.push(`rua_divergente: SIM — o cliente escreveu «${prep.ruaDivergente.cliente}», mas o CEP ${conv.cep || prep.p_cep || ''} é da «${prep.ruaDivergente.cep}». Pergunte qual é ANTES de seguir (Passo 2).`);
  if (prep.opcoesRua) L.push(`opcoes_de_rua (busca pela rua que o cliente escreveu, sem CEP — ofereça numeradas, uma por linha, com o CEP): ${prep.opcoesRua.map((o, i) => `${i + 1}) ${o.logradouro} · ${o.bairro} · CEP ${o.cep}`).join(' | ')}`);
  if (prep.ruaSemCidade) L.push(`rua_sem_cep: o cliente passou a rua «${prep.ruaSemCidade}» sem CEP e sem cidade — pergunte a cidade (ou o CEP).`);
  if (prep.ruaNaoAchada) L.push(`rua_sem_cep: não achei a rua «${prep.ruaNaoAchada}» pelo nome — peça o CEP.`);
  // 23/11 (L-259, P48): sem endereço resolvido a Mari seguiu para nome, CPF, e-mail e pagamento. Trava no estado.
  if ((prep.ruaNaoAchada || dados.rua_nao_achada) && !conv.cep && !prep.p_cep && !prep.opcoesRua) {
    L.push('endereco_pendente: SIM — a rua do cliente ainda não foi achada. Enquanto não houver CEP, NÃO peça nome, CPF, e-mail, pagamento nem data, '
      + 'não prometa localizar o CEP você mesma e nunca diga que não dá pra buscar pelo nome da rua: peça o CEP ou o nome certinho da rua e o bairro.');
  }
  // 07/11 (correção de raiz da conversa #1): CEP achado pela rua já está gravado — a Mari só confirma, mostrando o CEP.
  if (prep.cepDaBusca) L.push(`cep_achado_pela_rua: SIM — busquei a rua «${prep.cepDaBusca.rua}» e achei UMA opção só, já gravada: ${prep.cepDaBusca.logradouro} · ${prep.cepDaBusca.bairro} · CEP ${prep.cepDaBusca.cep}. Na confirmação do endereço (Passo 2) escreva a rua, o bairro E o CEP; não peça o CEP. Se o cliente disser que não é, peça o CEP certo.`);
  if (prep.ruaPedeNumero) L.push(`rua_sem_cep: a rua «${prep.ruaPedeNumero}» tem vários CEPs, um por faixa de número — pergunte o número da casa (ou o CEP) antes de seguir; não ofereça opções de CEP.`);
  if (prep.opcoesRecusadasRua) L.push(`opcoes_de_rua_recusadas: o cliente disse que nenhuma das opções da rua «${prep.opcoesRecusadasRua}» é a dele — peça o CEP (não ofereça as mesmas opções de novo).`);
  const podeCarrossel = seg === 'varejo' && cluster === 'regular' && cartoes.length > 0;
  L.push(`planos_em_carrossel: ${podeCarrossel ? 'SIM — no Passo 3 escreva a frase de abertura e a marca [CARROSSEL_PLANOS] (sem listar os planos)' : 'NAO — lista em texto do Passo 3'}`);
  // 07/11: o histórico que o modelo lê não traz o carrossel (a marca sai, ver semMarcaInterativo) — sem isto ele dizia
  // "os planos que te mandei" sem o cliente ter recebido nada (teste real, conversa #1). Verdade do sistema, não do modelo.
  const viuCarrossel = historico.some((h) => h.papel === 'mari' && /\[carrossel:/i.test(String(h.texto || '')));
  const viuLista = historico.some((h) => h.papel === 'mari' && /^\s*\d\)\s[^\n]*R\$\s*\d/m.test(String(h.texto || '')));
  L.push(`planos_mostrados: ${viuCarrossel || viuLista
    ? `SIM (${viuCarrossel ? 'carrossel' : 'lista em texto'}) — o cliente já recebeu os planos; repita só se ele pedir ou disser que não viu`
    : 'NAO — o cliente ainda NÃO recebeu nenhum plano nesta conversa: nunca diga que já mandou planos, imagens ou opções'}`);
}
if (V4) {
  // Viabilidade oficial do portal da Nio (nível A). Em espera desde 05/11 (login BO = SSO Microsoft): sem consulta,
  // o estado diz "indisponivel" e a Mari segue a fala por cidade + DFV (Bloco 9 do prompt v4).
  const nv = conv.nio_viab_resultado || 'indisponivel';
  L.push(`nio_viab_resultado (viabilidade oficial do endereço, uso interno, nunca citar): ${nv}${conv.nio_viab_velocidade ? ` | velocidade_maxima: ${conv.nio_viab_velocidade}` : ''}`
    + (['viavel', 'posse'].includes(nv) ? '' : ' (fluxo normal: planos e cobertura pela cidade — nunca diga nem insinue que o endereço não é atendido)'));
  // 12/11 (0133, Ricardo): a decisão do operador, igual à tela Cobertura (portal decide, DFV resgata) — Bloco 9 do prompt.
  if (V7) {
    const cd = conv.cobertura_decisao || (conv.cep && conv.numero ? 'consultando' : 'sem_endereco');
    const det = conv.cobertura_detalhe || {};
    const unid = cd === 'unidade_fora_lista' && Array.isArray(det.unidades) ? det.unidades.slice(0, 12).map((u) => (typeof u === 'string' ? u : (u && (u.texto || u.nome)) || '')).filter(Boolean) : [];
    L.push(`cobertura_decisao (uso interno, nunca citar portal/sistema/consulta): ${cd}`
      + (unid.length ? ` | unidades_cadastradas: ${unid.join('; ')}` : '')
      + ` | consultas_de_endereco: ${conv.viab_consultas || 0} de 3`);
    // 24/11 (0381, B4 1.3 — opção 3 do Ricardo): no viável, a frase da cobertura leva a prova social da Nio, pelo BAIRRO da
    // viabilidade/CEP (sem bairro, "aí"). Nunca número de instalações. Vazio em config = desligado.
    const ps = String((inter.textos || {}).viabilidade_prova_social || '').trim();
    if (cd === 'viavel' && ps) {
      const bairro = String((conv.endereco_cep || {}).bairro || '').trim();
      const frasePs = ps.replace(/\{no_bairro\}/g, bairro ? `no ${bairro}` : 'aí').replace(/\{bairro\}/g, bairro || 'seu bairro');
      L.push(`prova_social_viavel: no lugar de "A Nio atende o seu endereço ✅", use esta frase quase como está (uma vez só na conversa): «${frasePs}» — e siga o passo em que a conversa está; não invente número de instalações nem cite a empresa revendedora.`);
    }
    // 16/11 (0233, Ricardo; caso "CS 1" × "Casa A"): viável no endereço, mas a unidade do cliente não está IGUAL na lista
    // fechada da Nio (ou ele não disse). A Mari mostra as opções e o cliente escolhe — nunca escolhe por ele.
    const uc = conv.unidade_conferir || {};
    // 21/11 (conversa L-222, #202): o portal consultou antes do "Casa A" chegar e abriu a conferência — mas "Casa A" está na
    // lista. A unidade do cliente que BATE com a lista não se pergunta (a Mari perguntou 2 vezes, uma no meio do chip).
    const kUn = (s) => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]/g, '');
    const unBate = !!kUn(conv.complemento) && Array.isArray(det.unidades)
      && det.unidades.some((u) => kUn(typeof u === 'string' ? u : (u && (u.texto || u.nome))) === kUn(conv.complemento));
    if (det.unidade_a_confirmar && Array.isArray(det.unidades) && conv.unidade_conferir_em && !unBate) {
      const ul = det.unidades.slice(0, 12).map((u) => (typeof u === 'string' ? u : (u && (u.texto || u.nome)) || '')).filter(Boolean);
      // 16/11 (caso Queroly, conversa 138): a viabilidade pode chegar DEPOIS dos planos (fila do operador). O sistema diz se a
      // Mari já mostrou as unidades; se não mostrou, ela pergunta NESTA resposta, em qualquer etapa (antes do próximo dado).
      const nu = (s) => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
      const jaPerguntou = historico.some((h) => h.papel === 'mari' && ul.some((u) => u && nu(h.texto).includes(nu(u))));
      L.push(uc.motivo === 'nenhuma'
        ? 'unidade_a_confirmar: o cliente JÁ disse que a unidade dele não é nenhuma da lista — o nosso time está pedindo o cadastro à Nio. NÃO pergunte de novo; siga a venda normalmente.'
        : `unidade_a_confirmar: SIM — a fibra chega no endereço, mas a unidade que o cliente deu («${conv.complemento || 'nenhuma'}») não está igual no cadastro da Nio`
          + ` | unidades_cadastradas: ${ul.join('; ')}${ul.length <= 2 && ul.every((u) => u.length <= 20) ? ' | use [BOTOES:unidade]' : ''}`
          + (jaPerguntou ? ' | ja_perguntou: SIM — não pergunte de novo; se ele não escolheu, siga (o nosso time confirma)'
            : ' | ja_perguntou: NAO — pergunte NESTA resposta, seja qual for a etapa (mesmo depois dos planos ou no meio dos dados): registre o que o cliente mandou agora e, na mesma resposta, mostre as unidades e pergunte qual é a dele'));
    }
    // 13/11 (0167, Ricardo; conversa #86, portão P30): a Mari avisou "não chega", convidou a mandar o CEP certo e o cliente voltou.
    const scAv = (conv.dados || {}).sem_cobertura_avisado;
    if (cd === 'sem_cobertura' && scAv != null && conv.cobertura_em && Number(scAv) === Math.floor(new Date(conv.cobertura_em).getTime() / 1000)) {
      L.push('sem_cobertura_cliente_voltou: SIM — você JÁ avisou que a fibra ainda não chega no endereço acima e convidou o cliente a mandar '
        + 'o CEP ou o número certo; ele voltou a escrever agora. NÃO repita o aviso, não fale de planos, não emita [HANDOFF]. '
        + 'Se ele mandou um CEP ou um número DIFERENTE do que está acima: registre na tag de endereço e diga só que vai conferir. '
        + 'Se disse que errou, repetiu o mesmo endereço ou não mandou endereço: peça, numa frase curta e gentil, o CEP (8 números) e o número da casa certos. '
        + 'Se só agradeceu ou se despediu: responda curto ("Imagina! 💚 Assim que a rede chegar aí eu te aviso.").');
    }
    // 15/11 (Ricardo, caso Lucas): o time já tratou e encerrou o lead → a Mari sabe e não reabre a venda por conta própria.
    if (conv.funil_destino && !['em_andamento', 'instalada'].includes(conv.funil_destino)) {
      L.push(`situacao_lead (uso interno): o nosso time JÁ tratou este cliente e encerrou o lead — saída "${conv.saida_motivo || conv.funil_destino}". `
        + 'Leia no histórico o que o consultor já disse e tentou (ex.: outros CPFs). NÃO repita ofertas que o time já fez nem refaça consultas. '
        + 'Responda curto e gentil ao que o cliente perguntou; se ele quiser seguir com um pedido novo ou tiver dúvida do pedido, emita [HANDOFF] pedido_humano.');
    }
    // 0138: crédito pela Mari — o sistema pede a autorização com botões e consulta sozinho; a Mari só usa o resultado (Bloco 9).
    // 0380: débito na Nio — o modelo não vê "negado" (o cliente não sabe; o time conduz)
    L.push(`credito (uso interno): ${conv.credito_resultado === 'negado_debito' ? 'em conferência com o nosso time — não comente a análise; se o cliente perguntar, "Isso o nosso time confirma quando abrir o pedido 😊"'
      : conv.credito_resultado ? `resultado=${conv.credito_resultado}${Array.isArray(conv.credito_formas) && conv.credito_formas.length ? ` (formas: ${conv.credito_formas.join(', ')})` : ''}`
      : conv.credito_em ? 'consultando' : 'ainda não consultado (sai sozinho com CPF e e-mail)'}${conv.credito_consultas >= 2 ? ' | já é a 2ª consulta (CPF do parente)' : ''}`);
    // 0383 (L-82): 'endereco' = o portal achou o pedido no ENDEREÇO (de qualquer CPF) — outro CPF da casa não resolve
    L.push(`pedido_nio_em_aberto_no_cpf (uso interno): ${conv.nio_pedido_aberto === 'sim' ? 'SIM — pergunte ao cliente (Bloco 9)'
      : conv.nio_pedido_aberto === 'endereco' ? 'SIM, NO ENDEREÇO (não no CPF) — pergunte ao cliente se o pedido é dele ou de alguém da casa (Bloco 9); NÃO ofereça outro CPF como titular: o portal trava pelo endereço'
      : conv.nio_pedido_aberto === 'nao' ? 'nao' : 'nao_consultado'}`
      + (dados.pedido_aberto_resposta ? ` | o cliente já respondeu: ${dados.pedido_aberto_resposta}` : ''));
  }
}
if (!V7 && (!conv.elegibilidade || conv.elegibilidade === 'cancelou_30d')) {   // v7: "já tem Nio" é pista, sem tabela de retorno
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
// 21/11 (Ricardo; conversa L-222, #202): a sugestão saiu e o cliente ainda não disse se fica ou troca → nada de nome/CPF agora.
if (planoSel && conv.upsell_oferecido && !dados.upsell_resposta && !(dados.cpf && cpfOk)) {
  const ac = planos.filter((o) => o.portfolio === planoSel.portfolio && o.variante === planoSel.variante && Number(o.preco) > Number(planoSel.preco)
    && Number(o.preco) - Number(planoSel.preco) <= 40).sort((a, b) => a.preco - b.preco)[0];
  if (ac) {
    L.push(`upsell_pendente: SIM — você sugeriu o ${nomeCurto(ac.nome)} e o cliente ainda NÃO disse se fica no ${nomeCurto(planoSel.nome)} ou troca. `
      + 'Responda o que ele mandou (dúvida, "não entendi": explique curto, só o plano escolhido e a diferença) e NÃO peça nome nem CPF nesta resposta — '
      + 'o sistema fecha com a pergunta "fica ou troca" e os botões. Se ele escolheu um dos dois, confirme o plano e o sistema pede os dados.');
  }
}
L.push(`dados: nome=${dados.nome || '—'}; cpf=${dados.cpf || '—'}${dados.cpf ? ` (cpf_valido: ${cpfOk ? 'SIM' : 'NAO'})` : ''}; telefone=${dados.telefone || '—'}; email=${dados.email || '—'}${dados.email && dados.email_confirmado === true ? ' (CONFIRMADO pelo cliente — nunca peça nem confirme de novo)' : ''}; pagamento=${formaTxt || '—'}; ${V4 ? `instalacao=${conv.instalacao_preferencia || (dados.instalacao_data ? `data ${dados.instalacao_data} escolhida — falta o período (o sistema manda Manhã/Tarde)` : '—')}` : `visita=${conv.visita_preferencia || '—'}`}`
  + (V7 ? `; referencia=${dados.referencia || '—'}; operadora_atual=${dados.operadora_atual || '—'}` : ''));
L.push(`dados_faltando: ${faltando.length ? faltando.join(', ') : 'nenhum'}`);
// 16/11 (caso Queroly): "Quero 800 mega 125 no cartão" já diz a forma — a Mari pedia o e-mail de novo e mandava os botões do pagamento.
if (!conv.forma_pagamento) {
  const mc = String(cons.mensagem || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  const fDita = /\b(cartao|credito)\b/.test(mc) ? 'cartao' : /\bboleto\b/.test(mc) ? 'boleto' : /\b(debito automatico|dacc)\b/.test(mc) ? 'debito' : null;
  if (fDita) L.push(`forma_dita_agora: ${fDita} — o cliente disse a forma de pagamento nesta mensagem: emita [DADOS_COLETADOS: …; pagamento=${fDita}] e NÃO mande [BOTOES:pagamento]; siga para o próximo dado que falta.`);
}
// 10/11 (rodada única): e-mail repetido para o cliente confirmar (Valdo, 09/11: e-mail errado travou o portal).
if (V7 && dados.email && dados.email_confirmado === false) {
  L.push(`email_a_confirmar: SIM — o cliente mandou «${dados.email}» e ainda não confirmou: repita o e-mail e pergunte se está certinho; não siga para o pagamento antes do "sim" (se ele corrigir, repita o novo).`);
}
// 10/11 (rodada única, Bloco 4b): quantas vezes cada objeção já foi contornada — no 3º "não" firme à mesma, despede.
if (V7) {
  const ob = dados.objecoes && typeof dados.objecoes === 'object' ? dados.objecoes : {};
  const ks = Object.keys(ob).filter((k) => Number(ob[k]) > 0);
  L.push(`objecoes_contornadas: ${ks.length ? ks.map((k) => `${k}=${ob[k]}`).join(', ') + ' (até 2 contornos por objeção; depois disso, despedida com a porta aberta)' : 'nenhuma'}`);
}
// v3 (regra de emoji): quantos emojis a Mari já usou e se o cliente usa — o 7 · Extrair aplica o teto.
const EMOJI_RE = /\p{Extended_Pictographic}/gu;
const nEmoji = (s) => (String(s || '').replace(/💚/gu, '').match(EMOJI_RE) || []).length;   // 💚 (saudação/despedida, 05/11) não conta
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
    // 10/11 (pend. 48): 11 confirmações no prompt (a confirmação repetia até 6× em 10 conversas).
    const d11 = () => 1 + Math.floor(Math.random() * 11);
    sdv._variacoes[cid] = [d6(), d6(), d11()];
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
      const m = l.match(/^\s*\d{1,2}\.\s+"(.+)"\s*$/);
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
// 08/11 (abertura B2): a saudação com botões já saiu pelo sistema e o cliente respondeu em TEXTO (sem tocar) — o Claude
// segue sem repetir a saudação; pede só o CEP (ou rua e bairro) e o número depois da cidade.
const tx0 = inter.textos || {};
// 24/11 (0386, caso L-363): o que o cliente respondeu à pergunta do "🏠 Sou cliente Nio" vale a conversa inteira (antes e depois do CEP).
if (V7 && (conv.dados || {}).abertura_botao === 'cli_outro') {
  L.push('abertura_botao: o cliente já é Nio NOUTRO endereço e tocou "Outro endereço" — quer a Nio num endereço NOVO (família, trabalho, comércio). '
    + 'Isso é VENDA normal: não trate como cliente Nio de suporte nem mande para o App/0800. Siga o fluxo de sempre para o endereço novo; '
    + 'quem confere se o endereço novo já tem Nio é a viabilidade do portal.');
} else if (V7 && (conv.dados || {}).abertura_botao === 'cli_contratar') {
  L.push('abertura_botao: o cliente tocou "Sou cliente Nio" e depois "Quero contratar" — ainda NÃO tem Nio. É venda normal: siga o fluxo de sempre.');
}
if (V7 && (conv.dados || {}).abertura && !conv.cep) {
  // 13/11 (0188): no formato 'texto' a 1ª mensagem já pediu o CEP e o número — o Claude não repete a saudação.
  const comBotoes = String((inter.textos || {}).abertura_formato || 'texto').trim() === 'botoes';
  L.push(`abertura_b2: a 1ª mensagem (${comBotoes
    ? `saudação + botões "${String(tx0.abertura_botoes || 'rua,planos,humano')}"`
    : 'saudação + pedido do CEP e do número da casa'}) JÁ FOI ENVIADA pelo sistema — `
    + 'não cumprimente de novo nem se apresente. Siga o Passo 2: peça só o CEP (ou o nome da rua e o bairro); o número da casa só depois de a cidade ser identificada.');
  // 24/11 (0381, B4): a abertura disse "a partir de R$ X" — o preço que vale é o da cidade do cliente, depois do CEP (trava BTU).
  if ((conv.dados || {}).abertura_preco) {
    const dAp = conv.dados || {};
    L.push(`abertura_preco_citado: a 1ª mensagem disse "a partir de R$ ${dAp.abertura_preco}${dAp.abertura_preco_cartao ? `, ou R$ ${dAp.abertura_preco_cartao} no cartão de crédito` : ''}" (plano de entrada${dAp.abertura_preco_cartao ? '' : ', sem o desconto do cartão'}). `
      + 'O preço que vale é SEMPRE o da cidade do cliente, que só sai depois do CEP: se a cidade dele tiver outro preço, mostre o da cidade, '
      + 'sem repetir nem comentar o da abertura. O desconto do cartão só se cita em cidade Regular, quando o cliente tiver cartão ou perguntar.');
  }
  if ((conv.dados || {}).abertura_botao === 'comercio') {
    L.push('abertura_botao: o cliente tocou "Pro comércio" — a internet é para um comércio/empresa. Siga o segmento como sempre; nada de plano, condição ou prazo que não esteja na tabela.');
  }
  // 19/11 (0328, Ricardo: "perguntar a cidade e não o CEP" no "💰 Ver os planos"): o sistema pediu a cidade e/ou já mostrou os
  // planos dela (preço da cidade), antes do CEP.
  const dAb = conv.dados || {};
  if (dAb.planos_cidade) {
    L.push(`planos_pela_cidade: o cliente JÁ VIU os planos de ${dAb.planos_cidade} com o preço da cidade, antes de dar o CEP. `
      + 'Se ele escolheu ou perguntou de um plano, registre a escolha e peça o CEP (ou a rua e o bairro) para conferir se a fibra chega na rua dele. '
      + 'Não mande os planos de novo agora e não confirme a cobertura antes do CEP.');
  } else if (dAb.abertura_pediu_cidade) {
    // 24/11 (L-276, Nelma, #241 — Ricardo: "A cidade em si já é o filtro e ela deveria descartar e encerrar o atendimento"): a linha
    // antiga mandava "confirme a cidade e peça o CEP" — a Mari pediu o CEP de Cabo Frio/RJ e ficou esperando. A cidade fora da lista
    // encerra agora (linha cidades_atendidas, abaixo); o CEP só se pede quando a cidade pode ser uma das atendidas.
    L.push('abertura_pediu_cidade: a Mari perguntou a CIDADE do cliente para mostrar os planos, e o sistema não reconheceu uma cidade atendida na resposta. '
      + 'Se ele disse uma cidade que NÃO está em cidades_atendidas, siga a linha cidades_atendidas (encerra, sem pedir CEP). '
      + 'Se o que ele disse pode ser uma das atendidas (erro de digitação, bairro ou distrito de uma delas), pergunte qual é a cidade; se não respondeu a cidade, pergunte de novo, com leveza.');
  }
}
// 24/11 (L-276): sem cidade resolvida pelo CEP, a Mari recebe a lista das cidades atendidas (config_area, nó 4c) para reconhecer,
// pelo texto, a cidade que está fora — antes ela só sabia pelo CEP e pedia o CEP de uma cidade que a gente não atende.
const cidadesAtendidas = (Array.isArray(inter.cidades) ? inter.cidades : []).map((x) => x && x.cidade).filter(Boolean);
if (V7 && !cluster && conv.dentro_area !== false && cidadesAtendidas.length) {
  // 26/11 (0417/0418, área nacional): a lista vem da config_area — as cidades ativas de todos os estados; não é mais só Minas.
  L.push(`cidades_atendidas: ${cidadesAtendidas.join(', ')} (as cidades onde a gente vende, em vários estados — a lista é do sistema). `
    + 'Se o cliente disser que o endereço da instalação é numa cidade que NÃO está nesta lista (de qualquer estado — inclusive de Minas), '
    + 'a cidade já é o filtro: NÃO peça CEP, número nem confirmação — despedida fora_de_area (Bloco 6b) com o nome da cidade '
    + 'que ele disse + handoff fora_de_area com [ELEGIBILIDADE: fora_area] e [CIDADE_DETECTADA: cidade]. '
    + 'Só pergunte antes se não der para saber a cidade (pode ser bairro ou distrito de uma da lista, nome com erro, ou ele falou de uma cidade que não é a do endereço).');
}
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
// v7: o resumo do que foi enviado como interativo ("[botões: Sim / Não]", "[carrossel: …]") fica no banco e na tela Mari,
// mas NÃO vai para o Claude — ele imitava a marca em perguntas que não são de sim/não (teste real de 06/11).
const semMarcaInterativo = (t) => String(t || '').replace(/\n*\[(?:bot[oõ]es|carrossel):[^\]]*\]/gi, '').trim();
for (const h of historico) {
  if (h.papel === 'lead') push('user', h.texto);
  else if (h.papel === 'mari') push('assistant', semMarcaInterativo(h.texto));
  else if (h.papel === 'humano') push('assistant', `[Mensagem do consultor da equipe, enviada enquanto ele atendia]\n${h.texto}`);
  else push('assistant', h.texto);
}
push('user', cons.mensagem);
while (msgs.length && msgs[0].role !== 'user') msgs.shift();
// @ensaio-inicio — corte de histórico (07/11). Config por alvo no deploy_mari.py (--historico N); fora do código da produção.
// Mantém as últimas N mensagens (começando por uma do cliente); endereço, dados e plano seguem no ESTADO_ATUAL do system.
// Sem corte (N = 0) só MEDE quanto um corte em HIST_MEDIR tiraria — a bateria converte em tokens de input novo.
const HIST_MAX = __HIST_MAX__;
const HIST_MEDIR = 6;
const corteHist = (() => {
  const n = HIST_MAX > 0 ? HIST_MAX : HIST_MEDIR;
  let ini = Math.max(0, msgs.length - n);
  while (ini > 0 && ini < msgs.length - 1 && msgs[ini].role !== 'user') ini++;
  const fora = msgs.slice(0, ini);
  const chars = (l) => l.reduce((a, m) => a + String(m.content || '').length, 0);
  const info = { n, aplicado: HIST_MAX > 0, msgsTotal: msgs.length, msgsFora: fora.length,
    charsMsgs: chars(msgs), charsFora: chars(fora), charsDinamico: dinamico.length };
  if (HIST_MAX > 0 && fora.length) msgs.splice(0, fora.length);
  return info;
})();
// @ensaio-fim

// 12/11 (0145, docs/Prompt_midia_transcricao_121126_0230.md): a FOTO da mensagem de agora vai ao Claude como imagem (link
// assinado de 15 min do bucket privado, gerado no 2b3). Só a da mensagem atual (custo); o histórico segue em texto.
// Áudio já chega transcrito no texto ("🎤 (áudio) …"). Até 3 fotos por turno.
const fotosAgora = (Array.isArray(cons.midia) ? cons.midia : [])
  .filter((m) => m && m.tipo === 'imagem' && m.url_ia && (!m.url_ia_ate || new Date(m.url_ia_ate) > new Date()))
  .slice(0, 3);
if (fotosAgora.length && msgs.length && msgs[msgs.length - 1].role === 'user') {
  const ult = msgs[msgs.length - 1];
  ult.content = [
    ...fotosAgora.map((f) => ({ type: 'image', source: { type: 'url', url: f.url_ia } })),
    { type: 'text', text: `${ult.content}\n\n[Sistema: ${fotosAgora.length > 1 ? 'as fotos acima foram enviadas' : 'a foto acima foi enviada'} pelo cliente agora. `
      + 'Use o que estiver nela (CEP ou endereço de conta de luz/água, print de anúncio, documento) para seguir o atendimento. '
      + 'Nunca repita CPF, RG, número de documento ou outro dado sensível da foto na resposta. Se não der para ler, peça para ele escrever.]' },
  ];
}

// v7 (prompt 26, spec §4): botão "Detalhes <plano>" → texto fixo do cartão, SEM chamar o Claude (o 5f leva direto ao 7).
let textoFixo = null;
if (V7) {
  const md = String(cons.mensagem || '').trim().match(/^detalhes (fibra|essencial|super|ultra)$/i);
  const FAM = { fibra: 'V-REG-FIBRA', essencial: 'V-REG-ESS', super: 'V-REG-SUP', ultra: 'V-REG-ULT' };
  const card = md && cartoes.find((k) => k.plano_codigo === FAM[md[1].toLowerCase()]);
  if (card) textoFixo = { texto: card.texto_detalhes, plano: card.plano_codigo };
}

// 08/11 (docs/Prompt_mari_abertura_b2_081126_1310.md): ABERTURA B2. 1ª mensagem da conversa → saudação fixa + 3 botões,
// SEM o Claude (o lead do anúncio sumia quando a 1ª resposta pedia CEP e número). Toque num botão dela → resposta fixa
// (rua / planos) ou humano na hora. Textos e títulos em config_mari_textos (0070) — sem 'abertura_versao' a B2 fica
// desligada e tudo segue como antes. Fica de fora (vai para o Claude, como hoje): 1ª mensagem já com CEP ou endereço,
// cliente Nio reclamando, luto, urgência, desconto, pedido de atendente, retomada de ciclo e conversa em handoff.
// 13/11 (0188): a 1ª resposta volta a PEDIR O CEP, em texto, no lugar do menu. Medido em 13/11: a saudação com
// botões não perguntava nada e 37 das 108 conversas de 14 dias nunca deram CEP (0 de 11 entre quem tocou
// "Falar com alguém"; 23 de 50 entre quem não tocou botão nenhum). 'abertura_formato' = 'botoes' em
// config_mari_textos devolve o menu sem deploy; a resposta a cada botão continua valendo (conversa antiga na tela).
const tx = inter.textos || {};
const B2 = String(tx.abertura_versao || '').trim();
const FORMATO = String(tx.abertura_formato || 'texto').trim() === 'botoes' ? 'botoes' : 'texto';
const nrm = (s) => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
const semEmoji = (s) => nrm(s).replace(/\p{Extended_Pictographic}|️|‍/gu, '').replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();
if (V7 && B2 && !textoFixo && conv.status === 'ativo') {
  // 16/11 (Ricardo, 0234): o menu é a lista 'abertura_botoes' (chaves na ordem; padrão = o de antes). Quem tocava "Falar com
  // alguém" era cliente Nio pedindo suporte e caía no backoffice → "🏠 Sou cliente Nio" (resposta fixa, sem time). "Ver os
  // planos" não mostrava plano nenhum (sem a cidade) → "🔒 Preço até 2030". Todos seguem reconhecidos (menu antigo na tela).
  const BOT_TODOS = [
    { id: 'ab:rua', chave: 'rua', title: tx.abertura_botao_rua || '📍 Ver minha rua' },
    { id: 'ab:planos', chave: 'planos', title: tx.abertura_botao_planos || '💰 Ver os planos' },
    { id: 'ab:humano', chave: 'humano', title: tx.abertura_botao_humano || '💬 Falar com alguém' },
    { id: 'ab:cliente', chave: 'cliente', title: tx.abertura_botao_cliente || '🏠 Sou cliente Nio' },
    { id: 'ab:2030', chave: 'trava2030', title: tx.abertura_botao_2030 || '🔒 Preço até 2030' },
    // 24/11 (0381, abertura B4): o 1º toque não custa nada — casa ou comércio. A resposta pede o endereço (loop aberto do mapa).
    { id: 'ab:casa', chave: 'casa', title: tx.abertura_botao_casa || '🏡 Pra minha casa' },
    { id: 'ab:comercio', chave: 'comercio', title: tx.abertura_botao_comercio || '🏪 Pro comércio' },
    // 19/11 (0328): o "rua" virou "📍 Tem na minha rua?" — o título antigo segue reconhecido (menu antigo na tela do cliente).
    { id: 'ab:rua', chave: 'rua', title: '📍 Ver minha rua' },
    // 24/11 (0386, caso L-363): a pergunta que o "🏠 Sou cliente Nio" abre — não entram no menu (abertura_botoes), só nela.
    { id: 'ab:cli_outro', chave: 'cli_outro', title: tx.abertura_botao_cli_outro || '📍 Outro endereço' },
    { id: 'ab:cli_contratar', chave: 'cli_contratar', title: tx.abertura_botao_cli_contratar || '🛒 Quero contratar' },
    { id: 'ab:cli_suporte', chave: 'cli_suporte', title: tx.abertura_botao_cli_suporte || '🔧 Suporte/fatura' },
  ];
  const BOT_AB = String(tx.abertura_botoes || 'rua,planos,humano').split(',').map((k) => BOT_TODOS.find((b) => b.chave === k.trim()))
    .filter(Boolean).slice(0, 3);
  const msgAb = String(cons.mensagem || '').trim();
  const tocado = BOT_TODOS.find((b) => semEmoji(b.title) === semEmoji(msgAb));
  const jaTemMari = historico.some((h) => h.papel === 'mari' || h.papel === 'humano');
  const dadosAb = conv.dados || {};
  if (tocado && tocado.chave === 'humano') {
    // "💬 Falar com alguém" vale a qualquer momento: humano agora (motivo pedido_humano → etiqueta handoff-humano + time).
    textoFixo = {
      texto: tx.abertura_resp_humano || 'Claro! Já chamei nosso consultor, ele te responde por aqui 💚',
      tags: { abertura: dadosAb.abertura || B2, abertura_botao: 'humano' },
      upd: dadosAb.abertura_botao ? {} : { dados: { abertura_botao: 'humano' } },
      handoff: { motivo: 'pedido_humano', lead: { dados: {}, briefing: 'Cliente tocou "💬 Falar com alguém" na abertura da Mari — chamar agora.'
        + (conv.cep ? '' : ' Ainda sem CEP/endereço.') } },
      modelo: 'abertura_b2',
    };
  } else if (tocado && tocado.chave === 'cliente') {
    // "🏠 Sou cliente Nio" → 24/11 (0386, caso L-363 — Ricardo: "Somos uma revenda e nosso interesse é exclusivo em vender"):
    // o toque NÃO dá mais a Saída. Desde 16/11, 2 de ~10 que tocaram não eram clientes Nio (L-155 tinha Claro; L-146 queria plano).
    // A Mari pergunta com 3 botões, a porta de venda primeiro; só "🔧 Suporte/fatura" grava abertura_botao = 'cliente', que é o que o
    // gatilho mari_conversas_abertura_cliente (0234/0288) espera para a Saída "Já é cliente Nio". Volta ao de antes sem deploy:
    // abertura_cliente_pergunta = 'nao' em config_mari_textos.
    const BC = ['cli_outro', 'cli_contratar', 'cli_suporte'].map((k) => BOT_TODOS.find((b) => b.chave === k));
    const corpoC = tx.abertura_resp_cliente_pergunta || 'Que bom ter você com a gente! 💚\n\nMe conta o que você precisa:\n\n📍 Nio em outro endereço (da família, do trabalho, do comércio): isso é comigo, faço agora.\n🛒 Ainda não tem Nio aí? Toca em Quero contratar.\n🔧 Fatura, suporte ou mudança de plano: quem resolve é a própria Nio, eu te passo o caminho.';
    textoFixo = String(tx.abertura_cliente_pergunta || 'sim').trim() === 'nao' ? {
      texto: tx.abertura_resp_cliente || 'Que bom ter você com a gente! 💚\n\nAqui é a central de vendas da Nio, então não consigo ver sua conta nem resolver suporte por aqui. Pra fatura, 2ª via, suporte técnico ou mudança de plano, o caminho mais rápido é o App Nio ou o 0800 001 1000.\n\nSe quiser levar a Nio pra outro endereço (da família, do trabalho), é comigo: me manda o CEP 😉',
      tags: { abertura: dadosAb.abertura || B2, abertura_botao: 'cliente' },
      upd: { dados: { abertura_botao: 'cliente' } },
      modelo: 'abertura_b2',
    } : {
      texto: null,
      interativo: { tipo: 'botoes', chave: 'abertura_cliente', corpo: corpoC.slice(0, 1024),
        botoes: BC.map((b) => ({ id: b.id, title: b.title })),
        resumo: `botões: ${BC.map((b) => b.title).join(' / ')}`,
        fallbackTexto: `${corpoC}\n\nMe responde por aqui mesmo 😊` },
      tags: { abertura: dadosAb.abertura || B2, abertura_botao: 'cliente_pergunta' },
      upd: { dados: { abertura_botao: 'cliente_pergunta' } },
      modelo: 'abertura_b2',
    };
  } else if (tocado && tocado.chave === 'cli_suporte') {
    // "🔧 Suporte/fatura": central de VENDAS — suporte é com a Nio. Sem time, sem handoff. abertura_botao = 'cliente' → o gatilho
    // mari_conversas_abertura_cliente dá a Saída "Já é cliente Nio" (para a cadência); se ele escrever de novo, a Mari responde.
    textoFixo = {
      texto: tx.abertura_resp_cli_suporte || 'Entendi! 💚 Fatura, 2ª via, suporte técnico e mudança de plano quem resolve é a própria Nio, e o caminho mais rápido é o App Nio ou o 0800 001 1000.\n\nAqui é a central de vendas, então não consigo ver a sua conta. Mas se um dia quiser a Nio em outro endereço (da família, do trabalho), é só me chamar aqui 😉',
      tags: { abertura: dadosAb.abertura || B2, abertura_botao: 'cliente' },
      upd: { dados: { abertura_botao: 'cliente' } },
      modelo: 'abertura_b2',
    };
  } else if (tocado && ['cli_outro', 'cli_contratar'].includes(tocado.chave) && !conv.cep) {
    // "📍 Outro endereço" / "🛒 Quero contratar": venda normal — pede a rua e o bairro (ou o CEP). Quem barra endereço que já tem
    // Nio é a posse na viabilidade do portal (Ricardo, 23/11), não a Mari. Com CEP já dado, o toque segue para o Claude (linha de estado).
    textoFixo = {
      texto: tocado.chave === 'cli_outro'
        ? (tx.abertura_resp_cli_outro || 'Boa! Vamos levar a Nio pra lá 😊\n\nMe manda a rua e o bairro do endereço novo (ou o CEP, se souber de cabeça) que em 1 minuto eu te digo se a fibra já passa na porta.')
        : (tx.abertura_resp_cli_contratar || 'Perfeito! 😊\n\nTô com o mapa aberto aqui — me manda a rua e o bairro (ou o CEP, se souber de cabeça) que em 1 minuto eu te digo se a fibra já passa na sua porta 😉'),
      tags: { abertura: dadosAb.abertura || B2, abertura_botao: tocado.chave },
      upd: { dados: { abertura_botao: tocado.chave } },
      modelo: 'abertura_b2',
    };
  } else if (tocado && !cluster && tocado.chave === 'planos' && seg === 'varejo' && String(tx.abertura_planos_cidade || 'sim').trim() !== 'nao') {
    // 19/11 (Ricardo, 0328): "💰 Ver os planos" antes do CEP → a Mari pergunta a CIDADE ("o CEP nem sempre o lead sabe"); a resposta
    // com a cidade mostra os planos com o preço dela (abaixo). Desliga sem deploy: abertura_planos_cidade = 'nao' (volta a pedir o CEP).
    textoFixo = {
      texto: tx.abertura_resp_planos_cidade || 'Claro! 😊 Me diz a sua cidade que eu já te mostro os planos com o preço certinho daí 👇',
      tags: { abertura: dadosAb.abertura || B2, abertura_botao: 'planos', pediu_cidade: true },
      upd: { dados: Object.assign(dadosAb.abertura_botao ? {} : { abertura_botao: 'planos' }, { abertura_pediu_cidade: true }) },
      modelo: 'abertura_b2',
    };
  } else if (!tocado && dadosAb.abertura_pediu_cidade && !dadosAb.planos_cidade && !cluster && !conv.cep && !prep.p_cep && seg === 'varejo'
    && String(tx.abertura_planos_cidade || 'sim').trim() !== 'nao' && msgAb.length <= 60) {
    // A resposta à pergunta da cidade: casa com a lista de cidades atendidas (config_area, 4c) — a mais longa que aparece inteira.
    // Regular → o carrossel (preços de config_planos pela trava de sempre); BTU → a lista em texto com o preço único da cidade.
    // Nos dois, o pedido do CEP no fim (a cobertura é da rua). Não casou → o Claude segue (linha abertura_pediu_cidade).
    const cidades = Array.isArray(inter.cidades) ? inter.cidades : [];
    const m1 = ` ${semEmoji(msgAb)} `;
    const achada = cidades.filter((x) => x && x.cidade && m1.includes(` ${semEmoji(x.cidade)} `))
      .sort((a, b) => String(b.cidade).length - String(a.cidade).length)[0];
    if (achada) {
      const pedeCep = (tx.abertura_planos_cidade_cep || 'Pra ver se a fibra chega na sua rua, me manda o CEP (ou o nome da rua e o bairro) 😊');
      const updC = { dados: { planos_cidade: achada.cidade, planos_cidade_cluster: achada.cluster } };
      const tagsC = { abertura: dadosAb.abertura || B2, abertura_botao: 'planos', cidade_planos: achada.cidade };
      const divergentes = cartoes.filter((k) => {
        const v = [...String(k.texto_card).matchAll(/R\$\s*([\d.]+,\d{2})/g)].map((m) => Number(m[1].replace(/\./g, '').replace(',', '.')));
        return v.length < 2 || v[0] !== Number(k.preco) || v[1] !== Number(k.preco_cartao);
      });
      const brl = (n) => Number(n).toFixed(2).replace('.', ',').replace(',00', '');
      const nomeP = (k) => String(k.nome || k.nome_curto || '').replace(/\s*\(.*?\)\s*/g, ' ').trim();
      const lista = (pls, comCartao) => pls.map((k, i) => `${i + 1}) ${nomeP(k)} — R$${brl(k.preco)} por mês`
        + (comCartao && k.preco_cartao != null ? ` (R$${brl(k.preco_cartao)} no cartão)` : '')).join('\n\n');
      if (achada.cluster === 'regular' && cartoes.length && !divergentes.length) {
        const corpo = `Em ${achada.cidade} são estes 👇\n\n${pedeCep}`;
        textoFixo = {
          texto: null,
          interativo: { tipo: 'carrossel', corpo: corpo.slice(0, 1024),
            cartoes: cartoes.map((k) => ({ imagem: k.imagem_url, texto: k.texto_card, botoes: [
              { id: `plano:${k.plano_codigo}:quero`, title: k.titulo_quero }, { id: `plano:${k.plano_codigo}:detalhes`, title: k.titulo_detalhes }] })),
            resumo: `carrossel: ${cartoes.map((k) => `${String(k.nome_curto || k.nome).split(' ')[0]} R$${Number(k.preco)}/${Number(k.preco_cartao)}`).join(' · ')} (${achada.cidade}, antes do CEP)`,
            fallbackTexto: `Em ${achada.cidade} são estes:\n\n${lista(cartoes, true)}\n\n${pedeCep}` },
          tags: Object.assign(tagsC, { carrossel: true }), upd: updC, modelo: 'abertura_b2',
        };
      } else {
        const pls = ((inter.planos_cidade || {})[achada.cluster] || []).slice(0, 4);
        if (pls.length) {
          textoFixo = {
            texto: `Em ${achada.cidade} os planos são:\n\n${lista(pls, achada.cluster !== 'btu')}\n\n${pedeCep}`,
            tags: tagsC, upd: updC, modelo: 'abertura_b2',
          };
        }
      }
    }
  } else if (tocado && ['casa', 'comercio'].includes(tocado.chave) && !conv.cep) {
    // 24/11 (0381, B4): "🏡 Pra minha casa" / "🏪 Pro comércio" → pede a rua e o bairro (ou o CEP). Comércio: mesma tabela vigente —
    // nada de plano, condição ou prazo de PJ inventado (regra 1); o Claude segue o segmento como sempre.
    textoFixo = {
      texto: tocado.chave === 'casa'
        ? (tx.abertura_resp_casa || 'Perfeito, residencial então.\n\nTô com o mapa aberto aqui — me manda a rua e o bairro (ou o CEP, se souber de cabeça) que em 1 minuto eu te digo se a fibra já passa na sua porta 😉')
        : (tx.abertura_resp_comercio || 'Perfeito, pro seu comércio então.\n\nTô com o mapa aberto aqui — me manda a rua e o bairro do comércio (ou o CEP, se souber de cabeça) que em 1 minuto eu te digo se a fibra já passa na porta 😉'),
      tags: { abertura: dadosAb.abertura || B2, abertura_botao: tocado.chave },
      upd: dadosAb.abertura_botao ? {} : { dados: { abertura_botao: tocado.chave } },
      modelo: 'abertura_b2',
    };
  } else if (tocado && !cluster && !/^cli_/.test(tocado.chave)) {
    // "📍 Ver minha rua" / "💰 Ver os planos": a cidade ainda não é conhecida → pede só o CEP (ou rua e bairro), sem preço.
    // Cidade já conhecida → o toque segue para o Claude (mostra os planos da cidade).
    textoFixo = {
      texto: tocado.chave === 'trava2030'
        ? (tx.abertura_resp_2030 || 'Isso mesmo! 🔒 Fechando agora, o valor do seu plano fica travado até janeiro de 2030, sem reajuste.\n\nMe manda seu CEP (ou a rua e o bairro) que eu confiro se a fibra chega aí e já te mostro o preço certinho da sua cidade 👇')
        : tocado.chave === 'rua'
        ? (tx.abertura_resp_rua || 'Oba! 🥰 Me manda só o seu CEP que eu já confiro pra você.\n\nSe não lembrar, tudo bem: pode mandar o nome da rua e o bairro 😉')
        : (tx.abertura_resp_planos || 'Claro! 😊 Os planos vão de 600 Mega a 1 Giga, com preço fixo até 2030.\n\nO valor muda um pouquinho de cidade pra cidade. Me manda seu CEP (ou a rua e o bairro) que eu te mostro os planos e preços certinhos daí 👇'),
      tags: { abertura: dadosAb.abertura || B2, abertura_botao: tocado.chave },
      upd: dadosAb.abertura_botao ? {} : { dados: { abertura_botao: tocado.chave } },
      modelo: 'abertura_b2',
    };
  } else if (!tocado && !jaTemMari && !conv.ciclo_anterior && !conv.cep && !prep.p_cep) {
    const m0 = nrm(msgAb);
    const temEndereco = /\b\d{5}-?\d{3}\b/.test(msgAb)
      || /\b(rua|r\.|avenida|av\.?|travessa|tv\.|alameda|estrada|praca|rodovia|beco|bairro)\s+[a-z]{2,}/.test(m0)
      || /\bn[º°o.]\s*\d|\bnumero\s*\d/.test(m0);
    // Regras de handoff de sempre vêm antes da abertura: quem chega reclamando, de luto, com urgência, pedindo desconto ou
    // um atendente vai para o Claude (que já sabe tratar cada caso).
    const especial = /\b(ja sou cliente|sou cliente|ja tenho (a )?nio|minha internet|sem internet|internet (caiu|parou|lenta|ruim)|caiu|parou de funcionar|reclama|cancel|suporte|tecnico|defeito|problema|fatura|segunda via|2a via|boleto|conta da nio|luto|falec|morreu|velorio|urgen|emergencia|desconto|mais barat|abatimento|atendente|humano|pessoa de verdade|falar com (alguem|uma pessoa|um atendente|o consultor|um vendedor))/.test(m0);
    if (!temEndereco && !especial) {
      // {nome} = 1º nome do contato no Chatwoot, só se parecer nome de pessoa (sem número, emoji, "Cliente", loja…).
      // 13/11: em conversa real saíram "Oi, Deus" e "Oi, Pedroernestoromaoptc". No resto do sistema
      // nome_confiavel = false quer dizer "não chame por esse nome" (o 5b avisa isso ao Claude na linha de estado);
      // só esta saudação usava o nome do WhatsApp. Na dúvida, SEM nome: "Oi, tudo bem? 😊" não custa nada,
      // e chamar alguém de "Deus" ou de um apelido colado custa a conversa. Nome de pessoa de verdade continua valendo.
      const nc = String(conv.nome_contato || '').trim();
      // A lista é comparada contra nrm(p1), que já vem sem acento: escrever sem acento ("nenem", "irmao", "vo").
      const NAO_PESSOA = new RegExp('^(' + [
        'familia', 'casa', 'eu', 'mae', 'pai', 'amor', 'vida', 'cliente', 'whatsapp', 'contato', 'teste', 'oi', 'ola',
        'nio', 'internet', 'loja', 'vendas', 'atendimento', 'suporte', 'sr', 'sra', 'dr', 'dra',
        // 13/11: o que apareceu em conversa real e o que costuma aparecer em nome de contato
        'deus', 'senhor', 'senhora', 'dona', 'dono', 'anjo', 'bebe', 'nenem', 'princesa', 'principe', 'rei', 'rainha',
        'chefe', 'boss', 'admin', 'sistema', 'robo', 'zap', 'whats', 'numero', 'pessoa', 'moca', 'rapaz',
        'amigo', 'amiga', 'irmao', 'irma', 'filho', 'filha', 'vo', 'vovo', 'vovoo', 'tio', 'tia', 'primo', 'prima',
        'sobrinho', 'sobrinha', 'neto', 'neta', 'esposa', 'esposo', 'marido', 'mulher', 'namorado', 'namorada',
        'noivo', 'noiva', 'sogro', 'sogra', 'padrinho', 'madrinha', 'patrao', 'vizinho', 'vizinha', 'colega',
        'trabalho', 'servico',
        // possessivo no 1º lugar quer dizer etiqueta, não nome ("Minha Vida", "Meu Amor") — e o apelido carinhoso
        'meu', 'meus', 'minha', 'minhas', 'nosso', 'nossa', 'nene', 'bb', 'baby', 'lindo', 'linda', 'gato', 'gata',
        'querido', 'querida', 'titio', 'titia', 'dinda', 'dindo', 'coracao', 'fofo', 'fofa',
      ].join('|') + ')$');
      const LOJA = /\b(loja|store|ltda|me|eireli|comercio|comercial|distribuidora|empresa|servicos|atacado|oficina|studio|estudio|salao|bar|lanchonete|restaurante|mercado|acougue|padaria|farmacia|igreja|escola)\b/;
      const p1 = nc.split(/\s+/)[0] || '';
      const n1 = nrm(p1);
      const pessoa = /^[A-Za-zÀ-ÿ' .-]{2,40}$/.test(nc)
        // 13/11: 1º nome de 2 a 12 letras. Era 20, e passava apelido colado ("Pedroernestoromaoptc", 20 letras);
        // nome brasileiro de verdade não passa de 12 ("Maximiliano" = 11, "Constantino" = 11).
        && /^[A-Za-zÀ-ÿ']{2,12}$/.test(p1)
        && /[aeiou]/.test(n1)                       // sem vogal não é nome ("Zzz", "Mkt")
        && !/(.)\1\1/.test(n1)                      // 3 letras iguais seguidas ("Aaaa", "Ooo")
        && !NAO_PESSOA.test(n1) && !LOJA.test(nrm(nc));
      const nome = pessoa ? p1.charAt(0).toUpperCase() + p1.slice(1).toLowerCase() : null;
      const comNome = (s) => (nome ? s.replace(/\{nome\}/g, nome) : s.replace(/,?\s*\{nome\}\s*,?\s*/g, ', ').replace(/^Oi, ,/, 'Oi,'));
      const corpo = comNome(tx.abertura_corpo || 'Oi, {nome}, tudo bem? 😊\n\nAqui é a Mari, da Nio. Fiquei feliz com sua mensagem!\n\nTe mostro rapidinho, sem compromisso nenhum. O que você prefere ver primeiro?');
      const fb = comNome(tx.abertura_fallback || 'Oi, {nome}, tudo bem? 😊\n\nAqui é a Mari, da Nio. Fiquei feliz com sua mensagem!\n\nMe manda seu CEP (ou o nome da rua e o bairro) que eu já te mostro os planos daí 😉');
      // 13/11 (0188): formato 'texto' (padrão) — saudação + pedido do CEP e do número, uma mensagem só, sem botões.
      const corpoTexto = comNome(tx.abertura_corpo_texto || 'Oi, {nome}, tudo bem? 😊 Aqui é a Mari, da Nio.\n\nMe manda seu CEP e o número da casa que eu já vejo o que tem aí pra você. Se não lembrar o CEP, pode mandar a rua e o bairro.');
      // 24/11 (0381, docs/Prompt_mari_abertura_b4_241126_1125.md): ABERTURA B4 em duas mensagens. 1ª (texto, na hora): a âncora
      // no gancho do anúncio que trouxe o lead (referral da 0057 → mari_contexto.anuncio; o pedaço _H1_/_HA_… do nome do anúncio,
      // mapa em abertura_ancora_mapa); sem referral, "Oi! Tudo bem? 👋". 2ª (botões, depois do "digitando" de abertura_pausa_s, nós
      // 12p–12r): o preço "a partir de" — SÓ com referral de um conjunto mapeado em abertura_preco_conjuntos (as cidades dele são todas
      // do mesmo cluster); o valor é o plano de varejo mais barato desse cluster em config_planos, nunca fixo (Regular: R$ 110). Sem
      // referral ou conjunto fora do mapa: o corpo SEM preço. O preço da cidade continua saindo só depois do CEP (trava de sempre).
      // Sem nome do contato (decisão de 14/11). Volta sem deploy: abertura_versao = 'b3_191126'.
      const B4 = /^b4/.test(B2) && !!tx.abertura_corpo_b4 && FORMATO === 'botoes';
      const parMapa = (s) => Object.fromEntries(String(s || '').split(',').map((x) => x.split('=').map((y) => y.trim())).filter((x) => x[0] && x[1]));
      const an = B4 && db.anuncio && db.anuncio.ad_id ? db.anuncio : null;
      const mg = an ? String(an.ad_nome || '').match(/_(H[0-9A-Z]+)_/i) : null;
      const gancho = mg ? parMapa(tx.abertura_ancora_mapa)[mg[1].toUpperCase()] || null : null;
      const ancora = an ? ((gancho && tx[`abertura_ancora_${gancho}`]) || tx.abertura_ancora_anuncio || 'Oi! Vi que você chegou pelo nosso anúncio 👋')
        : (tx.abertura_ancora_padrao || 'Oi! Tudo bem? 👋');
      const clAn = an && an.adset_id ? parMapa(tx.abertura_preco_conjuntos)[String(an.adset_id)] || null : null;
      // 24/11 16h45 (0382, docs/Prompt_mari_abertura_preco_cartao_241126_1645.md — Ricardo: "Estou de acordo"): o anúncio diz R$ 95
      // (cartão) e a abertura dizia só R$ 110. O corpo é escolhido pelo cluster do conjunto (abertura_corpo_b4_<cluster>, senão o
      // geral) e {preco_cartao_entrada} sai do mesmo plano de entrada em config_planos. Plano sem preço no cartão (Oferta 50 % da BTU)
      // com texto que pede o cartão → cai no corpo geral, sem a frase do cartão (nunca desconto de cartão em cidade BTU).
      const plsAn = clAn ? ((inter.planos_cidade || {})[clAn] || []).filter((p) => Number(p.preco) > 0) : [];
      const entAn = plsAn.length ? plsAn.reduce((a, b) => (Number(b.preco) < Number(a.preco) ? b : a)) : null;
      const precoEnt = entAn ? Number(entAn.preco) : null;
      const cartaoEnt = entAn && Number(entAn.preco_cartao) > 0 && Number(entAn.preco_cartao) < precoEnt ? Number(entAn.preco_cartao) : null;
      const brl0 = (n) => (Number.isInteger(n) ? String(n) : n.toFixed(2).replace('.', ','));
      let corpoTpl = String(tx[`abertura_corpo_b4_${clAn}`] || tx.abertura_corpo_b4 || '');
      if (/\{preco_cartao_entrada\}/.test(corpoTpl) && !cartaoEnt) corpoTpl = String(tx.abertura_corpo_b4 || '');
      if (/\{preco_cartao_entrada\}/.test(corpoTpl) && !cartaoEnt) corpoTpl = '';
      // o que a 2ª mensagem DISSE (registro + estado do Claude): sem corpo com preço, nada; cartão só se o texto o citou
      const precoDito = precoEnt && corpoTpl ? precoEnt : null;
      const cartaoDito = precoDito && cartaoEnt && /\{preco_cartao_entrada\}/.test(corpoTpl) ? cartaoEnt : null;
      const corpoB4 = precoEnt && corpoTpl ? corpoTpl.replace(/\{preco_entrada\}/g, brl0(precoEnt)).replace(/\{preco_cartao_entrada\}/g, cartaoEnt ? brl0(cartaoEnt) : '')
        : String(tx.abertura_corpo_b4_sem_preco || 'Aqui é a Mari, da Nio 😊\n\nOs planos de fibra vão de 600 Mega a 1 Giga, e o valor que você fechar agora fica travado até janeiro de 2030, sem reajuste todo ano.');
      const perguntaB4 = tx.abertura_pergunta_b4 || 'Já abri aqui o mapa da Nio pra conferir seu endereço — me diz só uma coisa antes:';
      const pedidoB4 = tx.abertura_fallback_pedido || 'Me manda a rua e o bairro (ou o CEP, se souber de cabeça) que em 1 minuto eu te digo se a fibra já passa na sua porta 😉';
      const pausaB4 = Math.max(0, Math.min(15, Number(tx.abertura_pausa_s ?? 6) || 0));
      textoFixo = B4 ? {
        texto: ancora,
        interativo: { tipo: 'botoes', chave: 'abertura', corpo: `${corpoB4}\n\n${perguntaB4}`.slice(0, 1024),
          botoes: BOT_AB.map((b) => ({ id: b.id, title: b.title })),
          resumo: `botões: ${BOT_AB.map((b) => b.title).join(' / ')}`, fallbackTexto: `${corpoB4}\n\n${pedidoB4}`, pausaS: pausaB4 },
        tags: { abertura: B2, ancora: gancho || (an ? 'anuncio' : 'padrao'), ad_id: an ? an.ad_id : null, preco_abertura: precoDito,
          preco_cartao_abertura: cartaoDito },
        upd: { dados: Object.assign({ abertura: B2 }, precoDito ? { abertura_preco: precoDito, abertura_preco_cluster: clAn } : {},
          cartaoDito ? { abertura_preco_cartao: cartaoDito } : {}) },
        modelo: 'abertura_b2',
      } : FORMATO === 'texto' ? {
        texto: corpoTexto,
        tags: { abertura: B2, abertura_formato: 'texto' },
        upd: { dados: { abertura: B2 } },
        modelo: 'abertura_b2',
      } : {
        texto: null,
        interativo: { tipo: 'botoes', chave: 'abertura', corpo: corpo.slice(0, 1024),
          botoes: BOT_AB.map((b) => ({ id: b.id, title: b.title })),
          resumo: `botões: ${BOT_AB.map((b) => b.title).join(' / ')}`, fallbackTexto: fb },
        tags: { abertura: B2 },
        upd: { dados: { abertura: B2 } },
        modelo: 'abertura_b2',
      };
    }
  }
}

return [{ json: {
  model: MODEL, maxTokens: MAX_TOKENS, system, messages: msgs,
  fixo: textoFixo,
  ctx: {
    carrossel: V7 && seg === 'varejo' && cluster === 'regular' && cartoes.length > 0,
    inter,
    conversaId: conv.id, t0: Date.now(), promptVersao: conteudo.promptVersao,
    cluster, btu, dentroArea: conv.dentro_area, dentroHorario, segmento: seg,
    planos: planos.map((p) => ({ codigo: p.codigo, nome: p.nome, portfolio: p.portfolio, variante: p.variante, preco: p.preco, preco_cartao: p.preco_cartao,
      taxa_habilitacao: p.taxa_habilitacao, isencao_meses: p.isencao_meses,
      velocidade_mb: p.velocidade_mb, wifi: p.wifi })),   // 10/11: o roteador das condições vem do plano (Wi-Fi 5 / Wi-Fi 6)   // 0030/prompt 18: bloco [CONDICOES]; 07/11: trava de valor/plano fora da tabela (7 · Extrair)
    conversa: { etapa: conv.etapa, cep: conv.cep, numero: conv.numero, complemento: conv.complemento, cidade: conv.cidade,
      elegibilidade: conv.elegibilidade, plano_escolhido: conv.plano_escolhido, forma_pagamento: conv.forma_pagamento,
      visita_preferencia: conv.visita_preferencia, instalacao_preferencia: conv.instalacao_preferencia,
      nio_viab_resultado: conv.nio_viab_resultado, nio_viab_velocidade: conv.nio_viab_velocidade, nio_viab_interesse_id: conv.nio_viab_interesse_id,
      dados, dfv_resultado: conv.dfv_resultado, lgpd_enviada: conv.lgpd_enviada,
      nome_contato: conv.nome_contato, telefone: conv.telefone, mei: conv.mei,
      // 12/11 (0133): decisão do operador e pedido Nio em andamento — o 7 · Extrair decide/anota com eles (portão P27/P28)
      cobertura_decisao: conv.cobertura_decisao, cobertura_em: conv.cobertura_em, cobertura_detalhe: conv.cobertura_detalhe, nio_pedido_aberto: conv.nio_pedido_aberto,
      unidade_conferir: conv.unidade_conferir, unidade_conferir_em: conv.unidade_conferir_em,   // 16/11 (0233): unidade a confirmar
      nome_confiavel: conv.nome_confiavel,
      // 0138: crédito pela Mari (autorização do titular gravada → n8n mari_credito)
      credito_autorizado_em: conv.credito_autorizado_em, credito_autorizacao_frase: conv.credito_autorizacao_frase,
      credito_recusado_em: conv.credito_recusado_em, credito_resultado: conv.credito_resultado, credito_formas: conv.credito_formas, credito_consultas: conv.credito_consultas,
      // 15/11 (handoff curto): o 7 · Extrair escreve na nota se o crédito está em andamento e em que endereço foi lido (0204)
      credito_em: conv.credito_em, credito_endereco: conv.credito_endereco,
      venda_id: conv.venda_id || null,   // 24/11 (L-82): já tem venda = o quadro de condições já saiu (o histórico do motor é só o recente)
      status: conv.status },
    primeira,   // 💚 na saudação (7 · Extrair)
    // v7: trava das condições (fechamento obrigatório da Nio) — já saíram nesta conversa?
    // 10/11: frase nova do bloco ("As condições do seu plano:"); a antiga vale para as conversas de antes.
    condicoesEnviadas: historico.some((h) => h.papel === 'mari' && /Antes de fechar, rapidinho as condições|As condições do seu plano:/.test(String(h.texto || ''))),
    turnoIds: cons.turno_ids || [],
    estado: estadoTxt,
    emojiMari, emojiCliente,
    // @ensaio-inicio
    corteHist,
    // @ensaio-fim
  },
} }];
