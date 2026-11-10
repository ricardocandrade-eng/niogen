/* NIOGEN | docs/assets/app.js | 03/11/2026 · 04/11 componentes do padrão de telas (período, KPIs, abas, ordenação, gaveta)
 * Cliente Supabase, sessão, rótulos do funil, formatação e componentes comuns (toast, modais).
 * Depende de: config.js (window.NIOGEN_CONFIG) e supabase-js v2 (window.supabase), carregados antes.
 */
(function () {
  'use strict';

  // Limpa BOM, espaço e quebra de linha que um secret mal gravado deixa na chave (vira erro de header no fetch).
  const limpa = (s) => String(s || '').replace(/[^\x21-\x7E]/g, '');
  const cfg = { supabaseUrl: limpa((window.NIOGEN_CONFIG || {}).supabaseUrl), supabaseAnonKey: limpa((window.NIOGEN_CONFIG || {}).supabaseAnonKey) };
  if (!cfg.supabaseUrl || !cfg.supabaseAnonKey) {
    document.addEventListener('DOMContentLoaded', () => {
      document.body.innerHTML = '<div class="login"><div class="login-box"><strong>config.js ausente</strong>' +
        '<span class="painel-sub">Copie docs/config.example.js para docs/config.js e preencha a URL e a chave anon do Supabase Nio.</span></div></div>';
    });
    throw new Error('NIOGEN: config.js ausente');
  }

  const sb = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey, {
    auth: { persistSession: true, autoRefreshToken: true },
  });

  const TZ = 'America/Sao_Paulo';

  const STATUS = [
    // 0089 (Ricardo, 09/11): UMA jornada de 5 etapas com os mesmos nomes em toda tela. Os ids do banco não mudam:
    // 0_qualificado é a etapa 2 (sem pedido) ou a 3 (com pedido) — quem separa é etapaDe(venda). Venda = OS aberta (0096); o agendamento vem depois.
    { id: '0_qualificado', curto: 'Lead qualificado', col: 'Lead qualificado (ainda não é venda)', chip: 'info' },
    { id: '1_vendido', curto: 'Ativação/Agenda', col: 'Ativação/Agenda', chip: '', oculto: true },
    { id: '2_aguardando_instalacao', curto: 'Ativação/Agenda', col: 'Ativação/Agenda', chip: '' },
    { id: '3_instalado', curto: 'Instalada', col: 'Instalada', chip: 'ok' },
    { id: '4_ativo_provisorio', curto: 'Instalada', col: 'Instalada', chip: 'ok', oculto: true },
    { id: '5_comissao_firme', curto: 'Instalada', col: 'Instalada', chip: 'ok', oculto: true },
    { id: 'saida', curto: 'Saída', col: 'Saída · motivo obrigatório', chip: 'dim' },
  ];
  const STATUS_MAP = Object.fromEntries(STATUS.map((s) => [s.id, s]));

  // A jornada (0089; nomes do Ricardo 09/11 ~23h55): 1 Conversa · 2 Lead qualificado · 3 Biometria · 4 Ativação/Agenda · 5 Instalada · Saída.
  // A etapa 1 (conversa sem venda) não tem venda: aparece só na Minha vez (v_jornada). Ids curtos ficam nas URLs.
  const JORNADA = [
    { n: 1, id: 'conversa', nome: 'Conversa', cor: '#6B8AFD' },
    { n: 2, id: 'qualificado', nome: 'Lead qualificado', cor: '#5FB3F9' },
    { n: 3, id: 'pedido', nome: 'Biometria', cor: '#E3B341' },
    { n: 4, id: 'vendido', nome: 'Ativação/Agenda', cor: '#32E000' },
    { n: 5, id: 'instalado', nome: 'Instalada', cor: '#2EA043' },
  ];
  const ETAPAS = [
    { id: 'qualificado', n: 2, nome: 'Lead qualificado', status: ['0_qualificado'] },
    { id: 'pedido', n: 3, nome: 'Biometria', status: ['0_qualificado'] },
    { id: 'vendido', n: 4, nome: 'Ativação/Agenda', status: ['1_vendido', '2_aguardando_instalacao'] },
    { id: 'instalado', n: 5, nome: 'Instalada', status: ['3_instalado', '4_ativo_provisorio', '5_comissao_firme'] },
    { id: 'saida', n: 0, nome: 'Saída', status: ['saida'] },
  ];
  // etapaDe(venda) — com a venda separa a etapa 2 da 3 pelo nº do pedido; com só o status, 0_qualificado = Lead qualificado.
  const etapaDe = (x) => {
    const obj = x && typeof x === 'object';
    const st = obj ? x.status : x;
    if (st === '0_qualificado') return obj && (x.jornada_etapa === 3 || String(x.nio_pedido || '').trim()) ? ETAPAS[1] : ETAPAS[0];
    return ETAPAS.find((e) => e.status.includes(st)) || { id: '', n: null, nome: st || '—', status: [] };
  };
  // ---------- v_jornada (0090): a regra única de "precisa de ação" ----------
  // nivel do banco → cor das telas: agora = vermelho · hoje = amarelo · espera = azul (terceiro) · ok/fora = cinza.
  const NIVEL_COR = { agora: 'bad', hoje: 'warn', espera: 'espera', ok: 'ok', fora: 'dim' };
  async function jornada() {
    const { data, error } = await sb.from('v_jornada').select('*');
    if (error) return { erro: msgErro(error), lista: [], porVenda: {}, porConversa: {} };
    const lista = (data || []).filter((j) => j.etapa > 0);
    return {
      lista, todas: data || [],
      porVenda: Object.fromEntries((data || []).filter((j) => j.venda_id).map((j) => [j.venda_id, j])),
      porConversa: Object.fromEntries((data || []).filter((j) => j.conversa_id).map((j) => [j.conversa_id, j])),
    };
  }
  // Linha da v_jornada → o mesmo formato do proximoPasso ({txt, nivel, acao, espera}).
  const passoJornada = (j) => (j ? { txt: j.o_que_fazer, nivel: NIVEL_COR[j.nivel] || 'dim', acao: !!j.precisa_acao, espera: j.nivel === 'espera', botao: j.botao } : null);
  const ordemJornada = (a, b) => (({ agora: 0, hoje: 1, espera: 2, ok: 3, fora: 4 })[a.nivel] - ({ agora: 0, hoje: 1, espera: 2, ok: 3, fora: 4 })[b.nivel])
    || (new Date(a.desde || 0) - new Date(b.desde || 0));

  const ORIGENS = {
    meta_ads: 'Meta Ads · Mari', instagram: 'Instagram · Mari', facebook: 'Facebook · Mari', fila_vero: 'Fila Vero', rua: 'Rua / PAP',
    indicacao: 'Indicação', site: 'Site', outro: 'Evento / outro', parceiro_pap: 'Parceiro PAP',
  };
  // Origem para exibir: "Parceiro PAP · <nome>" (o nome vem de v_funil.parceiro_nome; o vendedor não lê a tabela parceiros e vê só "Parceiro PAP").
  const origemTxt = (v) => {
    if (!v) return '—';
    if (v.origem === 'parceiro_pap') return v.parceiro_nome ? `Parceiro PAP · ${v.parceiro_nome}` : 'Parceiro PAP';
    return ORIGENS[v.origem] || v.origem || '—';
  };
  // ---------- Programa Parceiro PAP (prompt 25): rótulos únicos das telas ----------
  const PARCEIRO_STATUS = { aguardando: 'Aguardando aprovação', ativo: 'Ativo', suspenso: 'Suspenso', desligado: 'Desligado' };
  const PARCEIRO_FORMA = { diario: 'Diário', quinzenal: 'Quinzenal' };
  // Lista fechada da conferência (check vendas_conferencia_motivo_check, 0038). O parceiro vê estes rótulos (F4).
  const MOTIVOS_CONFERENCIA = {
    cliente_nao_confirmou: 'Cliente não confirmou a compra', cliente_nao_atende: 'Cliente não atende', dados_divergentes: 'Dados divergentes',
    sem_cobertura: 'Sem cobertura', fora_da_area: 'Fora da área de atuação', ja_cliente_nio: 'Já é cliente Nio',
    ja_tem_pedido_nio: 'Já tem pedido na Nio', cancelou_30d: 'Cancelou a Nio há menos de 30 dias', suspeita_fraude: 'Suspeita de fraude', outro: 'Outro motivo',
  };
  const CONFERENCIA_STATUS = { pendente: 'Em conferência', aprovada: 'Aprovada', reprovada: 'Reprovada', devolvida: 'Devolvida ao parceiro' };
  const PAGAMENTO_TIPO = { comissao: 'Comissão', incentivo_quinzenal: 'Incentivo quinzenal', premio_degrau: 'Prêmio de degrau', bonus_boas_vindas: 'Bônus de boas-vindas' };
  const PAGAMENTO_STATUS = { previsto: 'Previsto', pago: 'Pago', cancelado: 'Cancelado' };
  const FORMAS = { boleto: 'Boleto', cartao: 'Cartão', dacc: 'DACC' };
  const SEGMENTOS = { PF: 'PF · Varejo', MEI: 'PJ · MEI', NMEI: 'PJ · NMEI' };
  // Venda remota (05/11): não existe biometria em campo. A própria Nio manda o LINK ao cliente (WhatsApp + e-mail) na hora
  // em que o pedido é aberto no portal (prompt 19); o portal mostra Pendente · com Risco · Validada. "Não enviada" = sem pedido.
  const BIOMETRIA = { nao_enviada: 'sem pedido (link ainda não saiu)', pendente: 'pendente (link enviado pela Nio)', com_risco: 'com risco', validada: 'validada' };
  const CREDITO = { pendente: 'pendente (24 h)', aprovado: 'aprovado', so_cartao: 'aprovado só no cartão', negado: 'negado' };
  // Viabilidade oficial do portal (nível A em espera: hoje registrada à mão na ficha). Nunca nega venda sozinha (05/11 10h05):
  // ≠ viável = conferir manualmente no portal (variações de CEP/rua/número); quem decide sem cobertura é o humano.
  const VIAB_NIO = { viavel: 'Viável', sem_viabilidade: 'Sem viabilidade', nao_encontrado: 'Endereço não encontrado', posse: 'Endereço já tem Nio (posse)', indisponivel: 'Portal não respondeu' };
  const PORTAL_PAP_NOVO_PEDIDO = 'https://pap.niointernet.com.br/administrativo/novo-pedido';
  // 06/11 (prompt 27): os 4 estados que o backoffice registra na ficha ("Não consultado" = nada gravado).
  const VIAB_PORTAL_REGISTRO = { viavel: 'Viável', sem_viabilidade: 'Sem viabilidade', nao_encontrado: 'Endereço não encontrado' };
  const fmtCep = (c) => { const d = String(c || '').replace(/\D/g, ''); return d.length === 8 ? `${d.slice(0, 5)}-${d.slice(5)}` : (d || '?'); };
  // Trava 0 → 1 (0048): só o portal libera — Viável e com menos de 7 dias.
  const portalViavel = (v) => !!v && v.nio_viab_resultado === 'viavel' && !!v.nio_viab_em && (Date.now() - new Date(v.nio_viab_em)) < 7 * 86400000;

  // ---------- ajuda ao passar o mouse (prompt 27) ----------
  // Um único dicionário: o que é e o que fazer. Tela Mari, ficha e menu usam daqui (title= + ⓘ via NG.dicaTxt).
  const ajuda = {
    // situação da conversa
    sit_andamento: 'Em andamento: a Mari ainda está conversando com o cliente. Nada a fazer — acompanhe pela conversa.',
    sit_qualificada: 'Qualificada: a Mari juntou os dados e passou para o time (a venda nasceu em 0 · Qualificado). Próximo passo: consultar a viabilidade no portal e abrir o pedido.',
    sit_humano: 'Precisa de humano: a Mari parou e pediu alguém do time (pedido do cliente, objeção, urgência, cliente Nio reclamando). Responda pelo Chatwoot.',
    sit_encerrada: 'Encerrada: a conversa terminou sem venda (recusa, fora de área, sem contato…). Nada a fazer, a não ser que o cliente volte.',
    sit_venda: 'A situação vem da venda que a Mari criou: a etapa atual dela em Vendas (Qualificado, Vendido…) ou a Saída com o motivo. Abra a venda para ver o próximo passo.',
    // Chatwoot
    cw_aresolver: 'A resolver: a conversa está aberta no Chatwoot (aberta ou pendente). Alguém do time precisa responder ou resolver.',
    cw_resolvida: 'Resolvida: a conversa foi fechada no Chatwoot. Se o cliente escrever de novo, ela reabre e a Mari volta a atender.',
    cw_adiada: 'Adiada: a conversa foi adiada (snooze) no Chatwoot e volta sozinha na data marcada.',
    cw_atribuida: 'Quem está com a conversa no Chatwoot (agente e/ou time). Sem ninguém atribuído, a Mari responde; com alguém, ela fica quieta.',
    cw_etiquetas: 'Etiquetas da conversa no Chatwoot. handoff = a Mari passou para o time · handoff-venda = dados completos, abrir o pedido · handoff-humano = alguém precisa responder já · nao-contatar = a Mari e a cadência param.',
    cw_sync: 'Quando o NIOGEN leu o status do Chatwoot pela última vez.',
    // colunas e indicadores da tela Mari
    col_contato: 'Nome que o cliente informou à Mari ou, antes disso, o nome do perfil do WhatsApp (sem nome, o telefone), e a origem da conversa (anúncio, Instagram, Facebook…).',
    col_local: 'Bairro e cidade do endereço que o cliente passou.',
    col_situacao: 'Uma situação por conversa. Com venda criada, é a etapa da venda; sem venda, é o ponto em que a Mari está.',
    col_chatwoot: 'Status no Chatwoot (A resolver / Resolvida), quem está atribuído e as etiquetas.',
    col_plano: 'Plano e forma de pagamento que o cliente escolheu na conversa.',
    col_valor: 'Valor mensal do plano na forma de pagamento escolhida (tabela vigente).',
    col_proximo: 'O que fazer agora. Vermelho = atrasado ou com erro · amarelo = hoje · cinza = esperando o cliente.',
    col_ultima: 'Há quanto tempo foi a última mensagem (do cliente ou da Mari).',
    etapa: 'Etapa da Mari na conversa: abertura → endereço → elegibilidade → planos → coleta → resumo → handoff. Retomada = o time devolveu a conversa para ela.',
    origem: 'De onde o cliente veio: (IG) = link do Instagram, (FB) = botão da página, "Vi o anúncio" = Meta Ads, sem marca = direto.',
    dfv_pista: 'DFV = foto da base da Nio (03/11). É só uma pista: "não achou" pode ser endereço escrito diferente. Quem decide a viabilidade é o portal PAP.',
    // ficha · viabilidade e portal
    viab_portal: 'Viabilidade oficial: o resultado da consulta do endereço no portal PAP (etapa 2 do Novo Pedido). Só "Viável" com menos de 7 dias libera a venda.',
    viab_consultar: 'Abre o portal PAP numa aba nova e copia "CEP número" para colar na busca de viabilidade.',
    viab_registrar: 'Depois de consultar no portal, registre aqui o que ele respondeu. Fica gravado com a data e quem registrou.',
    portal_dados: 'Tudo o que o portal pede no Novo Pedido, na ordem das etapas. Copie campo a campo ou tudo de uma vez. Em vermelho = falta (peça ao cliente antes de abrir o pedido).',
    // cadência (prompt 28)
    cad_bolinhas: 'Cadência da Mari: F1 (~1 h) e F2 (~4 h) no mesmo dia, dentro da janela de 24 h; depois D3, D7 e D15 por template. Acesa = enviada · piscando = próxima · apagada = futura. Passe o mouse em cada uma para ver o texto exato. Nunca mais de 2 toques por dia e 15 por mês; nunca domingo/feriado. Sem resposta 48 h depois do D15, a conversa SEM venda se encerra sozinha; venda criada nunca sai sozinha.',
    cad_avisos_venda: 'Avisos automáticos da Mari para esta venda: BIO1 = lembrete da biometria no D+1 do pedido · BIO3 = no D+3 sem biometria o nosso time liga (não é mensagem) · INSTALACAO = aviso assim que a instalação é agendada · VESPERA = lembrete na véspera. Passe o mouse para ver o texto.',
    interesse_futuro: 'Interesse futuro: a venda está em Saída e o cliente pediu para voltarmos a falar na data. A conversa ganha a etiqueta interesse-futuro no Chatwoot e uma nota privada com a data; o backoffice retoma por lá. A cadência não manda nada para ela.',
    // menu lateral
    menu_mari: 'Conversas esperando alguém do time: handoff da Mari, A resolver no Chatwoot e a última mensagem é do cliente. Vermelho = alguma passou de 15 min em horário de contato.',
    menu_vendas: 'Vendas novas em 0 · Qualificado desde a última vez que você abriu Vendas, mais as que precisam de ação (venda em espera só conta na data de revisão).',
    // pendência com terceiro (0064)
    pendencia: 'Em espera: a venda depende de um terceiro (Nio, Rogério, cliente) e fica na etapa com o motivo e a data de revisão. Sai de "Precisam de ação" até a data; na data volta em vermelho para todos. A cadência da Mari fica pausada. Só admin/backoffice abre e encerra.',
  };
  const opcoes = (mapa, atual, vazio = '—') => `<option value="">${vazio}</option>${Object.entries(mapa).map(([k, t]) => `<option value="${k}" ${atual === k ? 'selected' : ''}>${t}</option>`).join('')}`;
  const PERFIS = { admin: 'Admin', vendedor: 'Vendedor', backoffice: 'Backoffice' };

  const MOTIVOS_SAIDA = [
    'Sem cobertura', 'Já é cliente Nio', 'Concorrente', 'Preço', 'Sem contato (cadência esgotada)',
    'Desistiu', 'Reprovado na biometria', 'Crédito negado', 'Fora da área', 'Interesse futuro (com data)',
  ];

  // ---------- formatação ----------
  const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const dt = (v) => (v ? new Date(v) : null);
  const parts = (d, opts) => new Intl.DateTimeFormat('pt-BR', { timeZone: TZ, ...opts }).format(d);
  const fmtData = (v) => (v ? parts(dt(v), { day: '2-digit', month: '2-digit' }) : '—');
  const fmtDataAno = (v) => (v ? parts(dt(v), { day: '2-digit', month: '2-digit', year: 'numeric' }) : '—');
  const fmtHora = (v) => (v ? parts(dt(v), { hour: '2-digit', minute: '2-digit' }) : '—');
  const fmtDataHora = (v) => (v ? `${fmtData(v)} ${fmtHora(v)}` : '—');
  const fmtDiaSemana = (v) => (v ? parts(dt(v), { weekday: 'short' }).replace('.', '') : '');
  const fmtMoeda = (v) => (v == null ? '—'
    : 'R$ ' + Number(v).toLocaleString('pt-BR', { minimumFractionDigits: Number(v) % 1 ? 2 : 0, maximumFractionDigits: 2 }));
  // Coluna date do banco (AAAA-MM-DD) → DD/MM/AAAA, sem passar por Date (evita virar o dia anterior no fuso).
  const fmtDiaISO = (v) => (v ? String(v).slice(0, 10).split('-').reverse().join('/') : '—');
  const fmtNum = (v) => (v == null ? '—' : Number(v).toLocaleString('pt-BR', { maximumFractionDigits: 0 }));
  const fmtHoras = (h) => {
    if (h == null) return '—';
    const t = Math.max(0, Math.round(Number(h) * 60));
    return `${Math.floor(t / 60)}h${String(t % 60).padStart(2, '0')}`;
  };
  // Data (AAAA-MM-DD) no fuso de São Paulo.
  const diaSP = (v) => parts(v ? dt(v) : new Date(), { year: 'numeric', month: '2-digit', day: '2-digit' }).split('/').reverse().join('-');
  const diasEntre = (a, b) => Math.floor((dt(b) - dt(a)) / 86400000);
  // Janela de instalação: o horário gravado indica o período (antes do meio-dia = manhã).
  const janela = (v) => (v ? (Number(parts(dt(v), { hour: '2-digit', hour12: false })) < 12 ? '8–12h' : '13–17h') : '');
  const primeiroNome = (nome) => {
    const p = String(nome || '').trim().split(/\s+/);
    return p.length > 1 ? `${p[0]} ${p[p.length - 1][0]}.` : p[0] || '—';
  };

  // ---------- validação ----------
  function cpfValido(cpf) {
    const s = cpf.replace(/\D/g, '');
    if (s.length !== 11 || /^(\d)\1+$/.test(s)) return false;
    let d = 0;
    for (let i = 0; i < 9; i++) d += Number(s[i]) * (10 - i);
    d = (d * 10) % 11 % 10;
    if (d !== Number(s[9])) return false;
    d = 0;
    for (let i = 0; i < 10; i++) d += Number(s[i]) * (11 - i);
    d = (d * 10) % 11 % 10;
    return d === Number(s[10]);
  }
  function cnpjValido(cnpj) {
    const s = cnpj.replace(/\D/g, '');
    if (s.length !== 14 || /^(\d)\1+$/.test(s)) return false;
    const calc = (len) => {
      const pesos = len === 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
      const soma = pesos.reduce((acc, p, i) => acc + Number(s[i]) * p, 0);
      const r = soma % 11;
      return r < 2 ? 0 : 11 - r;
    };
    return calc(12) === Number(s[12]) && calc(13) === Number(s[13]);
  }
  const documentoValido = (v) => {
    const n = String(v || '').replace(/\D/g, '');
    return n.length === 11 ? cpfValido(n) : n.length === 14 ? cnpjValido(n) : false;
  };
  const soDigitos = (v) => String(v || '').replace(/\D/g, '');

  // ---------- erros e toasts ----------
  function msgErro(e) {
    if (!e) return 'Erro desconhecido';
    const m = e.message || String(e);
    if (/duplicate key.*nio_pedido/i.test(m)) return 'Esse nº de pedido já está em outra venda.';
    if (/parceiros_cpf_unico/i.test(m)) return 'Já existe um parceiro com esse CPF.';
    if (/parceiros_whatsapp_unico/i.test(m)) return 'Já existe um parceiro com esse WhatsApp.';
    if (/row-level security/i.test(m)) return 'Sem permissão para essa venda ou operação.';
    return m;
  }
  function toast(texto, tipo) {
    let box = document.querySelector('.toasts');
    if (!box) {
      box = document.createElement('div');
      box.className = 'toasts';
      box.setAttribute('role', 'status');
      box.setAttribute('aria-live', 'polite');
      document.body.appendChild(box);
    }
    const el = document.createElement('div');
    el.className = 'toast' + (tipo ? ' ' + tipo : '');
    el.textContent = texto;
    box.appendChild(el);
    setTimeout(() => el.remove(), tipo === 'bad' ? 7000 : 4000);
  }

  // ---------- botão "Atualizar" (09/11, pedido do Ricardo): busca dados frescos sem F5 ----------
  // Uso: NG.botaoAtualizar(() => carregar()) depois do login. Entra no começo de .cab-acoes (ou em opts.alvo), gira enquanto
  // busca, não deixa clicar duas vezes e também refaz os contadores do menu (NGSidebar.avisos). Filtros, aba e vista ficam.
  function botaoAtualizar(fn, { alvo } = {}) {
    const box = alvo || document.querySelector('.cab .cab-acoes');
    if (!box) return null;
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'btn btn-atualizar';
    b.title = 'Buscar os dados de novo, sem recarregar a página';
    b.innerHTML = '<span class="ico" aria-hidden="true">↻</span><span class="txt">Atualizar</span>';
    b.addEventListener('click', async () => {
      if (b.classList.contains('girando')) return;
      b.classList.add('girando');
      b.setAttribute('aria-busy', 'true');
      try {
        await Promise.all([fn(), window.NGSidebar && NGSidebar.avisos ? NGSidebar.avisos() : null]);
        const h = fmtHora(new Date().toISOString());
        b.title = `Atualizado às ${h} — clique para buscar de novo`;
        toast(`Atualizado às ${h}`, 'ok');
      } catch (e) {
        toast(msgErro(e), 'bad');
      } finally {
        b.classList.remove('girando');
        b.removeAttribute('aria-busy');
      }
    });
    box.prepend(b);
    return b;
  }

  // ---------- fluxo único do backoffice (0082): um botão por momento; o banco grava a venda e enfileira o Chatwoot ----------
  // momento: assumir · viabilidade · pedido · biometria · agendar · parar · devolver_mari. vendaId pode ser null quando
  // dados.conversa_id vem (conversa sem venda: assumir/parar/devolver). Devolve o jsonb da RPC ({resumo, aviso, …}) ou null.
  const MOMENTOS = {
    assumir: 'Assumida', viabilidade: 'Viabilidade registrada', pedido: 'Pedido gravado', biometria: 'Biometria',
    os: 'OS aberta (venda)', agendar: 'Instalação agendada', os_agendar: 'OS + agendamento (venda)', reagendar: 'Instalação reagendada', parar: 'Cliente pediu para parar', devolver_mari: 'Devolvida para a Mari',
  };
  async function momento(vendaId, qual, dados = {}) {
    const { data, error } = await sb.rpc('backoffice_momento', { p_venda: vendaId || null, p_momento: qual, p_dados: dados || {} });
    if (error) { toast(msgErro(error), 'bad'); return null; }
    toast(data.aviso ? `${data.resumo} · ${data.aviso}` : data.resumo, data.aviso ? 'bad' : 'ok');
    if (window.NGSidebar && NGSidebar.avisos) NGSidebar.avisos();
    return data;
  }

  // Fila "Minha vez": desde a 0090 vem inteira da v_jornada (NG.jornada) — a mesma regra do menu, do Funil, do Painel e da Mari.

  // ---------- comissão: prevista / paga · M-10 · downgrade ----------
  // Único lugar dos textos de explicação (Funil, Venda, Painel, Vendas e Tabela usam daqui).
  // Desde 04/11 (decisão do Ricardo no padrão de telas) a comissão aparece só como "prevista" (antes do pagamento) ou
  // "paga" (no extrato). As regras de estorno (Rogério + contrato, 04/11) seguem no banco e na Tabela e política.
  const TEXTOS_COMISSAO = {
    // Contrato, Anexo I 1.2.2.2 (texto do Ricardo, 04/11).
    m10: 'Apurado no 11º mês após a ativação, se o cliente seguir ativo até o fim do 10º mês, com todas as faturas emitidas até lá pagas '
      + '(nenhuma com mais de 15 dias de atraso) e sem downgrade. Não entra na comissão prevista.',
    m10Nao: (motivo) => `Não elegível ao bônus M-10: ${motivo}.`,
    downgrade: (ate) => `Downgrade até ${ate} desconta só a diferença de comissão.`,
  };
  const textoComissao = (chave, arg) => {
    const t = TEXTOS_COMISSAO[chave];
    return typeof t === 'function' ? t(arg) : t;
  };
  // Rótulo com explicação: title= no desktop; o ⓘ abre o mesmo texto ao tocar (celular).
  function dicaTxt(texto) {
    const t = esc(texto);
    return `<button type="button" class="dica" data-dica="${t}" title="${t}" aria-label="O que é isso?">ⓘ</button>`;
  }
  function dica(chave, arg) { return dicaTxt(textoComissao(chave, arg)); }
  function rotulo(texto, chave, arg) {
    return `<span class="com-rot" title="${esc(textoComissao(chave, arg))}">${esc(texto)}</span>${dica(chave, arg)}`;
  }
  // Aviso de downgrade (venda instalada/ativa, até ativação + 180 d).
  function avisoDowngrade(v) {
    if (!v || !v.downgrade_ate || !['3_instalado', '4_ativo_provisorio', '5_comissao_firme'].includes(v.status)) return '';
    if (new Date(v.downgrade_ate) <= new Date()) return '';
    return textoComissao('downgrade', fmtData(v.downgrade_ate));
  }

  // ---------- DFV Nio (nível 1: consulta manual registrada na venda) ----------
  // Único lugar dos textos do DFV (venda de rua, Venda, Funil e Painel usam daqui).
  const DFV_OPCOES = {
    nao_consultado: 'Não consultado',
    viavel: 'Viável',
    viavel_predio: 'Viável (prédio — unidade confirma no portal)',
    sem_viabilidade: 'Sem viabilidade',
    nao_encontrado: 'Endereço não encontrado',
  };
  const TEXTOS_DFV = {
    regra: 'O portal PAP dá a palavra final (viabilidade oficial no pedido). Nunca dizer ao cliente "cobertura confirmada" com base no DFV.',
    // 06/11 (prompt 27, 0048): quem decide é o PORTAL. O DFV é pista — não libera nem nega a venda.
    trava: 'Para registrar a venda (0 → 1) vale só a viabilidade do portal PAP: Viável, com menos de 7 dias. O DFV é só uma pista — não libera nem nega a venda.',
    como: 'Usuário PARCEIRO · senhas com o Ricardo · filtre UF, município e CEP',
    opcoes: {
      nao_consultado: 'Ninguém consultou o DFV para este endereço ainda. Consulte antes de abrir o pedido no portal.',
      viavel: 'Casa com viabilidade "Viável" e HP livre ≥ 1: endereço atendido e com porta livre. Segue para o pedido no portal.',
      viavel_predio: 'Prédio atendido com HP livre ≥ 1; a unidade só se confirma no portal. Segue para o pedido e anote o apto.',
      sem_viabilidade: 'A fachada existe, mas a viabilidade não é "Viável" (restrição técnica ou pendência). Não decide a venda: confira no portal (variações de CEP, rua e número) — quem manda é o portal.',
      nao_encontrado: 'A fachada não aparece no DFV (pode ser CEP, rua ou número escrito diferente na base). Não decide a venda: confira no portal — quem manda é o portal.',
    },
    jaTemNio: 'Casa com HCS = 1 e HP livre = 0 indica Nio no endereço: pergunte ao cliente e confira no portal. Só é saída "Já é cliente Nio" se o cliente confirmar (aí, vender seria estorno 100 %).',
    placar: 'Das vendas que entraram no mês, quantas tiveram o DFV consultado e deram viável. Toda qualificada deve ser consultada antes de abrir o pedido no portal.',
    faixa: 'Faixa de aprovação de crédito do bairro (últimos 2 meses). Não se fala disso com o cliente: serve para o Placar e o risco de FPD.',
  };
  const DFV_OK = ['viavel', 'viavel_predio'];
  // Conta Nio no Chatwoot (nunca a da Vero). Vazio = links para o Chatwoot desligados.
  const CHATWOOT_NIO_ACCOUNT = '195428';   // conta "Nio Atendimento" (modo chatwoot desde 04/11)
  const linkChatwoot = (conversa) => (CHATWOOT_NIO_ACCOUNT && conversa
    ? `https://app.chatwoot.com/app/accounts/${CHATWOOT_NIO_ACCOUNT}/conversations/${encodeURIComponent(conversa)}` : null);
  function dfvValido(v) {
    return DFV_OK.includes(v.dfv_viabilidade) && !!v.dfv_consultado_em && (Date.now() - new Date(v.dfv_consultado_em)) < 7 * 86400000;
  }
  // Selo: verde viável · amarelo não consultado / vencido / dispensado · vermelho sem viabilidade ou não encontrado.
  function seloDfv(v) {
    if (!v || v.status === 'saida') return '';
    const selo = (txt, cls, texto) => `<span class="chip selo ${cls}" data-dica="${esc(texto)}" title="${esc(texto)}">${esc(txt)}</span>`;
    const quando = v.dfv_consultado_em ? fmtData(v.dfv_consultado_em) : '';
    if (DFV_OK.includes(v.dfv_viabilidade)) {
      return dfvValido(v)
        ? selo(`DFV viável ${quando}${v.dfv_origem === 'auto' ? ' · auto' : ''}`, 'ok', `${TEXTOS_DFV.opcoes[v.dfv_viabilidade]} ${TEXTOS_DFV.regra}`)
        : selo(`DFV vencido (${quando})`, 'warn', `Consulta com mais de 7 dias. ${TEXTOS_DFV.trava}`);
    }
    if (v.dfv_resultado === 'endereco_ocupado') return selo('DFV: endereço já tem Nio', 'bad', DFV_RESULTADO.endereco_ocupado);
    if (v.dfv_viabilidade === 'sem_viabilidade' || v.dfv_viabilidade === 'nao_encontrado') {
      return selo(`DFV: ${v.dfv_viabilidade === 'sem_viabilidade' ? 'sem viabilidade' : 'não encontrado'}`, 'bad', TEXTOS_DFV.opcoes[v.dfv_viabilidade]);
    }
    if (v.dfv_dispensado) return selo('DFV dispensado (admin)', 'warn', `Admin dispensou a consulta: ${v.dfv_dispensa_motivo || '—'}`);
    return selo('DFV não consultado', 'warn', `${TEXTOS_DFV.opcoes.nao_consultado} ${TEXTOS_DFV.trava}`);
  }
  // Link e acesso do DFV vêm do banco (config_links, só para logado) — nunca do repo, que é público.
  let dfvCache;
  async function dadosDfv() {
    if (dfvCache === undefined) {
      const { data } = await sb.from('config_links').select('url, acesso').eq('chave', 'dfv_sudeste').maybeSingle();
      dfvCache = { url: (data && data.url) || null, acesso: (data && data.acesso) || null };
    }
    return dfvCache;
  }
  // ---------- DFV nível 3: consulta automática na base nio_hp (dfv_consultar) ----------
  // Resposta crua da função → valor do seletor (a mesma tabela do trigger vendas_antes_cobertura).
  const DFV_MAPA = {
    viavel: 'viavel', viavel_predio: 'viavel_predio', endereco_ocupado: 'sem_viabilidade',
    sem_porta_livre: 'sem_viabilidade', nao_encontrado: 'nao_encontrado',
  };
  const DFV_RESULTADO = {
    viavel: 'Viável na base DFV: fachada com porta livre.',
    viavel_predio: 'Prédio na base DFV: escolha a unidade (complemento) para conferir a porta.',
    endereco_ocupado: 'DFV indica Nio no endereço (casa com HC = 1): pergunte ao cliente e confira no portal. Só encerra como "Já é cliente Nio" se o cliente confirmar.',
    sem_porta_livre: 'Na base DFV, mas sem porta livre (HP livre = 0): confira no portal — quem manda é o portal.',
    nao_encontrado: 'Fora da base DFV: sem viabilidade hoje (a Nio só exporta endereços viáveis). Confira CEP e número.',
    precisa_numero: 'CEP na base DFV: informe o número da fachada para consultar.',
  };
  // Rótulo curto e cor (classe do chip) de cada resposta — tela Cobertura e selos.
  const DFV_ROTULO = {
    viavel: ['Viável', 'ok'], viavel_predio: ['Viável (prédio)', 'ok'], endereco_ocupado: ['Endereço já tem Nio', 'bad'],
    sem_porta_livre: ['Sem porta livre', 'bad'], nao_encontrado: ['Não encontrado', 'bad'], precisa_numero: ['Precisa do número', 'warn'],
  };
  // Faixa de crédito da Nio → código do seletor (igual a dfv_faixa_codigo no banco).
  const faixaCodigo = (t) => (!t ? null : /^maior/i.test(t) ? '>70' : /^entre/i.test(t) ? '50-70' : /^menor/i.test(t) ? '<50' : 'nao_informado');
  const baseDe = (particao) => (particao ? fmtDiaISO(particao).slice(0, 5) : '');
  async function dfvConsultar(cep, numero, complemento) {
    const { data, error } = await sb.rpc('dfv_consultar', { p_cep: cep || '', p_numero: numero || '', p_complemento: complemento || null });
    if (error) throw error;
    return (data || [])[0] || null;
  }

  // Bloco "Cobertura (DFV)": os mesmos campos na venda de rua e no detalhe da venda.
  function dfvCampos(v) {
    v = v || {};
    const opt = (lista, atual) => lista.map(([val, txt]) => `<option value="${val}" ${val === (atual ?? '') ? 'selected' : ''}>${esc(txt)}</option>`).join('');
    const todas = Object.entries(DFV_OPCOES).map(([k, t]) => `${t}: ${TEXTOS_DFV.opcoes[k]}`).join(' · ');
    const auto = v.dfv_origem === 'auto';
    return `
      <div class="dfv-auto">
        <span class="chip ${auto ? 'info' : ''}" data-dfv-origem>${auto ? `automático · base de ${esc(baseDe(v.dfv_particao))}` : v.dfv_origem === 'manual' ? 'manual' : 'base DFV'}</span>
        <span class="nota-campo" data-dfv-msg>${auto && v.dfv_resultado ? esc(DFV_RESULTADO[v.dfv_resultado] || '') : 'Preenche sozinho ao informar CEP e número.'}</span>
        <button type="button" class="btn btn-sm" data-dfv-consultar>Consultar de novo</button>
      </div>
      <div class="dfv-opcoes" data-dfv-opcoes hidden></div>
      <input type="hidden" name="dfv_origem" value="${esc(v.dfv_origem || '')}">
      <input type="hidden" name="dfv_resultado" value="${esc(v.dfv_resultado || '')}">
      <input type="hidden" name="dfv_particao" value="${esc(v.dfv_particao || '')}">
      <div class="grade2">
        <label class="campo"><span>Viabilidade no DFV ${dicaTxt(todas)}</span>
          <select name="dfv_viabilidade">${opt(Object.entries(DFV_OPCOES), v.dfv_viabilidade || 'nao_consultado')}</select></label>
        <label class="campo"><span>Faixa de aprovação ${dicaTxt(TEXTOS_DFV.faixa)}</span>
          <select name="dfv_faixa_credito">${opt([['', '—'], ['<50', 'menor que 50 %'], ['50-70', '50 a 70 %'], ['>70', 'maior que 70 %'], ['nao_informado', 'não informado']], v.dfv_faixa_credito)}</select></label>
        <label class="campo">Classificação
          <select name="dfv_classificacao">${opt([['', '—'], ['ALTO', 'Alto'], ['MEDIO', 'Médio'], ['BAIXO', 'Baixo']], v.dfv_classificacao)}</select></label>
        <div class="junto dfv-hp">
          <label class="campo">HP livre<input type="number" min="0" name="dfv_hp_livre" value="${v.dfv_hp_livre ?? ''}"></label>
          <label class="campo">HCs<input type="number" min="0" name="dfv_hcs" value="${v.dfv_hcs ?? ''}"></label>
        </div>
      </div>
      <details class="dfv-manual">
        <summary>Consulta manual no painel da Nio (fallback)</summary>
        <div class="dfv-topo">
          <a class="btn btn-sm dfv-link" data-dfv-link target="_blank" rel="noopener noreferrer" href="#">Abrir DFV Sudeste ↗</a>
          <a class="btn btn-sm" data-dfv-tela target="_blank" rel="noopener" href="cobertura.html">Consultar na tela de cobertura ↗</a>
          <span class="nota-campo" data-dfv-acesso>${esc(TEXTOS_DFV.como)}</span>
        </div>
        <span class="nota-campo">Mudou algum campo acima à mão? A consulta passa a valer como manual.</span>
      </details>
      <span class="nota-campo">${esc(TEXTOS_DFV.regra)} ${dicaTxt(TEXTOS_DFV.jaTemNio)}</span>`;
  }
  function dfvLer(root) {
    const val = (n) => { const el = root.querySelector(`[name="${n}"]`); return el ? el.value : ''; };
    const num = (n) => (val(n) === '' ? null : Number(val(n)));
    const vi = val('dfv_viabilidade') || 'nao_consultado';
    return {
      dfv_viabilidade: vi,
      dfv_faixa_credito: val('dfv_faixa_credito') || null,
      dfv_classificacao: val('dfv_classificacao') || null,
      dfv_hp_livre: num('dfv_hp_livre'),
      dfv_hcs: num('dfv_hcs'),
      dfv_origem: vi === 'nao_consultado' ? null : (val('dfv_origem') || 'manual'),
      dfv_resultado: val('dfv_resultado') || null,
      dfv_particao: val('dfv_particao') || null,
    };
  }
  // Escreve no bloco o que a base respondeu (origem auto). Devolve a resposta.
  function dfvPreencher(root, r) {
    const set = (n, v) => { const el = root.querySelector(`[name="${n}"]`); if (el) el.value = v ?? ''; };
    const msg = root.querySelector('[data-dfv-msg]');
    const selo = root.querySelector('[data-dfv-origem]');
    const ops = root.querySelector('[data-dfv-opcoes]');
    ops.hidden = true;
    ops.innerHTML = '';
    if (!r) return r;
    msg.textContent = DFV_RESULTADO[r.resultado] || r.resultado;
    if (r.resultado === 'precisa_numero') return r;
    set('dfv_viabilidade', DFV_MAPA[r.resultado] || 'nao_encontrado');
    set('dfv_faixa_credito', faixaCodigo(r.faixa_credito));
    set('dfv_classificacao', ['ALTO', 'MEDIO', 'BAIXO'].includes(r.classificacao) ? r.classificacao : '');
    set('dfv_hp_livre', r.hp_livre);
    set('dfv_hcs', r.hc_tot);
    set('dfv_origem', 'auto');
    set('dfv_resultado', r.resultado);
    set('dfv_particao', r.particao || '');
    selo.className = 'chip info';
    selo.textContent = `automático · base de ${baseDe(r.particao)}`;
    if (r.resultado === 'viavel_predio' && Array.isArray(r.opcoes) && r.opcoes.length) {
      ops.innerHTML = `<span class="nota-campo">${fmtNum(r.opcoes.length)} unidades nesta fachada · ${fmtNum(r.hp_livre)} portas livres. Toque na do cliente:</span>
        <div class="dfv-opcoes-lista">${r.opcoes.slice(0, 120).map((o) => `<button type="button" class="chip ${o.hp_livre >= 1 ? 'ok' : 'bad'}" data-dfv-comp="${esc(o.complemento || '')}"
          title="HP livre ${o.hp_livre ?? '—'} · HC ${o.hc_tot ?? '—'}">${esc(o.complemento || `nº ${o.numero} (sem complemento)`)}</button>`).join('')}</div>
        ${r.opcoes.length > 120 ? '<span class="nota-campo">Lista cortada em 120: digite o complemento e toque em "Consultar de novo".</span>' : ''}`;
      ops.hidden = false;
    }
    return r;
  }
  // Liga o bloco: consulta (botão / chamada externa), escolha de unidade do prédio e mudança manual.
  // endereco() → {cep, numero, complemento}; aoEscolher(complemento) grava o complemento escolhido; aoMudar(resposta|null).
  function ligarDfvAuto(root, endereco, { aoEscolher, aoMudar } = {}) {
    let seq = 0;
    async function consultar() {
      const e = endereco();
      const msg = root.querySelector('[data-dfv-msg]');
      if (soDigitos(e.cep).length !== 8 || !String(e.numero || '').trim()) {
        msg.textContent = 'Informe CEP e número para consultar a base DFV.';
        return null;
      }
      const meu = ++seq;
      msg.textContent = 'Consultando a base DFV…';
      try {
        const r = await dfvConsultar(e.cep, e.numero, e.complemento);
        if (meu !== seq) return null;
        dfvPreencher(root, r);
        if (aoMudar) aoMudar(r);
        return r;
      } catch (err) {
        msg.textContent = `Base DFV indisponível (${msgErro(err)}) — use a consulta manual.`;
        return null;
      }
    }
    root.querySelector('[data-dfv-consultar]').addEventListener('click', consultar);
    // Tela Cobertura em nova aba com o endereço atual (a venda de rua não perde o que foi digitado).
    root.querySelectorAll('[data-dfv-tela]').forEach((a) => {
      const montarHref = () => {
        const e = endereco();
        const q = new URLSearchParams(Object.entries({ cep: soDigitos(e.cep), numero: String(e.numero || '').trim(), complemento: String(e.complemento || '').trim() })
          .filter(([, v]) => v));
        a.href = `cobertura.html${q.toString() ? '?' + q : ''}`;
      };
      a.addEventListener('mousedown', montarHref);
      a.addEventListener('click', montarHref);
    });
    root.querySelector('[data-dfv-opcoes]').addEventListener('click', async (ev) => {
      const b = ev.target.closest('[data-dfv-comp]');
      if (!b) return;
      if (aoEscolher) await aoEscolher(b.dataset.dfvComp);
      consultar();
    });
    root.querySelectorAll('select, input[type=number]').forEach((el) => el.addEventListener('change', () => {
      root.querySelector('[name="dfv_origem"]').value = 'manual';
      root.querySelector('[name="dfv_resultado"]').value = '';
      root.querySelector('[name="dfv_particao"]').value = '';
      const selo = root.querySelector('[data-dfv-origem]');
      selo.className = 'chip';
      selo.textContent = 'manual';
      if (aoMudar) aoMudar(null);
    }));
    return consultar;
  }
  async function ligarLinkDfv(root) {
    const { url, acesso } = await dadosDfv();
    root.querySelectorAll('[data-dfv-link]').forEach((a) => {
      if (url) { a.href = url; return; }
      a.title = 'Link do DFV ainda não cadastrado no NIOGEN — peça ao Ricardo';
      a.addEventListener('click', (e) => { e.preventDefault(); toast(a.title, 'bad'); });
    });
    if (!acesso) return;
    // Senhas mascaradas até alguém tocar em "mostrar" (tela de celular na rua).
    root.querySelectorAll('[data-dfv-acesso]').forEach((el) => {
      const sen = (n) => `<code class="dfv-senha" data-senha="${esc(acesso[n] || '')}">••••</code>`;
      el.innerHTML = `Usuário <strong>${esc(acesso.usuario || '')}</strong> · Senha 1 ${sen('senha1')} · Senha 2 ${sen('senha2')} `
        + '<button type="button" class="btn btn-sm btn-ghost" data-mostrar-senha>mostrar</button>'
        + (acesso.passos ? `<span class="dfv-passos">${esc(acesso.passos)}</span>` : '');
      el.querySelector('[data-mostrar-senha]').addEventListener('click', (ev) => {
        const ver = ev.currentTarget.textContent === 'mostrar';
        el.querySelectorAll('[data-senha]').forEach((c) => { c.textContent = ver ? c.dataset.senha : '••••'; });
        ev.currentTarget.textContent = ver ? 'esconder' : 'mostrar';
      });
    });
  }

  document.addEventListener('click', (ev) => {
    const b = ev.target.closest('[data-dica]');
    const aberto = document.querySelector('.dica-pop');
    if (aberto) aberto.remove();
    if (!b || (aberto && aberto.dataset.de === b.dataset.dica)) return;
    ev.preventDefault();
    ev.stopPropagation();
    const pop = document.createElement('div');
    pop.className = 'dica-pop';
    pop.setAttribute('role', 'tooltip');
    pop.dataset.de = b.dataset.dica;
    pop.textContent = b.dataset.dica;
    document.body.appendChild(pop);
    const r = b.getBoundingClientRect();
    const larg = Math.min(300, window.innerWidth - 24);
    pop.style.width = `${larg}px`;
    pop.style.left = `${Math.max(12, Math.min(r.left + r.width / 2 - larg / 2, window.innerWidth - larg - 12)) + window.scrollX}px`;
    pop.style.top = `${r.bottom + 6 + window.scrollY}px`;
  }, true);

  // ---------- sessão ----------
  let usuarioAtual = null;
  async function exigirLogin() {
    const { data } = await sb.auth.getSession();
    if (!data.session) {
      location.replace('index.html');
      return new Promise(() => {});
    }
    const { data: u, error } = await sb.from('usuarios').select('*').eq('id', data.session.user.id).maybeSingle();
    if (error) {
      // Falha de rede/configuração não é "sem perfil": mostra o erro real e mantém a sessão.
      location.replace('index.html?erro=' + encodeURIComponent(msgErro(error)));
      return new Promise(() => {});
    }
    if (!u || !u.ativo) {
      await sb.auth.signOut();
      location.replace('index.html?erro=perfil');
      return new Promise(() => {});
    }
    usuarioAtual = { ...u, email: data.session.user.email };
    return usuarioAtual;
  }
  async function sair() {
    await sb.auth.signOut();
    location.replace('index.html');
  }

  // ---------- modais ----------
  // Cria um <dialog> com o HTML dado; resolve com FormData ao confirmar ou null ao cancelar.
  function modal(html, aoAbrir) {
    return new Promise((resolve) => {
      const d = document.createElement('dialog');
      d.className = 'modal';
      d.innerHTML = `<form method="dialog">${html}<div class="acoes"><button type="button" class="btn btn-ghost" data-cancelar>Cancelar</button><button type="submit" class="btn btn-acc" value="ok">Confirmar</button></div></form>`;
      document.body.appendChild(d);
      const form = d.querySelector('form');
      let resultado = null;
      form.addEventListener('submit', (ev) => {
        if (!form.reportValidity()) { ev.preventDefault(); return; }
        resultado = new FormData(form);
      });
      d.querySelector('[data-cancelar]').addEventListener('click', () => d.close());
      d.addEventListener('close', () => { d.remove(); resolve(resultado); });
      if (aoAbrir) aoAbrir(d);
      d.showModal();
    });
  }

  function amanhaISO() {
    const d = new Date(Date.now() + 86400000);
    return diaSP(d);
  }

  // Pede data + período; devolve ISO com fuso -03:00 (manhã 08:00, tarde 13:00) ou null.
  async function pedirAgendamento(titulo, venda) {
    const fd = await modal(`
      <h3>${esc(titulo)}</h3>
      <p>${esc(venda.cliente_nome)} · ${esc(venda.cidade || '')} · ${esc(venda.plano_nome || '')}</p>
      <label class="campo">Data da instalação<input type="date" name="data" required value="${amanhaISO()}"></label>
      <label class="campo">Período<select name="periodo"><option value="08:00">Manhã · 8–12h</option><option value="13:00">Tarde · 13–17h</option></select></label>
    `);
    if (!fd) return null;
    return `${fd.get('data')}T${fd.get('periodo')}:00-03:00`;
  }

  // 0087: venda = OS aberta no portal (etapa 7) — nº do pedido + nº da OS. A biometria vem depois.
  async function pedirPedidoBiometria(venda) {
    const fd = await modal(`
      <h3>Registrar a venda (OS aberta)</h3>
      <p>Venda é a OS aberta no portal da Nio (etapa 7 "Abrir OS"). O banco confere também a viabilidade do portal e o crédito.</p>
      <label class="campo">Nº do pedido (portal PAP)<input type="text" name="pedido" value="${esc(venda.nio_pedido || '')}" autocomplete="off"></label>
      <label class="campo">Nº da OS<input type="text" name="os" value="${esc(venda.nio_os || '')}" autocomplete="off"></label>
    `);
    if (!fd) return null;
    const pedido = String(fd.get('pedido') || '').trim();
    const os = String(fd.get('os') || '').trim();
    return { nio_pedido: pedido || null, nio_os: os || null };
  }

  async function pedirSaida(venda) {
    const fd = await modal(`
      <h3>Encerrar com motivo</h3>
      <p>${esc(venda.cliente_nome)}</p>
      <label class="campo">Motivo<select name="motivo" required><option value="">Escolher…</option>${MOTIVOS_SAIDA.map((m) => `<option>${esc(m)}</option>`).join('')}</select></label>
      <label class="campo" data-futuro hidden>Volta em<input type="date" name="futuro"></label>
    `, (d) => {
      const sel = d.querySelector('[name=motivo]');
      const fut = d.querySelector('[data-futuro]');
      sel.addEventListener('change', () => {
        const on = sel.value.startsWith('Interesse futuro');
        fut.hidden = !on;
        fut.querySelector('input').required = on;
      });
    });
    if (!fd) return null;
    const motivo = fd.get('motivo');
    return { motivo_saida: motivo, interesse_futuro_em: motivo.startsWith('Interesse futuro') ? fd.get('futuro') : null };
  }

  // Muda o status; os campos extras exigidos por cada destino são pedidos antes.
  // O banco é a autoridade: a mensagem do RAISE do trigger volta como toast.
  async function moverStatus(venda, destino) {
    if (destino === venda.status) return false;
    let campos = { status: destino };
    if (destino === '1_vendido' && venda.status === '0_qualificado') {
      const extra = await pedirPedidoBiometria(venda);
      if (!extra) return false;
      campos = { ...campos, ...extra };
    } else if (destino === '2_aguardando_instalacao') {
      const quando = await pedirAgendamento('Registrar agendamento', venda);
      if (!quando) return false;
      campos.instalacao_agendada_para = quando;
    } else if (destino === 'saida') {
      const extra = await pedirSaida(venda);
      if (!extra) return false;
      campos = { ...campos, ...extra };
    }
    const { error } = await sb.from('vendas').update(campos).eq('id', venda.id);
    if (error) { toast(msgErro(error), 'bad'); return false; }
    toast(`${primeiroNome(venda.cliente_nome)} → ${STATUS_MAP[destino].curto}`, 'ok');
    return true;
  }

  // ---------- dados comuns ----------
  async function carregarUsuarios() {
    const { data } = await sb.from('usuarios').select('id, nome, perfil').eq('ativo', true).order('nome');
    return data || [];
  }
  function preencherSelect(sel, valores, rotuloTodos) {
    sel.innerHTML = `<option value="">${esc(rotuloTodos)}</option>` +
      valores.map(([v, r]) => `<option value="${esc(v)}">${esc(r)}</option>`).join('');
  }

  // ---------- padrão de telas (04/11): período, KPIs, abas, ordenação, etapa, gaveta ----------
  const pad2 = (n) => String(n).padStart(2, '0');
  // São Paulo não tem horário de verão desde 2019: meia-noite local = 03:00 UTC.
  const inicioDiaSP = (dia) => new Date(`${dia}T00:00:00-03:00`);
  const somaDias = (dia, n) => { const d = new Date(`${dia}T12:00:00-03:00`); d.setUTCDate(d.getUTCDate() + n); return diaSP(d); };
  const PERIODOS = [['hoje', 'Hoje'], ['7', 'Últimos 7 dias'], ['mes', 'Este mês'], ['mesant', 'Mês passado'], ['tudo', 'Tudo'], ['custom', 'Período…']];
  // Período → {inicio, fim} (Date, fim exclusivo = 00:00 do dia seguinte ao último) + {de, ate} (AAAA-MM-DD), em America/Sao_Paulo.
  // "tudo" (ou datas vazias no Período…) devolve null na ponta aberta.
  function periodo(valor, de, ate) {
    const hoje = diaSP();
    let a = null, b = null;
    if (valor === 'hoje') { a = hoje; b = hoje; }
    else if (valor === '7') { a = somaDias(hoje, -6); b = hoje; }
    else if (valor === 'mes') { a = `${hoje.slice(0, 8)}01`; b = hoje; }
    else if (valor === 'mesant') {
      const primeiro = `${hoje.slice(0, 8)}01`;
      b = somaDias(primeiro, -1);
      a = `${b.slice(0, 8)}01`;
    } else if (valor === 'custom') { a = de || null; b = ate || null; }
    return { valor, de: a, ate: b, inicio: a ? inicioDiaSP(a) : null, fim: b ? inicioDiaSP(somaDias(b, 1)) : null };
  }
  const noPeriodo = (v, p) => {
    if (!p || (!p.inicio && !p.fim)) return true;
    if (!v) return false;
    const t = new Date(v).getTime();
    return (!p.inicio || t >= p.inicio.getTime()) && (!p.fim || t < p.fim.getTime());
  };
  // Seletor de Período (Hoje · 7 dias · Este mês · Mês passado · Tudo · Período… com de/até). Devolve {valor() → periodo, el}.
  function filtroPeriodo(el, { padrao = 'mes', aoMudar } = {}) {
    el.classList.add('periodo');
    el.innerHTML = `<select class="sel" aria-label="Período">${PERIODOS.map(([v, t]) => `<option value="${v}" ${v === padrao ? 'selected' : ''}>${t}</option>`).join('')}</select>
      <span class="datas" hidden><input class="sel" type="date" aria-label="De"> até <input class="sel" type="date" aria-label="Até"></span>`;
    const sel = el.querySelector('select');
    const datas = el.querySelector('.datas');
    const [de, ate] = el.querySelectorAll('input');
    const valor = () => periodo(sel.value, de.value, ate.value);
    sel.addEventListener('change', () => {
      datas.hidden = sel.value !== 'custom';
      if (sel.value === 'custom' && !de.value && !ate.value) { const h = diaSP(); de.value = `${h.slice(0, 8)}01`; ate.value = h; }
      if (aoMudar) aoMudar(valor());
    });
    [de, ate].forEach((i) => i.addEventListener('change', () => aoMudar && aoMudar(valor())));
    return { el, valor, get rotulo() { return sel.options[sel.selectedIndex].text; } };
  }

  // Cartão de KPI: {rot, val, de (meta), nota, pct (0–100, barra), cls (warn/bad), dica (texto do ⓘ)}.
  function kpi({ rot, val, de, nota, pct, cls, dica: d }) {
    return `<div class="kpi ${cls || ''}">
      <span class="rot">${esc(rot)}${d ? dicaTxt(d) : ''}</span>
      <span class="val">${val}${de != null ? ` <small>/ ${esc(de)}</small>` : ''}</span>
      ${pct != null ? `<div class="barra"><i style="width:${Math.max(0, Math.min(100, pct))}%"></i></div>` : ''}
      ${nota ? `<span class="nota">${nota}</span>` : ''}
    </div>`;
  }

  // Abas em pílula: itens [{id, nome, n, alerta}]. aoEscolher(id) ao clicar.
  function abasPilulas(el, itens, ativa, aoEscolher) {
    el.classList.add('abas', 'pilulas');
    el.setAttribute('role', 'tablist');
    el.innerHTML = itens.map((a) => `<button type="button" role="tab" class="aba${a.alerta ? ' alerta' : ''}${a.cls ? ` ${a.cls}` : ''}${a.id === ativa ? ' ativa' : ''}"${a.dica ? ` title="${esc(a.dica)}"` : ''}
      aria-selected="${a.id === ativa}" data-aba="${esc(a.id)}">${esc(a.nome)}<b>${fmtNum(a.n)}</b></button>`).join('');
    if (!el.dataset.ligado) {
      el.dataset.ligado = '1';
      el.addEventListener('click', (ev) => { const b = ev.target.closest('[data-aba]'); if (b && el._aoEscolher) el._aoEscolher(b.dataset.aba); });
    }
    el._aoEscolher = aoEscolher;
  }

  // Ordenação por coluna: <th data-ord="chave">. estado = {chave, dir (1 ↑ · -1 ↓)}; aoMudar() redesenha.
  function ligarOrdenacao(thead, estado, aoMudar) {
    const setas = () => thead.querySelectorAll('th[data-ord]').forEach((th) => {
      let s = th.querySelector('.seta');
      if (!s) { s = document.createElement('span'); s.className = 'seta'; th.appendChild(s); }
      const on = th.dataset.ord === estado.chave;
      s.textContent = on ? (estado.dir > 0 ? '↑' : '↓') : '↕';
      th.setAttribute('aria-sort', on ? (estado.dir > 0 ? 'ascending' : 'descending') : 'none');
    });
    thead.addEventListener('click', (ev) => {
      const th = ev.target.closest('th[data-ord]');
      if (!th) return;
      if (estado.chave === th.dataset.ord) estado.dir = -estado.dir;
      else { estado.chave = th.dataset.ord; estado.dir = th.dataset.dir === 'desc' ? -1 : 1; }
      setas();
      aoMudar();
    });
    setas();
  }
  // Ordena uma cópia; vazio sempre no fim. chaves = {coluna: (item) => valor}.
  function ordenar(lista, chaves, estado) {
    const f = chaves[estado.chave];
    if (!f) return lista.slice();
    return lista.slice().sort((a, b) => {
      const x = f(a), y = f(b);
      const vx = x == null || x === '', vy = y == null || y === '';
      if (vx || vy) return vx === vy ? 0 : vx ? 1 : -1;
      const c = typeof x === 'string' ? x.localeCompare(y, 'pt-BR', { sensitivity: 'base' }) : x - y;
      return c * estado.dir;
    });
  }

  // Pílula da etapa (uma por linha) e "próximo passo" ({txt, nivel: bad | warn | ok | dim}).
  const pilulaEtapa = (x) => { const e = etapaDe(x); return `<span class="pill ${e.id}">${esc(e.nome)}</span>`; };
  const proxPasso = (p) => (p && p.txt ? `<span class="prox ${p.nivel || 'ok'}">${esc(p.txt)}</span>` : '<span class="prox dim">—</span>');
  // ---------- próximo passo da venda (Vendas, Instalações, Painel e ficha usam daqui) ----------
  // {txt, nivel, acao (entra em "Precisam de ação"), resolver (o formulário da ficha que resolve o passo)}.
  // Sinais do banco: horas_sem_agendamento, biometria_em, nio_pendencia_*, dfv_ok, docs_prazo_em, nio_venda_valida e o
  // último contato (contatos_cliente, ou a entrada quando não há nenhum). ultimoContatoEm = data do último contato ou null.
  const ATIVAS_INST = ['1_vendido', '2_aguardando_instalacao', '3_instalado'];
  // ---------- pendência com terceiro (0064) ----------
  // Os motivos vêm de config_motivos_pendencia; aqui só o rótulo de "quem destrava" (enum do banco).
  const QUEM_DESTRAVA = { nio: 'Nio', rogerio: 'Rogério', cliente: 'cliente', interno: 'nosso time' };
  const RESULTADO_PENDENCIA = { destravou: 'Destravou', saida: 'Virou Saída', cancelada: 'Cancelada' };
  const diaCurto = (iso) => (iso ? `${fmtDiaSemana(`${String(iso).slice(0, 10)}T12:00:00-03:00`)} ${fmtDiaISO(iso).slice(0, 5)}` : '—');
  // v = linha da v_funil (colunas pend_*). null = sem pendência aberta (ou venda em Saída).
  function pendencia(v) {
    if (!v || !v.pend_id || v.status === 'saida') return null;
    const r = String(v.pend_revisar_em || '').slice(0, 10);
    return {
      id: v.pend_id, motivo: v.pend_motivo, nome: v.pend_motivo_nome || v.pend_motivo, quem: v.pend_quem,
      quemTxt: QUEM_DESTRAVA[v.pend_quem] || v.pend_quem || '—', descricao: v.pend_descricao, desde: v.pend_desde,
      revisar_em: r, revisoes: Number(v.pend_revisoes || 0), saida_sugerida: v.pend_saida_sugerida,
      vencida: !!r && r <= diaSP(), diaTxt: diaCurto(r),
    };
  }
  function proximoPasso(v, ultimoContatoEm) {
    const hoje = diaSP();
    const dd = (x) => fmtData(x);
    if (v.status === 'saida') {
      const volta = v.interesse_futuro_em ? ` · volta ${fmtDiaISO(v.interesse_futuro_em).slice(0, 5)}` : '';
      return { txt: `${v.motivo_saida || 'Encerrada'}${volta}`, nivel: 'dim' };
    }
    if (v.nio_venda_valida === false) return { txt: 'Nio marcou a venda como inválida', nivel: 'bad', acao: true, resolver: 'invalida' };
    if ((v.nio_pendencia_cod || v.nio_pendencia_desc) && ATIVAS_INST.includes(v.status)) {
      return { txt: `Pendência Nio · ${[v.nio_pendencia_cod, v.nio_pendencia_desc].filter(Boolean).join(' · ')}`.slice(0, 70), nivel: 'bad', acao: true, resolver: 'reagendar' };
    }
    // 0064 (08/11): pendência com terceiro ("Em espera"). A venda fica na etapa; enquanto a data de revisão não chega o selo é
    // neutro e a venda SAI de "Precisam de ação"; na data (ou depois) vira vermelho e volta a contar — para todos.
    const pe = pendencia(v);
    if (pe) {
      const adiada = pe.revisoes >= 2 ? ` · ⚠️ adiada ${pe.revisoes}×` : '';
      if (pe.vencida) {
        const era = pe.revisar_em < hoje ? ` (era ${pe.diaTxt})` : '';
        return { txt: `⏰ Revisar hoje: ${pe.nome} · ${pe.quemTxt}${era}${adiada}`, nivel: 'bad', acao: true, espera: true, vencida: true, resolver: 'pendencia' };
      }
      return { txt: `⏸ Aguardando ${pe.quemTxt} · ${pe.nome} · revisar ${pe.diaTxt}${adiada}`, nivel: 'espera', espera: true, resolver: 'pendencia' };
    }
    // Venda de parceiro (prompt 25): a conferência de qualidade vem antes de qualquer outro passo. Enquanto não estiver aprovada o
    // banco não deixa passar de Qualificado (trigger vendas_antes_conferencia); aqui só dizemos o que fazer e até quando.
    if (v.origem === 'parceiro_pap' && v.status === '0_qualificado' && v.conferencia_status && v.conferencia_status !== 'aprovada') {
      if (v.conferencia_status === 'pendente') {
        const prazo = v.conferencia_prazo_ate ? new Date(v.conferencia_prazo_ate) : null;
        if (!prazo) return { txt: 'Conferir a venda do parceiro', nivel: 'warn', acao: true, resolver: 'conferencia' };
        if (prazo.getTime() < Date.now()) return { txt: `Conferência atrasada · era até ${diaSP(prazo) === hoje ? fmtHora(prazo) : fmtDataHora(prazo)}`, nivel: 'bad', acao: true, resolver: 'conferencia' };
        return { txt: `Conferir até ${diaSP(prazo) === hoje ? fmtHora(prazo) : fmtDataHora(prazo)}`, nivel: diaSP(prazo) === hoje ? 'warn' : 'ok', acao: true, resolver: 'conferencia' };
      }
      if (v.conferencia_status === 'devolvida') return { txt: `Devolvida ao parceiro · ${MOTIVOS_CONFERENCIA[v.conferencia_motivo] || 'motivo'}`.slice(0, 70), nivel: 'dim' };
      if (v.conferencia_status === 'reprovada') return { txt: `Reprovada na conferência · ${MOTIVOS_CONFERENCIA[v.conferencia_motivo] || 'motivo'}`.slice(0, 70), nivel: 'dim' };
    }
    switch (v.status) {
      case '0_qualificado': {
        // 0089: etapa 2 LEAD QUALIFICADO (sem pedido) → viabilidade → pedido. Etapa 3 PEDIDO · BIOMETRIA (com pedido) → biometria
        // validada → abrir a OS (é ela que faz a venda contar, 0096); agendar é o passo seguinte. Mesmos textos da v_jornada.
        if (!String(v.nio_pedido || '').trim()) {
          if (v.credito_resultado === 'negado') return { txt: 'Crédito negado · pedir outro CPF (pendência) ou encerrar', nivel: 'bad', acao: true, resolver: 'saida' };
          if (!portalViavel(v)) {
            if (['sem_viabilidade', 'nao_encontrado', 'posse'].includes(v.nio_viab_resultado)) {
              return { txt: `Portal: ${VIAB_NIO[v.nio_viab_resultado].toLowerCase()} · conferir no DFV: endereço viável a até 200 m → formulário da Nio + pendência`, nivel: 'warn', acao: true, resolver: 'viab' };
            }
            if (v.nio_viab_resultado === 'viavel') return { txt: 'Viabilidade vencida (> 7 dias) · consultar de novo no portal', nivel: 'warn', acao: true, resolver: 'viab' };
            return { txt: 'Consultar a viabilidade no portal', nivel: 'warn', acao: true, resolver: 'viab' };
          }
          return { txt: 'Viável · abrir o pedido no portal e gravar o nº', nivel: 'warn', acao: true, resolver: 'pedido' };
        }
        const desdeLink = v.biometria_link_enviado_em || v.nio_pedido_em;
        const hBio = desdeLink ? (Date.now() - new Date(desdeLink)) / 3600000 : null;
        if (v.biometria_status === 'validada') {
          const h = v.biometria_validada_em ? (Date.now() - new Date(v.biometria_validada_em)) / 3600000 : null;
          return { txt: `Biometria validada · abrir a OS no portal (prazo 4 h)${h != null ? ` · há ${fmtHoras(h)}` : ''}`, nivel: 'bad', acao: true, resolver: 'os' };
        }
        if (v.credito_resultado === 'negado') return { txt: 'Crédito negado · pedir outro CPF (pendência) ou encerrar', nivel: 'bad', acao: true, resolver: 'bio_status' };
        if (v.biometria_status === 'com_risco') return { txt: 'Biometria com risco · conferir no portal', nivel: 'warn', acao: true, resolver: 'bio_status' };
        if (hBio != null && hBio > 72) return { txt: `Link da biometria há ${fmtHoras(hBio)} · ligar para o cliente`, nivel: 'bad', acao: true, resolver: 'bio_status' };
        if (hBio != null && hBio > 24) return { txt: `Link da biometria há ${fmtHoras(hBio)} · lembrar o cliente pela conversa`, nivel: 'warn', acao: true, resolver: 'bio_status' };
        return { txt: `Esperando a biometria do cliente${hBio != null ? ` · link da Nio há ${fmtHoras(hBio)}` : ''}`, nivel: 'espera', espera: true, resolver: 'bio_status' };
      }
      case '1_vendido':
      case '2_aguardando_instalacao': {
        // 0096: etapa 4 ATIVAÇÃO/AGENDA. OS aberta sem data → agendar (4 h da biometria). Depois só volta com a data passada sem baixa.
        const q = v.instalacao_agendada_para;
        if (!q) {
          const b = v.biometria_validada_em || v.vendido_em;
          const h = b ? (Date.now() - new Date(b)) / 3600000 : null;
          return { txt: `OS aberta · agendar a instalação (prazo 4 h)${h != null ? ` · há ${fmtHoras(h)}` : ''}`, nivel: 'bad', acao: true, resolver: 'agendar' };
        }
        const d = diaSP(q), j = janela(q);
        if (d < hoje) return { txt: `Instalação era ${dd(q)} e a Nio não deu baixa · conferir no portal`, nivel: 'warn', acao: true, resolver: 'reagendar' };
        if (d === hoje) return { txt: `Instalação hoje · ${j} · com a Nio`, nivel: 'ok', resolver: 'reagendar' };
        if (d === somaDias(hoje, 1)) return { txt: `Instalação amanhã · ${j} · com a Nio`, nivel: 'ok', resolver: 'reagendar' };
        return { txt: `Instalação ${dd(q)} · ${j} · com a Nio`, nivel: 'ok', resolver: 'reagendar' };
      }
      case '3_instalado': {
        if (!v.docs_entregues_em && v.docs_prazo_em) {
          const dias = (new Date(v.docs_prazo_em) - Date.now()) / 86400000;
          if (dias < 0) return { txt: `Documentos à Nio atrasados · prazo era ${dd(v.docs_prazo_em)}`, nivel: 'bad', acao: true, resolver: 'docs' };
          return { txt: `Documentos à Nio · prazo ${dd(v.docs_prazo_em)} (15 dias)`, nivel: 'warn', acao: true, resolver: 'docs' };
        }
        return { txt: 'Instalada · conta na meta', nivel: 'ok' };
      }
      case '4_ativo_provisorio':
      case '5_comissao_firme': {
        const b = v.ativado_em || v.instalado_em;
        return { txt: b ? `Instalada · ativa desde ${dd(b)}` : 'Instalada · ativa', nivel: 'ok' };
      }
      default: return { txt: '', nivel: 'dim' };
    }
  }
  // ---------- faixa "primeira venda" (onda 2.1, 09/11) ----------
  // Em que passo a venda está parada, desde quando e se passou do prazo do contrato. Prazos vêm de config_regras
  // (prazo_agendar_horas, prazo_docs_dias); os números abaixo são só o padrão se a config não carregar.
  const PARADAS = [
    { id: 'qualificado', nome: 'Lead qualificado', dica: 'Etapa 2 · ainda NÃO é venda: falta a viabilidade do portal e gravar o pedido' },
    { id: 'biometria', nome: 'Biometria', dica: 'Etapa 3 · pedido gravado: esperando o cliente fazer a biometria (link automático da Nio)' },
    { id: 'agendamento', nome: 'Abrir a OS', dica: 'Etapa 3 · biometria validada, falta abrir a OS no portal — contrato: até 4 h' },
    { id: 'agendar', nome: 'Agendar', dica: 'Etapa 4 · OS aberta (venda), falta agendar a instalação — contrato: até 4 h da biometria' },
    { id: 'instalacao', nome: 'Ativação/Agenda', dica: 'Etapa 4 · instalação agendada: esperando o técnico / a baixa da Nio no OSAB' },
    { id: 'instalada', nome: 'Instalada · docs', dica: 'Etapa 5 · instalada, documentos à Nio pendentes — contrato: 15 dias' },
  ];
  function paradaDe(v, regras = {}) {
    if (!v || v.status === 'saida') return null;
    const hAg = Number(regras.prazo_agendar_horas ?? 4);
    const dDocs = Number(regras.prazo_docs_dias ?? 15);
    const horas = (desde) => (desde ? (Date.now() - new Date(desde)) / 3600000 : null);
    switch (v.status) {
      case '0_qualificado': {
        if (!String(v.nio_pedido || '').trim()) return { id: 'qualificado', desde: v.criado_em };
        if (v.biometria_status !== 'validada') return { id: 'biometria', desde: v.biometria_link_enviado_em || v.nio_pedido_em || v.criado_em };
        const desde = v.biometria_validada_em || v.criado_em;
        return { id: 'agendamento', desde, atrasada: horas(desde) > hAg, prazo: `${hAg} h` };
      }
      case '1_vendido':
      case '2_aguardando_instalacao': {
        if (!v.instalacao_agendada_para) {
          const desde = v.biometria_validada_em || v.vendido_em || v.criado_em;
          return { id: 'agendar', desde, atrasada: horas(desde) > hAg, prazo: `${hAg} h` };
        }
        return { id: 'instalacao', desde: v.agendamento_registrado_em || v.vendido_em || v.criado_em };
      }
      case '3_instalado': {
        if (v.docs_entregues_em || !v.instalado_em) return null;
        return { id: 'instalada', desde: v.instalado_em, atrasada: horas(v.instalado_em) > dDocs * 24, prazo: `${dDocs} dias` };
      }
      default: return null;
    }
  }
  // ---------- ficha única · fase 1 (onda 3.1, 0076): selos de aviso, nada bloqueia ----------
  // r = retorno de ficha_avisos() ({bloquear, selos:[{tipo, nivel, texto, venda_id?, conversa_id?}]}). ignorar = id da venda aberta.
  const ICONE_SELO = { duplicado: '⚠️', saida: '↩️', dfv: '🏠', telefone: '📱' };
  function selosFicha(r, { ignorar } = {}) {
    const selos = ((r && r.selos) || []).filter((s) => !ignorar || s.venda_id !== ignorar);
    if (!selos.length) return '';
    return `<div class="selos-ficha" role="note" aria-label="Avisos de ficha única">${selos.map((s) => {
      const alvo = s.venda_id ? `#venda=${esc(s.venda_id)}` : s.conversa_id ? `mari.html?conversa=${esc(s.conversa_id)}` : '';
      const corpo = `${ICONE_SELO[s.tipo] || '⚠️'} ${esc(s.texto)}`;
      return alvo ? `<a class="selo-ficha ${esc(s.nivel || 'warn')}" href="${alvo}" title="Abrir">${corpo}</a>`
        : `<span class="selo-ficha ${esc(s.nivel || 'warn')}">${corpo}</span>`;
    }).join('')}<span class="selo-ficha-nota">Só aviso — nada foi bloqueado. Confira antes do pedido (recompra = multa R$ 500; cliente/endereço já Nio = estorno 100 %).</span></div>`;
  }
  // "há 3h05" / "há 2 dias" (para "a mais antiga está parada há …").
  const haQuanto = (desde) => {
    if (!desde) return '—';
    const h = Math.max(0, (Date.now() - new Date(desde)) / 3600000);
    return h < 48 ? fmtHoras(h) : `${Math.floor(h / 24)} dias`;
  };
  // Último contato por venda (contatos_cliente ordenado do mais novo para o mais velho) → {venda_id: em}.
  function ultimosContatos(linhas) {
    const m = {};
    (linhas || []).forEach((c) => { if (!m[c.venda_id]) m[c.venda_id] = c.em; });
    return m;
  }
  // Abre a ficha da venda em gaveta (se a tela carregou o ficha.js) ou cai na página cheia.
  function abrirVenda(id, novaAba) {
    if (!id) return;
    if (novaAba) { window.open(`${location.pathname}${location.search}#venda=${id}`, '_blank'); return; }
    if (window.NGFicha) window.NGFicha.abrir(id);
    else location.href = `venda.html?id=${id}`;
  }

  // Entrou: hoje / ontem / DD/MM.
  function quando(v) {
    if (!v) return '—';
    const d = diaSP(v), h = diaSP();
    return d === h ? 'hoje' : d === somaDias(h, -1) ? 'ontem' : fmtData(v);
  }

  // Gaveta lateral (direita, até 560 px; tela cheia no celular). Fecha com ×/[data-fechar], Esc ou clique fora.
  const gaveta = (() => {
    let atual = null, veu = null, antesFoco = null, aoFechar = null;
    function abrir(alvo, opts = {}) {
      const el = typeof alvo === 'string' ? document.getElementById(alvo) : alvo;
      if (!el) return;
      if (atual && atual !== el) fechar();
      if (!veu) {
        veu = document.createElement('div');
        veu.className = 'gaveta-veu';
        veu.addEventListener('click', () => fechar());
        document.body.appendChild(veu);
      }
      antesFoco = document.activeElement;
      atual = el;
      aoFechar = opts.aoFechar || null;
      el.querySelectorAll('[data-fechar]').forEach((b) => { b.onclick = () => fechar(); });
      el.setAttribute('role', 'dialog');
      el.setAttribute('aria-modal', 'true');
      el.removeAttribute('aria-hidden');
      el.classList.add('aberta');
      veu.classList.add('aberto');
      document.body.classList.add('gaveta-on');
      if (opts.foco !== false) setTimeout(() => { const f = el.querySelector('[autofocus]') || el.querySelector('.g-corpo input, .g-corpo select'); if (f) f.focus({ preventScroll: true }); }, 280);
    }
    function fechar() {
      if (!atual) return;
      const el = atual, cb = aoFechar;
      atual = null;
      aoFechar = null;
      el.classList.remove('aberta');
      el.setAttribute('aria-hidden', 'true');
      if (veu) veu.classList.remove('aberto');
      document.body.classList.remove('gaveta-on');
      if (antesFoco && antesFoco.focus) antesFoco.focus({ preventScroll: true });
      if (cb) cb();
    }
    document.addEventListener('keydown', (ev) => {
      if (ev.key === 'Escape' && atual && !document.querySelector('dialog[open]') && !document.querySelector('.dica-pop')) fechar();
    });
    return { abrir, fechar, get aberta() { return !!atual; } };
  })();

  // ---------- bolinhas da cadência (prompt 28, 07/11) ----------
  // Acesa = enviada (data) · piscando = próxima (dia e hora) · apagada = futura. Ao passar o mouse, o TEXTO exato:
  // enviada = mari_turnos com tags.cadencia · próxima = v_mari_cadencia.texto (0050) · futura = corpo do template.
  let tplCache = null;
  async function tplCadencia() {
    if (tplCache) return tplCache;
    const { data, error } = await sb.from('config_templates_waba').select('nome, corpo');
    if (error) return {};
    tplCache = Object.fromEntries((data || []).map((t) => [t.nome, t.corpo || '']));
    return tplCache;
  }
  const renderTpl = (corpo, params) => (corpo ? String(corpo).replace(/\{\{(\d+)\}\}/g, (m, n) => {
    const p = (params || [])[Number(n) - 1];
    return p == null || p === '' ? '…' : String(p);
  }) : '');
  // {{1}} igual ao banco (mari_cadencia_nome): 1º nome só se confiável; senão "tudo bem".
  const nomeCadencia = (nome) => {
    const p = String(nome || '').trim().split(/\s+/)[0];
    return p ? p.charAt(0).toUpperCase() + p.slice(1).toLowerCase() : 'tudo bem';
  };
  // turnos da Mari com tags.cadencia → { passo: { em, texto } } (o último de cada passo)
  const cadEnviados = (turnos) => Object.fromEntries((turnos || [])
    .filter((t) => t.tags && t.tags.cadencia)
    .map((t) => [t.tags.cadencia, { em: t.created_at, texto: t.texto, simulado: !!t.tags.simulado }]));
  // passos: [{ cod, rot }] · proximo: { cod, em, texto, bloqueio } · futuros: { cod: texto }
  function cadBolinhas(passos, { enviados = {}, proximo = null, futuros = {} } = {}) {
    const itens = passos.map(({ cod, rot }) => {
      const env = enviados[cod];
      let cls; let tit;
      if (env) {
        cls = 'on';
        tit = `${rot} · enviada ${fmtDataHora(env.em)}${env.simulado ? ' (simulado)' : ''}\n\n${env.texto || '(sem texto gravado)'}`;
      } else if (proximo && proximo.cod === cod) {
        cls = 'prox';
        const quando = proximo.em ? ` · ${fmtDiaSemana(proximo.em)} ${fmtDataHora(proximo.em)}` : '';
        const bloq = proximo.bloqueio && proximo.bloqueio !== 'aguardando' ? `\n(${proximo.bloqueio})` : '';
        tit = `${rot} · próxima${quando}${bloq}\n\n${proximo.texto || futuros[cod] || 'O texto exato aparece quando o banco tiver a migration 0050.'}`;
      } else {
        cls = 'off';
        tit = `${rot} · futura\n\n${futuros[cod] || 'O texto depende da etapa da conversa na hora do envio.'}`;
      }
      return `<span class="cad-b ${cls}" title="${esc(tit)}" tabindex="0">${esc(cod)}</span>`;
    });
    return `<span class="cad-bolas com-ajuda" aria-label="Cadência da Mari">${itens.join('')}</span>`;
  }

  // ---------- service worker ----------
  if ('serviceWorker' in navigator && location.protocol === 'https:') {
    navigator.serviceWorker.register('sw.js').catch(() => {});
  }

  window.NG = {
    origemTxt, PARCEIRO_STATUS, PARCEIRO_FORMA, MOTIVOS_CONFERENCIA, CONFERENCIA_STATUS, PAGAMENTO_TIPO, PAGAMENTO_STATUS,
    sb, TZ, STATUS, STATUS_MAP, ETAPAS, etapaDe, ORIGENS, FORMAS, SEGMENTOS, BIOMETRIA, CREDITO, VIAB_NIO, PORTAL_PAP_NOVO_PEDIDO, opcoes, PERFIS, MOTIVOS_SAIDA,
    VIAB_PORTAL_REGISTRO, portalViavel, fmtCep, ajuda,
    esc, fmtData, fmtDataAno, fmtHora, fmtDataHora, fmtDiaSemana, fmtMoeda, fmtDiaISO, fmtNum, fmtHoras, diaSP, diasEntre, janela, primeiroNome,
    documentoValido, soDigitos, msgErro, toast, botaoAtualizar, momento, MOMENTOS, JORNADA, jornada, passoJornada, ordemJornada, NIVEL_COR, TEXTOS_COMISSAO, textoComissao, dica, dicaTxt, rotulo, avisoDowngrade,
    PERIODOS, periodo, noPeriodo, somaDias, filtroPeriodo, kpi, abasPilulas, ligarOrdenacao, ordenar, pilulaEtapa, proxPasso, quando, gaveta,
    proximoPasso, ultimosContatos, abrirVenda, PARADAS, paradaDe, haQuanto,   // onda 2.1: faixa do Painel
    selosFicha,   // onda 3.1: ficha única (só aviso)
    CHATWOOT_NIO_ACCOUNT, linkChatwoot,
    QUEM_DESTRAVA, RESULTADO_PENDENCIA, pendencia, diaCurto,   // 0064: "Em espera"
    DFV_OPCOES, DFV_OK, TEXTOS_DFV, DFV_MAPA, DFV_RESULTADO, DFV_ROTULO, dadosDfv, dfvValido, seloDfv, dfvCampos, dfvLer, ligarLinkDfv,
    dfvConsultar, dfvPreencher, ligarDfvAuto, exigirLogin, sair, modal,
    moverStatus,   // arrastar no Quadro (modais); na ficha, os mesmos campos em formulário dentro dela
    carregarUsuarios, preencherSelect,
    tplCadencia, renderTpl, nomeCadencia, cadEnviados, cadBolinhas,   // prompt 28: bolinhas da cadência
    get usuario() { return usuarioAtual; },
  };
})();
