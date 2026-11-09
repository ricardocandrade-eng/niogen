/* NIOGEN | docs/assets/ficha.js | 05/11/2026 00h30 — Claude Code, rodada noturna de layout
 * Ficha da venda: UM componente para a gaveta larga (Vendas, Instalações, Painel, Mari) e para a página cheia (venda.html?id=).
 * URL: #venda=<id> abre a ficha; o voltar do navegador fecha; link com o hash abre direto.
 * Ordem: cabeçalho fixo (nome, local, etapa, origem, vendedor, "Mover para…", menu ⋯) · faixa "Próximo passo" com o botão que
 * resolve o passo (o formulário abre DENTRO da ficha) · linha do tempo das etapas · blocos recolhíveis com resumo de uma linha.
 * Gravação: os mesmos updates de antes (vendas / contatos_cliente) com os mesmos campos; as travas são do banco (triggers)
 * e a mensagem do RAISE volta como toast. Nada de regra de negócio aqui.
 * 06/11 (prompt 25): cartão da CONFERÊNCIA DE QUALIDADE (só origem parceiro_pap), origem "Parceiro PAP · nome" e "Gerar lançamentos".
 * 06/11 (prompt 27): cartão VIABILIDADE com o portal PAP na frente (Consultar no portal · Registrar resultado; DFV vira "pista")
 * e cartão DADOS PARA O PORTAL PAP (campos na ordem das etapas do Novo Pedido, copiar por campo e Copiar tudo; em
 * eventos_venda só o fato "dados copiados"). Os dois aparecem em Qualificado e em Saída.
 * 08/11 (0064): cartão PENDÊNCIA ("Em espera": abrir · adiar · encerrar por RPC, só admin/backoffice; atalho para a Saída sugerida;
 * histórico) logo abaixo do próximo passo; eventos tipo "pendencia" no histórico.
 * Depende de app.js (NG). Uso: <script src="assets/ficha.js"></script>; NGFicha.abrir(id) · NGFicha.aoMudar(fn) · NGFicha.pagina(el, id).
 */
(function () {
  'use strict';
  const { esc, STATUS_MAP, ORIGENS, FORMAS, SEGMENTOS } = NG;
  const HASH = /^#venda=([0-9a-f-]{36})$/i;

  let modo = 'gaveta';     // 'gaveta' | 'pagina'
  let gav = null;          // <aside class="gaveta larga">
  let raiz = null;         // onde a ficha é desenhada
  let d = null;            // dados da venda aberta
  let idAtual = null;
  let abertos = null;      // blocos abertos (null = o padrão: só o do próximo passo)
  let edicao = null;       // bloco em edição
  let formAtivo = null;    // formulário aberto na faixa do próximo passo
  let empurrou = false;    // a ficha criou a entrada no histórico (fechar = voltar)
  let consultarDfv = null; // consulta da base DFV do bloco Endereço em edição
  let usuariosCache = null;
  let convAberta = false;  // orelha da conversa da Mari aberta (painel à esquerda da ficha)
  let conv = null;         // { id, turnos, erro } — carregada na 1ª abertura
  let convFim = false;     // rolar a conversa até a última mensagem no próximo desenho
  let saidaPreset = null;  // 0064: motivo de Saída sugerido pela pendência (pré-seleciona o formulário de Saída)
  let motivosCache = null; // 0064: config_motivos_pendencia (ativos)
  const ouvintes = [];

  // ---------- formatação local ----------
  const fmtTel = (t) => {
    let s = NG.soDigitos(t);
    if (!s) return '—';
    if ((s.length === 12 || s.length === 13) && s.startsWith('55')) s = s.slice(2);
    if (s.length === 11) return `(${s.slice(0, 2)}) ${s.slice(2, 7)}-${s.slice(7)}`;
    if (s.length === 10) return `(${s.slice(0, 2)}) ${s.slice(2, 6)}-${s.slice(6)}`;
    return s;
  };
  const fmtDoc = (x) => {
    const s = NG.soDigitos(x);
    if (s.length === 11) return `${s.slice(0, 3)}.${s.slice(3, 6)}.${s.slice(6, 9)}-${s.slice(9)}`;
    if (s.length === 14) return `${s.slice(0, 2)}.${s.slice(2, 5)}.${s.slice(5, 8)}/${s.slice(8, 12)}-${s.slice(12)}`;
    return s || '—';
  };
  const linha = (rot, val) => `<div class="d-l"><span>${esc(rot)}</span><b>${val}</b></div>`;
  const diaSemanaData = (x) => `${NG.fmtDiaSemana(x)} ${NG.fmtData(x)}`;

  // ---------- histórico de eventos (o mesmo texto da venda.html até 04/11) ----------
  const TITULOS = {
    '0_qualificado': 'Qualificada', '1_vendido': 'Vendida · biometria validada', '2_aguardando_instalacao': 'Aguardando instalação',
    '3_instalado': 'Instalada', '4_ativo_provisorio': 'Ativa', '5_comissao_firme': 'Ativa', saida: 'Saída',
  };
  const CANAIS = { whatsapp: 'WhatsApp', ligacao: 'Ligação', presencial: 'Presencial' };

  function eventoHtml(e, v) {
    const dt = e.detalhe || {};
    const quem = e.autor ? ` · ${esc(e.autor)}` : '';
    let titulo = '', texto = '', cor = '';
    if (e.tipo === 'criada') {
      titulo = `Entrou como ${STATUS_MAP[dt.status]?.curto || dt.status}`;
      texto = `${NG.fmtDataHora(e.criado_em)}${quem} · origem ${esc(ORIGENS[dt.origem] || dt.origem || '')}`;
    } else if (e.tipo === 'status') {
      titulo = TITULOS[dt.para] || dt.para;
      cor = dt.para === 'saida' ? 'bad' : '';
      texto = `${NG.fmtDataHora(e.criado_em)}${quem} · de ${esc(STATUS_MAP[dt.de]?.curto || dt.de)}`;
      if (dt.para === '1_vendido' && v.nio_pedido) texto += ` · pedido #${esc(v.nio_pedido)}`;
      if (dt.para === '2_aguardando_instalacao' && v.vendido_em && v.agendamento_registrado_em) {
        const h = (new Date(v.agendamento_registrado_em) - new Date(v.vendido_em)) / 3600000;
        titulo = `Instalação agendada em ${NG.fmtHoras(h)}`;
        texto += h <= 4 ? ' · dentro do limite de 4 h' : ' · fora do limite de 4 h';
        if (h > 4) cor = 'warn';
      }
      if (dt.motivo) texto += ` · ${esc(dt.motivo)}`;
    } else if (e.tipo === 'agendamento') {
      titulo = dt.reagendamento ? 'Reagendada' : 'Data da instalação';
      cor = dt.reagendamento ? 'warn' : '';
      texto = `${NG.fmtDataHora(e.criado_em)}${quem} · para ${diaSemanaData(dt.para)} ${NG.janela(dt.para)}`;
    } else if (e.tipo === 'contato') {
      titulo = `Contato · ${CANAIS[dt.canal] || dt.canal} · ${dt.direcao === 'entrada' ? 'recebido' : 'enviado'}`;
      texto = `${NG.fmtDataHora(e.criado_em)} · por ${esc(dt.por || '')}${dt.resumo ? ' · ' + esc(dt.resumo) : ''}`;
    } else if (e.tipo === 'osab') {
      titulo = `OSAB · ${dt.situacao || 'sem situação'}`;
      cor = dt.para === 'saida' ? 'bad' : dt.pendencia_cod ? 'warn' : '';
      const p = [dt.dt_ref ? `DT_REF ${dt.dt_ref.split('-').reverse().join('/')}` : '', dt.para ? `${STATUS_MAP[dt.de]?.curto || dt.de} → ${STATUS_MAP[dt.para]?.curto || dt.para}` : '',
        dt.pendencia_cod || dt.pendencia_desc ? `pendência ${[dt.pendencia_cod, dt.pendencia_desc].filter(Boolean).join(' · ')}` : '',
        dt.venda_valida === false ? 'venda inválida' : ''].filter(Boolean);
      texto = `${NG.fmtDataHora(e.criado_em)}${quem}${p.length ? ' · ' + esc(p.join(' · ')) : ''}`;
    } else if (e.tipo === 'dfv_consulta') {
      const ok = ['viavel', 'viavel_predio'].includes(dt.viabilidade);
      titulo = `DFV · ${NG.DFV_OPCOES[dt.viabilidade] || dt.viabilidade}`;
      cor = ok ? '' : dt.viabilidade === 'nao_consultado' ? 'warn' : 'bad';
      const extra = [dt.faixa_credito ? `crédito ${dt.faixa_credito} %` : '', dt.classificacao ? dt.classificacao.toLowerCase() : '',
        dt.hp_livre != null ? `HP livre ${dt.hp_livre}` : '', dt.hcs != null ? `HCs ${dt.hcs}` : ''].filter(Boolean);
      if (dt.origem === 'auto') extra.unshift(`automático · base de ${dt.particao ? NG.fmtDiaISO(dt.particao).slice(0, 5) : '—'}`);
      else if (dt.origem === 'manual') extra.unshift('manual');
      texto = `${NG.fmtDataHora(dt.consultado_em || e.criado_em)}${quem}${extra.length ? ' · ' + esc(extra.join(' · ')) : ''}`;
    } else if (e.tipo === 'dfv_endereco_ocupado') {
      titulo = 'DFV: endereço já tem Nio';
      cor = 'bad';
      texto = `${NG.fmtDataHora(e.criado_em)}${quem} · confirmar com o cliente e no portal (só é saída "Já é cliente Nio" se ele confirmar)`;
    } else if (e.tipo === 'alerta_recompra') {
      titulo = 'Possível recompra · multa de R$ 500 por pedido';
      cor = 'warn';
      texto = `${NG.fmtDataHora(e.criado_em)}${quem} · endereço já teve ${dt.anteriores || 1} venda${dt.anteriores > 1 ? 's' : ''} que saiu ou foi cancelada · confirmar com o Ricardo`;
    } else if (e.tipo === 'dfv_dispensa') {
      titulo = 'DFV dispensado (admin)';
      cor = 'warn';
      texto = `${NG.fmtDataHora(e.criado_em)}${quem} · ${esc(dt.motivo || '')}`;
    } else if (e.tipo === 'biometria_link') {
      // 0027: link do portal colado na conversa do Chatwoot (fallback desde a 0032: com pedido registrado, só referência).
      titulo = dt.so_referencia ? 'Link da biometria guardado (Chatwoot)' : dt.reenvio ? 'Link da biometria reenviado (Chatwoot)' : 'Link da biometria colado (Chatwoot)';
      texto = `${NG.fmtDataHora(e.criado_em)} · gravado automaticamente da conversa · ${dt.so_referencia ? 'só referência (a contagem é do pedido)' : 'biometria pendente (sem pedido registrado)'}`;
    } else if (e.tipo === 'conferencia') {
      // Conferência de qualidade da venda de parceiro (0038). A observação é INTERNA: nunca vai para o parceiro.
      titulo = `Conferência · ${NG.CONFERENCIA_STATUS[dt.para] || dt.para}`;
      cor = ['reprovada', 'devolvida'].includes(dt.para) ? 'bad' : dt.para === 'pendente' ? 'warn' : '';
      texto = `${NG.fmtDataHora(e.criado_em)}${quem}${dt.motivo ? ' · ' + esc(NG.MOTIVOS_CONFERENCIA[dt.motivo] || dt.motivo) : ''}${dt.obs ? ' · obs. interna: ' + esc(dt.obs) : ''}`;
    } else if (e.tipo === 'parceiro_sem_comissao') {
      titulo = 'Instalada sem comissão configurada para o parceiro';
      cor = 'warn';
      texto = `${NG.fmtDataHora(e.criado_em)} · configure o valor do plano em Configurações › Programa Parceiro e use "Gerar lançamentos"`;
    } else if (e.tipo === 'portal_dados_copiados') {
      // Prompt 27: só o fato (quem, quando) — o conteúdo copiado nunca é gravado.
      titulo = 'Dados copiados para o portal PAP';
      texto = `${NG.fmtDataHora(e.criado_em)}${quem}`;
    } else if (e.tipo === 'pendencia') {
      // 0064: pendência com terceiro ("Em espera").
      const nome = dt.nome || (((d && d.motivos) || []).find((m) => m.codigo === dt.motivo) || {}).nome || dt.motivo || '';
      if (dt.acao === 'aberta') {
        titulo = `Em espera · ${nome}`;
        cor = 'warn';
        texto = `${NG.fmtDataHora(e.criado_em)}${quem} · destrava: ${esc(NG.QUEM_DESTRAVA[dt.quem] || dt.quem || '—')} · revisar ${esc(NG.diaCurto(dt.revisar_em))}${dt.descricao ? ' · ' + esc(dt.descricao) : ''}`;
      } else if (dt.acao === 'adiada') {
        titulo = `Revisão adiada (${dt.revisoes}×)`;
        cor = dt.revisoes >= 2 ? 'bad' : 'warn';
        texto = `${NG.fmtDataHora(e.criado_em)}${quem} · ${esc(NG.diaCurto(dt.de))} → ${esc(NG.diaCurto(dt.para))}${dt.nota ? ' · ' + esc(dt.nota) : ''}`;
      } else {
        titulo = `Pendência encerrada · ${NG.RESULTADO_PENDENCIA[dt.resultado] || dt.resultado}`;
        cor = dt.resultado === 'saida' ? 'bad' : '';
        texto = `${NG.fmtDataHora(e.criado_em)}${quem}${dt.automatica ? ' · automática (a venda foi para Saída)' : ''}${dt.dias != null ? ` · ${dt.dias} dia${dt.dias === 1 ? '' : 's'} em espera` : ''}${dt.nota ? ' · ' + esc(dt.nota) : ''}`;
      }
    } else if (e.tipo === 'osab_venda_invalida') {
      titulo = 'Nio: venda inválida / risco de multa ou estorno';
      cor = 'bad';
      texto = `${NG.fmtDataHora(e.criado_em)} · ${esc([dt.pendencia_desc, dt.motivo].filter(Boolean).join(' · ') || 'fg_venda_valida = 0')}`;
    } else {
      titulo = e.tipo;
      texto = `${NG.fmtDataHora(e.criado_em)}${quem}`;
    }
    return `<div class="tl-item"><span class="tl-dot ${cor}"></span><div class="tl-txt"><strong>${esc(titulo)}</strong><span>${texto}</span></div></div>`;
  }

  function proximosMarcos(v) {
    const m = [];
    if (v.status === '1_vendido' && v.vendido_em) m.push(`agendar até ${NG.fmtDataHora(new Date(new Date(v.vendido_em).getTime() + 4 * 3600000))}`);
    if (v.instalacao_agendada_para && !v.instalado_em) m.push(`instalação ${diaSemanaData(v.instalacao_agendada_para)} ${NG.janela(v.instalacao_agendada_para)}`);
    if (v.docs_prazo_em && !v.docs_entregues_em) m.push(`docs à Nio até ${NG.fmtData(v.docs_prazo_em)}`);
    if (NG.avisoDowngrade(v)) m.push(NG.avisoDowngrade(v));
    if (v.interesse_futuro_em) m.push(`interesse futuro volta ${NG.fmtDiaISO(v.interesse_futuro_em)}`);
    if (!m.length) return '';
    return `<div class="tl-item"><span class="tl-dot futuro"></span><div class="tl-txt"><strong class="apagado">Próximos marcos</strong><span>${esc(m.join(' · '))}</span></div></div>`;
  }

  // ---------- dados ----------
  async function carregar(id) {
    const perfil = (NG.usuario || {}).perfil;
    const [rv, re, rl, ra, rc, rk, ru] = await Promise.all([
      NG.sb.from('v_funil').select('*').eq('id', id).maybeSingle(),
      NG.sb.from('eventos_venda').select('*').eq('venda_id', id).order('criado_em'),
      NG.sb.from('v_contatos_limite').select('*').eq('venda_id', id).maybeSingle(),
      NG.sb.from('venda_adicionais').select('qtd, comissao_prevista, config_adicionais(nome, preco)').eq('venda_id', id).order('id'),
      // Conversa da Mari que gerou a venda (a tabela só abre para admin/backoffice; para os outros vem vazia).
      ['admin', 'backoffice'].includes(perfil)
        ? NG.sb.from('mari_conversas').select('id, chatwoot_conversation_id').eq('venda_id', id).order('created_at', { ascending: false }).limit(1)
        : Promise.resolve({ data: [] }),
      NG.sb.from('contatos_cliente').select('id, canal, direcao, por, em, resumo, toque').eq('venda_id', id).order('em', { ascending: false }).limit(30),
      usuariosCache ? Promise.resolve(usuariosCache) : NG.carregarUsuarios(),
    ]);
    if (rv.error || !rv.data) return { erro: rv.error ? NG.msgErro(rv.error) : 'Venda não encontrada (ou sem permissão para vê-la).' };
    usuariosCache = ru;
    const v = rv.data;
    // 0048 (prompt 27): v_funil congela v.* — quem registrou a viabilidade do portal e a referência vêm da tabela.
    const rx27 = await NG.sb.from('vendas').select('nio_viab_por, ponto_referencia').eq('id', id).maybeSingle();
    if (rx27.data) Object.assign(v, rx27.data);
    let nomeCurto = null;
    if (v.plano_id) {
      const rp = await NG.sb.from('config_planos').select('nome_curto').eq('id', v.plano_id).maybeSingle();
      nomeCurto = (rp.data || {}).nome_curto || null;
    }
    const nomeDe = Object.fromEntries(ru.map((u) => [u.id, u.nome]));
    // Venda de parceiro (admin/backoffice): máximo de tentativas, comissão configurada e se o lançamento já saiu.
    let parc = null;
    if (v.origem === 'parceiro_pap' && ['admin', 'backoffice'].includes(perfil)) {
      // Obs. interna, quem e quando aprovou não estão em v_funil (só prazo, status e motivo): lê da tabela.
      const rx = await NG.sb.from('vendas').select('conferencia_obs, conferencia_em, conferencia_por').eq('id', id).maybeSingle();
      if (rx.data) Object.assign(v, rx.data);
      const [rcfg, rcom, rpag] = await Promise.all([
        NG.sb.from('config_parceiros').select('conferencia_max_tentativas').maybeSingle(),
        v.plano_id ? NG.sb.from('parceiro_comissao').select('parceiro_id, valor').eq('plano_id', v.plano_id) : Promise.resolve({ data: [] }),
        NG.sb.from('parceiro_pagamentos').select('id, tipo, status').eq('venda_id', id),
      ]);
      const linhasCom = (rcom.data || []).filter((x) => x.parceiro_id === v.parceiro_id || x.parceiro_id === null);
      const doParc = linhasCom.find((x) => x.parceiro_id === v.parceiro_id);
      const padrao = linhasCom.find((x) => x.parceiro_id === null);
      const valor = doParc ? Number(doParc.valor) : padrao ? Number(padrao.valor) : null;
      parc = {
        max: (rcfg.data || {}).conferencia_max_tentativas || 3,
        comissaoValor: valor,
        temPagamentoComissao: (rpag.data || []).some((x) => x.tipo === 'comissao'),
      };
    }
    const abertura = [...(re.data || [])].reverse().find((e) => e.tipo === 'conferencia' && (e.detalhe || {}).para === 'pendente');
    const desde = abertura ? new Date(abertura.criado_em) : new Date(v.criado_em);
    const semResposta = (rk.data || []).filter((c) => c.toque === 'CONF_SEM_RESPOSTA' && new Date(c.em) >= desde).length;
    // Prompt 28: avisos automáticos da Mari para a venda (BIO1 · BIO3 · INSTALACAO · VESPERA) — só admin/backoffice.
    const convId = ((rc.data || [])[0] || {}).id || null;
    let cad = null;
    if (convId) {
      const [rkc, rtc, tpl] = await Promise.all([
        NG.sb.from('v_mari_cadencia').select('*').eq('conversa_id', convId).maybeSingle(),
        NG.sb.from('mari_turnos').select('texto, tags, created_at').eq('conversa_id', convId).eq('papel', 'mari')
          .not('tags->>cadencia', 'is', null).order('created_at'),
        NG.tplCadencia(),
      ]);
      cad = { k: rkc.error ? null : rkc.data, enviados: NG.cadEnviados(rtc.data), tpl: tpl || {} };
    }
    // 0064: pendências da venda (aberta + histórico) e a lista de motivos (config). 0076: avisos de ficha única (só aviso).
    const [rph, rmot, rav] = await Promise.all([
      NG.sb.from('venda_pendencias').select('*').eq('venda_id', id).order('aberta_em', { ascending: false }),
      motivosCache ? Promise.resolve({ data: motivosCache }) : NG.sb.from('config_motivos_pendencia').select('*').eq('ativo', true).order('ordem'),
      NG.sb.rpc('ficha_avisos', { p_venda: id }),
    ]);
    if (!rmot.error) motivosCache = rmot.data || [];
    const pendHist = (rph.data || []).filter((p) => p.encerrada_em).map((p) => ({ ...p, autor: nomeDe[p.encerrada_por] || nomeDe[p.aberta_por] }));
    const pendAberta = (rph.data || []).find((p) => !p.encerrada_em) || null;
    return {
      avisos: rav && !rav.error ? rav.data : null,
      pend: NG.pendencia(v), pendAberta, pendHist, motivos: motivosCache || [],
      cad,
      parc, semResposta,
      v,
      eventos: (re.data || []).map((e) => ({ ...e, autor: nomeDe[e.criado_por] })),
      lim: rl.data || { hoje: 0, mes: 0 },
      adics: ra.data || [],
      conversaId: ((rc.data || [])[0] || {}).id || null,
      chatwoot: NG.linkChatwoot(((rc.data || [])[0] || {}).chatwoot_conversation_id),
      contatos: rk.data || [],
      usuarios: ru,
      nomeCurto,
    };
  }

  // ---------- próximo passo: botão e formulário que resolvem ----------
  const BOTAO = {
    pedido: 'Registrar venda', portal: 'Registrar o pedido do portal', bio_status: 'Atualizar biometria', contato: 'Registrar contato',
    dfv: 'Consultar cobertura', sem_cobertura: 'Encerrar sem cobertura', agendar: 'Agendar instalação',
    reagendar: 'Reagendar', docs: 'Registrar envio dos documentos', viab: 'Registrar resultado do portal',
    pendencia: 'Ver a pendência',
  };
  // Bloco ligado a cada passo (é o único que abre sozinho).
  const BLOCO_DO_PASSO = {
    pedido: 'pedido', portal: 'pedido', bio_status: 'pedido', invalida: 'pedido', contato: 'contatos', dfv: 'endereco', sem_cobertura: 'endereco',
    agendar: 'instalacao', reagendar: 'instalacao', docs: 'instalacao',
  };
  function blocoPadrao(v, pr) {
    if (pr.resolver && BLOCO_DO_PASSO[pr.resolver]) return BLOCO_DO_PASSO[pr.resolver];
    if (v.status === 'saida') return 'historico';
    if (NG.etapaDe(v.status).id === 'ativo') return 'comissao';
    return null;
  }

  const hojeISO = () => NG.diaSP();
  const amanhaISO = () => NG.somaDias(NG.diaSP(), 1);
  // 0064: próximo dia útil (pula domingo) depois de base (ou de hoje) — sugestão da data de revisão da pendência.
  const proximoDiaUtil = (base) => {
    let x = NG.somaDias(base && base >= hojeISO() ? base : hojeISO(), 1);
    while (new Date(`${x}T12:00:00-03:00`).getUTCDay() === 0) x = NG.somaDias(x, 1);
    return x;
  };
  const periodoDe = (ts) => (ts && Number(new Intl.DateTimeFormat('pt-BR', { timeZone: NG.TZ, hour: '2-digit', hour12: false }).format(new Date(ts))) >= 12 ? '13:00' : '08:00');
  const campoData = (rot, nome, valor, extra = '') => `<label class="campo">${esc(rot)}<input type="date" name="${nome}" value="${esc(valor || '')}" ${extra}></label>`;
  const campoPeriodo = (nome, atual) => `<label class="campo">Período<select name="${nome}">
      <option value="08:00" ${atual === '08:00' ? 'selected' : ''}>Manhã · 8–12h</option>
      <option value="13:00" ${atual === '13:00' ? 'selected' : ''}>Tarde · 13–17h</option></select></label>`;
  const optBiometria = (atual) => NG.opcoes(NG.BIOMETRIA, atual);
  // Venda remota (05/11): pedido aberto no portal PAP (perfil BO) e biometria por LINK ao cliente.
  const botoesPortal = `<div class="f-form-acoes f-portal"><a class="btn btn-ghost" href="${NG.PORTAL_PAP_NOVO_PEDIDO}" target="_blank" rel="noopener">Abrir no portal PAP ↗</a>
      <button type="button" class="btn btn-ghost" data-f="copiar-endereco">Copiar endereço para o portal</button></div>`;
  const enderecoPortal = (v) => [`CEP ${v.cep || '?'}`, `nº ${v.numero || '?'}${v.complemento ? ` · ${v.complemento}` : ''}`,
    [v.logradouro, v.bairro, [v.cidade, v.uf].filter(Boolean).join('/')].filter(Boolean).join(', '),
    'referência: informado no atendimento'].join(' · ');
  const turnoDe = (fd, campo = 'periodo') => (fd.get(campo) === '13:00' ? 'tarde' : 'manha');
  const TURNO = { manha: 'manhã', tarde: 'tarde' };
  const acoesForm = (rotulo) => `<div class="f-form-acoes"><button type="button" class="btn btn-ghost" data-f="cancelar">Cancelar</button><button type="submit" class="btn btn-acc">${esc(rotulo)}</button></div>`;
  const formWrap = (id, titulo, texto, corpo, rotulo) => `<form class="f-formulario" data-form="${id}" novalidate>
      <h3>${esc(titulo)}</h3>${texto ? `<p>${texto}</p>` : ''}${corpo}${acoesForm(rotulo || 'Salvar')}</form>`;

  const formMotivoConf = () => `<label class="campo">Motivo (o parceiro vê este texto)<select name="motivo_conf"><option value="">Escolher o motivo…</option>${Object.entries(NG.MOTIVOS_CONFERENCIA).map(([k, t]) => `<option value="${k}">${esc(t)}</option>`).join('')}</select></label>
      <label class="campo">Observação interna <span class="nota-campo">(não aparece para o parceiro)</span><textarea name="obs_conf" maxlength="500"></textarea></label>`;
  // Formulários (faixa do próximo passo, "Mover para…" e "Editar" dos blocos). Cada um grava o que a tela antiga gravava.
  const FORMS = {
    // Qualificado → Vendido (era o modal "Registrar venda": pedido + biometria; a trava do banco confere DFV e o resto).
    pedido: (v) => formWrap('pedido', 'Registrar venda', 'Para virar "Vendido" a Nio exige o nº do pedido do portal PAP e a biometria validada (link). O banco confere também a viabilidade do portal (Viável, &lt; 7 dias) — o DFV não libera.',
      `<div class="grade2"><label class="campo">Nº do pedido (portal PAP)<input type="text" name="pedido" value="${esc(v.nio_pedido || '')}" autocomplete="off" autofocus></label>
       <label class="campo">Biometria<select name="biometria">${optBiometria(v.biometria_status === 'validada' ? 'validada' : v.biometria_status)}</select></label></div>`, 'Registrar venda'),
    // Venda remota: o nosso time abre o pedido no portal e roda o crédito. Prompt 19: o link da biometria é disparado pela
    // própria Nio (WhatsApp + e-mail) na hora do pedido — salvar o nº do pedido marca a biometria pendente e a contagem
    // 24/72 h e o D+1 partem dali (trigger vendas_antes_biometria, 0032). O backoffice só avisa o cliente na conversa.
    portal: (v) => formWrap('portal', 'Pedido no portal',
      'Abra o pedido no portal PAP (perfil BO) com o endereço abaixo e rode a análise de crédito. Ao concluir o pedido, a própria Nio manda ao cliente o link da biometria por WhatsApp e por e-mail — nós não mandamos link. Salve aqui o nº do pedido (a contagem de 24/72 h começa agora) e avise o cliente na conversa. Nunca conclua pedido com CPF de teste.',
      `${botoesPortal}<span class="nota-campo mono">${esc(enderecoPortal(v))}</span>
       <div class="grade2"><label class="campo">Nº do pedido (portal PAP)<input type="text" name="pedido" value="${esc(v.nio_pedido || '')}" autocomplete="off" autofocus></label>
       <label class="campo">Análise de crédito<select name="credito">${NG.opcoes(NG.CREDITO, v.credito_resultado)}</select></label></div>
       <label class="campo">Link da biometria (opcional — só referência; quem manda é a Nio)<input type="url" name="link" value="${esc(v.biometria_link || '')}" placeholder="https://…" autocomplete="off"></label>`, 'Salvar'),
    bio_status: (v) => formWrap('bio_status', 'Biometria e crédito', 'O portal mostra a biometria como Pendente, com Risco ou Validada (Consulta OS). Validada + nº do pedido libera "Registrar venda".',
      `${botoesPortal}<div class="grade2"><label class="campo">Biometria<select name="biometria">${optBiometria(v.biometria_status)}</select></label>
       <label class="campo">Análise de crédito<select name="credito">${NG.opcoes(NG.CREDITO, v.credito_resultado)}</select></label></div>`, 'Salvar'),
    // Contato (teto do contrato: 2/dia e 15/mês, só saída conta; exceção = o cliente pediu ou autorizou).
    contato: () => formWrap('contato', 'Registrar contato', `Hoje ${d.lim.hoje} de 2 · mês ${d.lim.mes} de 15 · seg–sex 9–21, sáb 10–16, nunca domingo ou feriado.`,
      `<div class="grade2"><label class="campo">Canal<select name="canal"><option value="whatsapp">WhatsApp</option><option value="ligacao">Ligação</option><option value="presencial">Presencial</option></select></label>
       <label class="campo">Direção<select name="direcao"><option value="saida">Nós chamamos o cliente</option><option value="entrada">O cliente nos chamou</option></select></label></div>
       <label class="campo">Resumo<textarea name="resumo" maxlength="500"></textarea></label>
       <label class="check"><input type="checkbox" name="autorizado"> O cliente pediu ou autorizou este contato</label>`, 'Registrar contato'),
    // Instalação: agendar (Vendido → Aguardando) ou reagendar; limpa a pendência da Nio (os campos do antigo NG.registrarAgendamento).
    agendar: (v) => formWrap('agendar', v.instalacao_agendada_para ? 'Reagendar instalação' : 'Agendar instalação',
      v.status === '1_vendido' ? 'Contrato: agendar em até 4 h depois da venda. Salvar leva a venda para "Aguardando".' : '',
      `<div class="grade2">${campoData('Data da instalação', 'dia', v.instalacao_agendada_para ? NG.diaSP(v.instalacao_agendada_para) : amanhaISO(), 'required')}
       ${campoPeriodo('periodo', v.instalacao_agendada_para ? periodoDe(v.instalacao_agendada_para) : '08:00')}</div>`, v.instalacao_agendada_para ? 'Reagendar' : 'Agendar'),
    docs: () => formWrap('docs', 'Documentos entregues à Nio', 'Contrato: termos assinados e documentação em até 15 dias após a habilitação.',
      campoData('Entregues em', 'dia', hojeISO(), 'required'), 'Registrar'),
    saida: () => formWrap('saida', 'Encerrar com motivo', saidaPreset ? `Motivo sugerido pela pendência: <b>${esc(saidaPreset)}</b>. Confira e registre.` : '',
      `<label class="campo">Motivo<select name="motivo" required><option value="">Escolher…</option>${NG.MOTIVOS_SAIDA.map((m) => `<option${m === saidaPreset ? ' selected' : ''}>${esc(m)}</option>`).join('')}</select></label>
       <label class="campo" data-futuro hidden>Volta em<input type="date" name="futuro"></label>`, 'Registrar saída'),
    sem_cobertura: (v) => formWrap('sem_cobertura', v.dfv_resultado === 'endereco_ocupado' ? 'Encerrar: já é cliente Nio' : 'Encerrar: sem cobertura',
      v.dfv_resultado === 'endereco_ocupado' ? 'Use só se o cliente confirmou que já tem Nio (vender seria estorno 100 %). A venda vai para Saída "Já é cliente Nio".'
        : 'Use só depois de conferir no portal (com variações de CEP, rua e número) que não há viabilidade. A venda vai para Saída "Sem cobertura" e volta para a fila em 90 dias.', '', 'Encerrar'),
    // Conferência de qualidade (venda de parceiro): motivo da lista fechada (0038) + observação INTERNA.
    conf_reprovar: () => formWrap('conf_reprovar', 'Reprovar a venda do parceiro',
      'A venda vai para Saída com este motivo e o parceiro vê só o motivo da lista. Suspeita de fraude: avise o Ricardo na hora.', formMotivoConf(), 'Reprovar e encerrar'),
    conf_devolver: () => formWrap('conf_devolver', 'Devolver ao parceiro',
      'A venda volta ao parceiro com o motivo da lista para ele corrigir e reenviar. Continua em Qualificado.', formMotivoConf(), 'Devolver ao parceiro'),
    // Viabilidade do portal (prompt 27): os 4 estados; "Não consultado" apaga o registro. Abre dentro do cartão Viabilidade.
    viab: (v) => formWrap('viab', 'Registrar o resultado do portal', 'O que o portal PAP respondeu na consulta de viabilidade (etapa 2 do Novo Pedido). Só "Viável" libera a venda; "Sem viabilidade" ou "não encontrado" = tente variações de CEP, rua e número antes de encerrar.',
      `<div class="grade2"><label class="campo">Resultado no portal<select name="viab" autofocus>${NG.opcoes(NG.VIAB_PORTAL_REGISTRO, ['viavel', 'sem_viabilidade', 'nao_encontrado'].includes(v.nio_viab_resultado) ? v.nio_viab_resultado : '', 'Não consultado')}</select></label>
       <label class="campo">Velocidade máxima (opcional)<input type="text" name="vel" value="${esc(v.nio_viab_velocidade || '')}" placeholder="1GB"></label>
       <label class="campo">Interesse no portal (opcional)<input type="text" name="interesse" value="${esc(v.nio_viab_interesse_id || '')}" autocomplete="off"></label>
       <label class="campo">Como a Nio cadastrou o endereço (opcional)<input type="text" name="endp" value="${esc(v.nio_viab_endereco_portal || '')}"></label></div>`, 'Registrar resultado'),
    // Referência (o portal exige na etapa 2). Não entra em trava: o backoffice registra quando o cliente passar.
    ref: (v) => formWrap('ref', 'Ponto de referência', 'Peça ao cliente um ponto de referência perto da casa (o portal exige na etapa 2).',
      `<label class="campo">Referência<input type="text" name="ref" value="${esc(v.ponto_referencia || '')}" maxlength="200" autocomplete="off" autofocus></label>`, 'Salvar referência'),
    // Pendência com terceiro (0064): abrir · adiar · encerrar. Abrem DENTRO do cartão Pendência.
    pend_abrir: () => formWrap('pend_abrir', 'Abrir pendência (venda em espera)',
      'A venda fica na etapa, sai de "Precisam de ação" até a data de revisão e a cadência da Mari pausa. Na data, volta em vermelho para todos.',
      `<label class="campo">Motivo<select name="motivo_pend" required autofocus><option value="">Escolher…</option>${(d.motivos || []).map((m) => `<option value="${esc(m.codigo)}">${esc(m.nome)} · destrava: ${esc(NG.QUEM_DESTRAVA[m.quem_destrava] || m.quem_destrava)}${m.exige_descricao ? ' (descreva)' : ''}</option>`).join('')}</select></label>
       <label class="campo">Descrição <span class="nota-campo">(o que falta e com quem; obrigatória em "Outro motivo")</span><textarea name="descricao" maxlength="500"></textarea></label>
       ${campoData('Revisar em', 'revisar', proximoDiaUtil(), `min="${hojeISO()}" required`)}`, 'Abrir pendência'),
    pend_adiar: () => formWrap('pend_adiar', 'Adiar a revisão',
      d.pend && d.pend.revisoes >= 1 ? 'Já foi adiada antes: com 2 adiamentos o selo mostra "⚠️ adiada 2×" e sobe para o Ricardo decidir.' : 'Use quando o terceiro pediu mais prazo. Fica registrado no histórico.',
      `${campoData('Nova data de revisão', 'revisar', proximoDiaUtil(d.pend ? d.pend.revisar_em : null), `min="${hojeISO()}" required autofocus`)}
       <label class="campo">Nota <span class="nota-campo">(por que adiou)</span><input type="text" name="nota" maxlength="300" autocomplete="off"></label>`, 'Adiar'),
    pend_encerrar: () => formWrap('pend_encerrar', 'Encerrar a pendência',
      '<b>Destravou</b> = o terceiro resolveu e a venda segue · <b>Virou Saída</b> = confirmou o problema (depois você registra a Saída) · <b>Cancelada</b> = aberta por engano.',
      `<label class="campo">Como terminou<select name="resultado" required autofocus><option value="">Escolher…</option>${Object.entries(NG.RESULTADO_PENDENCIA).map(([k, t]) => `<option value="${k}">${esc(t)}</option>`).join('')}</select></label>
       <label class="campo">Nota <span class="nota-campo">(o que o terceiro respondeu)</span><input type="text" name="nota" maxlength="300" autocomplete="off"></label>`, 'Encerrar'),
    // Mover para Aguardando pelo seletor (era o modal de NG.moverStatus: só a data).
    mover_aguardando: (v) => formWrap('mover_aguardando', 'Mover para Aguardando instalação', 'Informe a data combinada com o cliente.',
      `<div class="grade2">${campoData('Data da instalação', 'dia', v.instalacao_agendada_para ? NG.diaSP(v.instalacao_agendada_para) : amanhaISO(), 'required')}
       ${campoPeriodo('periodo', '08:00')}</div>`, 'Mover'),
  };

  // ---------- gravação ----------
  async function gravar(campos, msgOk) {
    const { error } = await NG.sb.from('vendas').update(campos).eq('id', d.v.id);
    if (error) {
      NG.toast(NG.msgErro(error), 'bad');
      // A trava da conferência é do banco; a ficha só explica, em faixa amarela dentro do cartão da conferência.
      if (d.v.origem === 'parceiro_pap' && /confer[eê]ncia/i.test(NG.msgErro(error))) { d.avisoBanco = NG.msgErro(error); render(); }
      return false;
    }
    if (d) { d.avisoBanco = null; d.avisoTent = null; }
    saidaPreset = null;
    NG.toast(msgOk, 'ok');
    formAtivo = null;
    edicao = null;
    if (campos.status) abertos = null;   // mudou a etapa: abre o bloco do novo próximo passo
    await recarregar();
    ouvintes.forEach((f) => { try { f(d && d.v); } catch (e) { /* tela que ouve */ } });
    return true;
  }
  const quandoDe = (fd) => `${fd.get('dia')}T${fd.get('periodo')}:00-03:00`;
  // 0064: as três ações da pendência vão por RPC (SECURITY DEFINER, checam admin/backoffice e gravam em eventos_venda).
  async function rpcPendencia(fn, args, msgOk) {
    const { error } = await NG.sb.rpc(fn, args);
    if (error) { NG.toast(NG.msgErro(error), 'bad'); return false; }
    NG.toast(msgOk, 'ok');
    formAtivo = null;
    abertos = null;
    await recarregar();
    ouvintes.forEach((f) => { try { f(d && d.v); } catch (e) { /* tela que ouve */ } });
    return true;
  }

  const SALVAR = {
    async pedido(fd) {
      const v = d.v;
      const pedido = String(fd.get('pedido') || '').trim();
      const biometria = fd.get('biometria') || null;
      // biometria_em / biometria_validada_em / biometria_link_enviado_em: carimbo do banco (trigger vendas_antes_biometria).
      return gravar({ status: '1_vendido', nio_pedido: pedido || null, biometria_status: biometria },
        `${NG.primeiroNome(v.cliente_nome)} → ${STATUS_MAP['1_vendido'].curto}`);
    },
    async portal(fd) {
      const v = d.v;
      const link = String(fd.get('link') || '').trim();
      if (link && !/^https?:\/\//i.test(link)) { NG.toast('O link da biometria tem que começar com https://', 'bad'); return false; }
      const campos = {
        nio_pedido: String(fd.get('pedido') || '').trim() || null,
        credito_resultado: fd.get('credito') || null,
        biometria_link: link || v.biometria_link || null,
      };
      // Biometria pendente e a contagem: o banco carimba na hora em que o nº do pedido entra (0032).
      const pedidoNovo = campos.nio_pedido && campos.nio_pedido !== (v.nio_pedido || null);
      return gravar(campos, pedidoNovo ? 'Pedido registrado · a Nio manda o link da biometria ao cliente' : 'Pedido no portal atualizado');
    },
    async bio_status(fd) {
      return gravar({ biometria_status: fd.get('biometria') || null, credito_resultado: fd.get('credito') || null }, 'Biometria e crédito atualizados');
    },
    async viab(fd) { return SALVAR.ed_viab(fd); },
    async ref(fd) {
      return gravar({ ponto_referencia: String(fd.get('ref') || '').trim() || null }, 'Referência registrada');
    },
    async ed_viab(fd) {
      const r = fd.get('viab') || null;
      return gravar({
        nio_viab_resultado: r, nio_viab_origem: r ? 'manual' : null, nio_viab_em: r ? new Date().toISOString() : null,
        nio_viab_velocidade: String(fd.get('vel') || '').trim() || null,
        nio_viab_interesse_id: String(fd.get('interesse') || '').trim() || null,
        nio_viab_endereco_portal: String(fd.get('endp') || '').trim() || null,
      }, r ? 'Viabilidade do portal registrada' : 'Viabilidade do portal apagada');
    },
    async contato(fd) {
      const saida = fd.get('direcao') === 'saida';
      if (saida && (d.lim.hoje >= 2 || d.lim.mes >= 15) && !fd.get('autorizado')) {
        NG.toast('Teto do contrato atingido (2/dia ou 15/mês). Só registre se o cliente pediu ou autorizou.', 'bad');
        return false;
      }
      const resumo = String(fd.get('resumo') || '').trim();
      const { error } = await NG.sb.from('contatos_cliente').insert({
        venda_id: d.v.id, canal: fd.get('canal'), direcao: fd.get('direcao'), por: saida ? 'vendedor' : 'cliente',
        resumo: (fd.get('autorizado') ? '[autorizado pelo cliente] ' : '') + resumo || null,
      });
      if (error) { NG.toast(NG.msgErro(error), 'bad'); return false; }
      NG.toast('Contato registrado', 'ok');
      formAtivo = null;
      edicao = null;
      await recarregar();
      ouvintes.forEach((f) => { try { f(d && d.v); } catch (e) { /* */ } });
      return true;
    },
    async agendar(fd) {
      if (!fd.get('dia')) { NG.toast('Informe a data da instalação.', 'bad'); return false; }
      const campos = { instalacao_agendada_para: quandoDe(fd), instalacao_turno: turnoDe(fd), nio_pendencia_cod: null, nio_pendencia_desc: null };
      if (d.v.status === '1_vendido') campos.status = '2_aguardando_instalacao';
      return gravar(campos, `Instalação de ${NG.primeiroNome(d.v.cliente_nome)} agendada`);
    },
    async docs(fd) {
      if (!fd.get('dia')) { NG.toast('Informe a data.', 'bad'); return false; }
      return gravar({ docs_entregues_em: `${fd.get('dia')}T12:00:00-03:00` }, 'Documentos registrados');
    },
    // ---------- pendência com terceiro (0064): só pelas RPCs (escrita direta na tabela é proibida pelo RLS) ----------
    async pend_abrir(fd) {
      const motivo = fd.get('motivo_pend');
      if (!motivo) { NG.toast('Escolha o motivo da pendência.', 'bad'); return false; }
      if (!fd.get('revisar')) { NG.toast('Informe a data de revisão.', 'bad'); return false; }
      return rpcPendencia('pendencia_abrir', { p_venda: d.v.id, p_motivo: motivo, p_descricao: String(fd.get('descricao') || '').trim() || null, p_revisar_em: fd.get('revisar') },
        'Pendência aberta · a venda está em espera e a cadência da Mari pausou');
    },
    async pend_adiar(fd) {
      if (!fd.get('revisar')) { NG.toast('Informe a nova data de revisão.', 'bad'); return false; }
      return rpcPendencia('pendencia_adiar', { p_id: d.pend.id, p_novo_revisar_em: fd.get('revisar'), p_nota: String(fd.get('nota') || '').trim() || null },
        `Revisão adiada para ${NG.diaCurto(fd.get('revisar'))}`);
    },
    async pend_encerrar(fd) {
      const res = fd.get('resultado');
      if (!res) { NG.toast('Escolha como a pendência terminou.', 'bad'); return false; }
      const sugerida = d.pend.saida_sugerida;
      const ok = await rpcPendencia('pendencia_encerrar', { p_id: d.pend.id, p_resultado: res, p_nota: String(fd.get('nota') || '').trim() || null },
        res === 'saida' ? 'Pendência encerrada · agora registre a Saída' : 'Pendência encerrada · a venda voltou ao fluxo normal');
      // "Virou Saída" só registra: a etapa muda pelo formulário de Saída de sempre (já com o motivo sugerido, se houver).
      if (ok && res === 'saida' && d.v.status !== 'saida') { saidaPreset = sugerida || null; formAtivo = 'saida'; render(); }
      return ok;
    },
    async saida(fd) {
      const motivo = fd.get('motivo');
      if (!motivo) { NG.toast('Escolha o motivo da saída.', 'bad'); return false; }
      const futuro = fd.get('futuro');
      if (motivo.startsWith('Interesse futuro') && !futuro) { NG.toast('Informe a data de retorno.', 'bad'); return false; }
      return gravar({ status: 'saida', motivo_saida: motivo, interesse_futuro_em: motivo.startsWith('Interesse futuro') ? futuro : null }, 'Saída registrada');
    },
    async sem_cobertura() {
      if (d.v.dfv_resultado === 'endereco_ocupado') return gravar({ status: 'saida', motivo_saida: 'Já é cliente Nio' }, 'Saída "Já é cliente Nio"');
      const volta = NG.diaSP(new Date(Date.now() + 90 * 86400000));
      return gravar({ status: 'saida', motivo_saida: 'Sem cobertura', interesse_futuro_em: volta }, `Saída "Sem cobertura" · volta em ${NG.fmtDiaISO(volta)}`);
    },
    async conf_reprovar(fd) { return confSalvar(fd, 'reprovada'); },
    async conf_devolver(fd) { return confSalvar(fd, 'devolvida'); },
    async mover_aguardando(fd) {
      if (!fd.get('dia')) { NG.toast('Informe a data da instalação.', 'bad'); return false; }
      return gravar({ status: '2_aguardando_instalacao', instalacao_agendada_para: quandoDe(fd), instalacao_turno: turnoDe(fd) }, `${NG.primeiroNome(d.v.cliente_nome)} → ${STATUS_MAP['2_aguardando_instalacao'].curto}`);
    },
    // ----- edição por bloco -----
    async ed_cliente(fd) {
      const nome = String(fd.get('nome') || '').trim();
      if (!nome) { NG.toast('O nome do cliente é obrigatório.', 'bad'); return false; }
      const doc = NG.soDigitos(fd.get('doc'));
      if (doc && !NG.documentoValido(doc)) { NG.toast('CPF/CNPJ inválido (dígito não confere).', 'bad'); return false; }
      return gravar({
        cliente_nome: nome, cliente_cpf_cnpj: doc || null, trava_cpf_valido: NG.documentoValido(doc),
        cliente_whatsapp: NG.soDigitos(fd.get('whatsapp')) || null, cliente_email: String(fd.get('email') || '').trim() || null,
        trava_contato_confirmado: !!fd.get('contato_ok'),
      }, 'Cliente atualizado');
    },
    async ed_pedido(fd) {
      const link = String(fd.get('link') || '').trim();
      if (link && !/^https?:\/\//i.test(link)) { NG.toast('O link da biometria tem que começar com https://', 'bad'); return false; }
      return gravar({
        nio_pedido: String(fd.get('pedido') || '').trim() || null,
        nio_contrato: String(fd.get('contrato') || '').trim() || null,
        nio_viab_interesse_id: String(fd.get('interesse') || '').trim() || null,
        credito_resultado: fd.get('credito') || null,
        biometria_status: fd.get('biometria') || null,
        biometria_link: link || null,
        vendedor_id: fd.get('vendedor') || null,
      }, 'Pedido e biometria atualizados');
    },
    async ed_instalacao(fd) {
      const v = d.v;
      const campos = {};
      if (fd.get('dia')) {
        const novo = quandoDe(fd);
        const atual = v.instalacao_agendada_para;
        if (!atual || new Date(novo).getTime() !== new Date(atual).getTime()) {
          Object.assign(campos, { instalacao_agendada_para: novo, instalacao_turno: turnoDe(fd), nio_pendencia_cod: null, nio_pendencia_desc: null });
          if (v.status === '1_vendido') campos.status = '2_aguardando_instalacao';
        }
      }
      const docs = fd.get('docs');
      const docsAtual = v.docs_entregues_em ? NG.diaSP(v.docs_entregues_em) : '';
      if (docs !== docsAtual) campos.docs_entregues_em = docs ? `${docs}T12:00:00-03:00` : null;
      if (!Object.keys(campos).length) { edicao = null; render(); return true; }
      return gravar(campos, 'Instalação atualizada');
    },
  };

  // ---------- conferência de qualidade (venda de parceiro) ----------
  async function confSalvar(fd, para) {
    const motivo = fd.get('motivo_conf');
    if (!motivo) { NG.toast('Escolha o motivo da lista: reprovar ou devolver sem motivo não é permitido.', 'bad'); return false; }
    const obsNova = String(fd.get('obs_conf') || '').trim();
    const campos = { conferencia_status: para, conferencia_motivo: motivo };
    if (obsNova) campos.conferencia_obs = [d.v.conferencia_obs, obsNova].filter(Boolean).join('\n');
    if (para === 'reprovada') { campos.status = 'saida'; campos.motivo_saida = `Reprovada na conferência: ${NG.MOTIVOS_CONFERENCIA[motivo]}`; }
    return gravar(campos, para === 'reprovada' ? 'Venda reprovada e encerrada' : 'Venda devolvida ao parceiro');
  }
  async function confTentativa(atendeu) {
    const sel = raiz.querySelector('[data-conf-canal]');
    const { data, error } = await NG.sb.rpc('parceiro_conferencia_tentativa', {
      p_venda: d.v.id, p_canal: sel ? sel.value : 'ligacao', p_atendeu: atendeu, p_resumo: null });
    if (error) { d.avisoTent = NG.msgErro(error); render(); return; }   // horário/teto do contrato: nada foi gravado
    d.avisoTent = null;
    NG.toast(data && data.devolvida ? `${data.sem_resposta} tentativas sem resposta: devolvida ao parceiro` : atendeu ? 'Tentativa registrada: cliente atendeu' : `Tentativa registrada: sem resposta (${data ? data.sem_resposta : '?'} de ${data ? data.max : '?'})`, 'ok');
    await recarregar();
    ouvintes.forEach((f) => { try { f(d && d.v); } catch (e) { /* tela que ouve */ } });
  }
  async function confGerar() {
    const { data, error } = await NG.sb.rpc('parceiro_lancar_instalacao_admin', { p_venda: d.v.id });
    if (error) { NG.toast(NG.msgErro(error), 'bad'); return; }
    NG.toast(data && data.lancado ? `Lançamentos gerados: ${data.pontos_novos} de pontos · ${data.pagamentos_novos} de pagamento` : `Nada gerado: ${(data || {}).motivo || 'sem motivo'}`, data && data.lancado ? 'ok' : 'bad');
    await recarregar();
  }

  // Cartão da conferência: só venda de parceiro. Admin e backoffice agem; o resto só lê o estado.
  function cartaoConferencia(v) {
    if (v.origem !== 'parceiro_pap') return '';
    const perfil = (NG.usuario || {}).perfil;
    const pode = ['admin', 'backoffice'].includes(perfil);
    const st = v.conferencia_status;
    const prazo = v.conferencia_prazo_ate ? new Date(v.conferencia_prazo_ate) : null;
    const estourou = st === 'pendente' && prazo && prazo.getTime() < Date.now();
    const max = (d.parc || {}).max || 3;
    const quem = v.conferencia_por ? (d.usuarios.find((u) => u.id === v.conferencia_por) || {}).nome : null;
    const instaladaConfirmada = ['3_instalado', '4_ativo_provisorio', '5_comissao_firme'].includes(v.status)
      && v.nio_situacao === 'Concluído' && v.nio_venda_valida === true && !!v.instalado_em;
    const semLancar = pode && d.parc && instaladaConfirmada && !d.parc.temPagamentoComissao;
    const form = formAtivo && formAtivo.startsWith('conf_') && FORMS[formAtivo] ? FORMS[formAtivo](v) : '';
    const botoes = pode && st === 'pendente' && !form ? `<div class="conf-botoes">
        <select class="sel" data-conf-canal aria-label="Canal da tentativa"><option value="ligacao">Ligação</option><option value="whatsapp">WhatsApp</option></select>
        <button type="button" class="btn" data-f="conf-tent-ok">Tentativa — atendeu</button>
        <button type="button" class="btn" data-f="conf-tent-nao">Tentativa — sem resposta</button></div>
      <div class="conf-botoes">
        <button type="button" class="btn btn-acc" data-f="conf-aprovar">Aprovar</button>
        <button type="button" class="btn" data-f="conf-form-reprovar">Reprovar</button>
        <button type="button" class="btn" data-f="conf-form-devolver">Devolver ao parceiro</button></div>` : '';
    return `<section class="conf-card${estourou ? ' atrasada' : ''}" aria-label="Conferência de qualidade">
      <h3>Conferência de qualidade <span class="pill cf-${esc(st || 'pendente')}">${esc(NG.CONFERENCIA_STATUS[st] || st || '—')}</span></h3>
      ${linha('Parceiro', esc(v.parceiro_nome || '—'))}
      ${st === 'pendente' ? linha('Prazo', prazo ? `<span class="${estourou ? 'bad-txt' : ''}">${esc(NG.fmtDataHora(prazo))}${estourou ? ' · estourado' : ''}</span>` : '—') : ''}
      ${st === 'pendente' ? linha('Sem resposta', esc(`${d.semResposta} de ${max} desde a última abertura`)) : ''}
      ${linha('Teto do cliente', esc(`hoje ${d.lim.hoje} de 2 · mês ${d.lim.mes} de 15`))}
      ${v.conferencia_motivo ? linha('Motivo', esc(NG.MOTIVOS_CONFERENCIA[v.conferencia_motivo] || v.conferencia_motivo)) : ''}
      ${v.conferencia_obs ? linha('Observação interna', `${esc(v.conferencia_obs)} <small class="apagado">· não aparece para o parceiro</small>`) : ''}
      ${st === 'aprovada' && v.conferencia_em ? linha('Aprovada em', esc(`${NG.fmtDataHora(v.conferencia_em)}${quem ? ' · ' + quem : ''}`)) : ''}
      ${st !== 'aprovada' && v.status === '0_qualificado' ? '<div class="faixa amarelo">Enquanto a conferência não for aprovada, o banco não deixa a venda passar de Qualificado.</div>' : ''}
      ${d.avisoBanco ? `<div class="faixa amarelo">${esc(d.avisoBanco)}</div>` : ''}
      ${d.avisoTent ? `<div class="faixa amarelo">${esc(d.avisoTent)} (nada foi gravado)</div>` : ''}
      ${botoes}${form}
      ${semLancar ? `<div class="faixa amarelo">${d.parc.comissaoValor ? 'Instalação confirmada, mas a comissão do parceiro ainda não foi lançada.' : 'Instalada sem comissão configurada para este plano: configure em Configurações › Programa Parceiro.'}
          ${perfil === 'admin' ? '<button type="button" class="btn btn-sm" data-f="conf-gerar">Gerar lançamentos</button>' : '<span class="nota-campo">O admin gera os lançamentos.</span>'}</div>` : ''}
    </section>`;
  }

  // ---------- pendência com terceiro (0064) ----------
  // Aparece em venda aberta (Qualificado a Instalado) ou quando há histórico. Admin/backoffice abrem, adiam e encerram;
  // os outros perfis só leem. O atalho "Confirmado? Encerrar como …" abre o formulário de Saída com o motivo sugerido
  // (a pendência é encerrada pelo trigger do banco quando a venda vai para Saída).
  function cartaoPendencia(v) {
    const pode = ['admin', 'backoffice'].includes((NG.usuario || {}).perfil);
    const aberta = ['0_qualificado', '1_vendido', '2_aguardando_instalacao', '3_instalado'].includes(v.status);
    const pe = d.pend;
    const hist = d.pendHist || [];
    if (!pe && !hist.length && (!aberta || !pode)) return '';
    const form = formAtivo && formAtivo.startsWith('pend_') && FORMS[formAtivo] ? FORMS[formAtivo](v) : '';
    const guia = '<a class="pend-guia" href="guia.html#pendencias" target="_blank" rel="noopener">Como funciona ↗</a>';
    const nomeMot = (c) => (d.motivos.find((m) => m.codigo === c) || {}).nome || c;
    const histHtml = hist.length ? `<div class="pend-hist"><div class="f-sub">Histórico</div>${hist.slice(0, 6).map((p) => `<span><b>${esc(nomeMot(p.motivo))}</b> · ${esc(NG.fmtData(p.aberta_em))} → ${esc(NG.fmtData(p.encerrada_em))} · ${esc(NG.RESULTADO_PENDENCIA[p.resultado] || p.resultado)}${p.revisoes ? ` · adiada ${p.revisoes}×` : ''}${p.nota_encerramento ? ` · ${esc(p.nota_encerramento)}` : ''}${p.autor ? ` · ${esc(p.autor)}` : ''}</span>`).join('')}</div>` : '';
    if (!pe) {
      return `<section class="conf-card pend-card" aria-label="Pendência" data-pend-card>
        <div class="cc-linha"><h3>Pendência <span class="pill dim">nenhuma</span></h3>${guia}</div>
        ${pode && aberta && !form ? '<div class="conf-botoes"><button type="button" class="btn" data-f="pend-abrir">⏸ Abrir pendência (depende de terceiro)</button></div>' : ''}
        ${form}${histHtml}
      </section>`;
    }
    const pill = pe.vencida ? '<span class="pill pend-vencida">⏰ revisar hoje</span>' : '<span class="pill pend-espera">⏸ em espera</span>';
    const dias = pe.desde ? Math.max(0, Math.round((new Date(`${NG.diaSP()}T12:00:00-03:00`) - new Date(`${NG.diaSP(pe.desde)}T12:00:00-03:00`)) / 86400000)) : null;
    const atalho = pode && pe.saida_sugerida && !form
      ? `<button type="button" class="btn btn-ghost" data-f="pend-saida">Confirmado? Encerrar como ${esc(pe.saida_sugerida)}</button>` : '';
    const botoes = pode && !form ? `<div class="conf-botoes">
        <button type="button" class="btn ${pe.vencida ? 'btn-acc' : ''}" data-f="pend-encerrar">Encerrar</button>
        <button type="button" class="btn" data-f="pend-adiar">Adiar</button>${atalho}</div>` : '';
    return `<section class="conf-card pend-card ${pe.vencida ? 'vencida' : 'espera'}" aria-label="Pendência" data-pend-card>
      <div class="cc-linha"><h3>Pendência ${pill}${pe.revisoes >= 2 ? `<span class="pill pend-adiada" title="Adiada duas ou mais vezes: o Ricardo decide">⚠️ adiada ${pe.revisoes}×</span>` : ''}</h3>${guia}</div>
      ${linha('Motivo', esc(pe.nome))}
      ${linha('Quem destrava', esc(pe.quemTxt))}
      ${linha('Desde', esc(`${NG.fmtDataHora(pe.desde)}${dias != null ? ` · ${dias} dia${dias === 1 ? '' : 's'} parada` : ''}`))}
      ${linha('Revisar em', `<span class="${pe.vencida ? 'bad-txt' : ''}">${esc(pe.diaTxt)}</span>`)}
      ${pe.descricao ? linha('Descrição', esc(pe.descricao)) : ''}
      <span class="nota-campo">A cadência da Mari está pausada para este cliente até a pendência ser encerrada. Avise o cliente uma vez, à mão (texto pronto no guia).</span>
      ${pode ? '' : '<span class="nota-campo">Só admin ou backoffice adia ou encerra.</span>'}
      ${botoes}${form}${histHtml}
    </section>`;
  }

  // DFV (bloco Endereço em edição): o mesmo "Salvar consulta" e "Dispensar (admin)" da venda.html.
  async function salvarDfv() {
    const dados = NG.dfvLer(raiz.querySelector('[data-dfv-campos]'));
    return gravar(dados, `DFV registrado: ${NG.DFV_OPCOES[dados.dfv_viabilidade]}${dados.dfv_origem === 'auto' ? ' (base automática)' : ''}`);
  }
  async function dispensarDfv() {
    const caixa = raiz.querySelector('[data-dispensa]');
    if (caixa.hidden) { caixa.hidden = false; caixa.querySelector('input').focus(); return; }
    const motivo = String(caixa.querySelector('input').value || '').trim();
    if (!motivo) { NG.toast('Escreva o motivo da dispensa.', 'bad'); return; }
    await gravar({ dfv_dispensado: true, dfv_dispensa_motivo: motivo }, 'Consulta do DFV dispensada');
  }

  // ---------- viabilidade pelo portal + dados para o portal (prompt 27) ----------
  const FORMS_NO_CARTAO = ['viab', 'ref', 'pend_abrir', 'pend_adiar', 'pend_encerrar'];   // abrem dentro dos cartões, não na faixa do próximo passo
  const mostraCartoesPortal = (v) => ['0_qualificado', 'saida'].includes(v.status);
  const cepNumero = (v) => [NG.fmtCep(v.cep), v.numero || ''].filter(Boolean).join(' ').trim();

  // Pista do DFV numa frase (sem cor de alerta): nunca decide a venda.
  function pistaDfv(v) {
    const foto = v.dfv_particao ? NG.fmtDiaISO(v.dfv_particao).slice(0, 5) : '03/11';
    const fr = {
      viavel: 'Viável — a foto da Nio mostra porta livre neste endereço. O portal confirma.',
      viavel_predio: 'Viável prédio — o prédio é atendido; a unidade só o portal confirma.',
      sem_viabilidade: v.dfv_resultado === 'endereco_ocupado'
        ? 'Indica Nio no endereço — pode ser outra unidade ou cliente antigo; o portal confere a posse.'
        : 'Sem porta livre na foto — pode ter mudado; o portal decide.',
      nao_encontrado: 'Não achou o endereço — pode ser sem cobertura ou endereço fora da foto da Nio; o portal decide.',
    }[v.dfv_viabilidade];
    return { foto, txt: fr || (v.dfv_dispensado ? 'Dispensado pelo admin.' : 'Não consultado.') };
  }

  function cartaoViabilidade(v) {
    if (!mostraCartoesPortal(v)) return '';
    const r = v.nio_viab_resultado;
    const estado = r ? (NG.VIAB_NIO[r] || r) : 'Não consultado';
    const cls = r === 'viavel' ? (NG.portalViavel(v) ? 'cf-aprovada' : 'cf-pendente') : r ? 'cf-reprovada' : 'cf-pendente';
    const quem = v.nio_viab_por ? (d.usuarios.find((u) => u.id === v.nio_viab_por) || {}).nome : null;
    const quando = r && v.nio_viab_em ? `${NG.fmtDataHora(v.nio_viab_em)}${quem ? ` · ${quem}` : v.nio_viab_origem === 'manual' ? '' : ' · automático'}` : '';
    const vencida = r === 'viavel' && !NG.portalViavel(v);
    const pd = pistaDfv(v);
    const form = formAtivo === 'viab' ? FORMS.viab(v) : '';
    const fechada = v.status === 'saida';
    // 07/11: recolhido = uma linha com o status do portal; abre no clique ou quando o formulário do resultado está aberto.
    const aberto = abertos.has('c_viab') || formAtivo === 'viab';
    return `<section class="conf-card portal-card recolhe${aberto ? ' aberto' : ''}" aria-label="Viabilidade">
      <div class="cc-cab"><button type="button" class="cc-tog" data-f="cartao" data-c="c_viab" aria-expanded="${aberto}"><b>Viabilidade</b><span class="pill ${cls}">${esc(estado)}</span>${quando ? `<small>${esc(quando)}</small>` : ''}${vencida ? '<small class="warn-txt">consultar de novo</small>' : ''}</button>${NG.dicaTxt(NG.ajuda.viab_portal)}</div>
      <div class="cc-corpo">
      ${vencida ? '<div class="faixa amarelo">Viável há mais de 7 dias: consulte de novo antes de registrar a venda.</div>' : ''}
      ${r && r !== 'viavel' && !fechada ? '<span class="nota-campo">Sem viabilidade ou endereço não encontrado: tente variações de CEP, rua e número no portal antes de encerrar.</span>' : ''}
      ${!fechada && !form ? `<div class="conf-botoes">
        <a class="btn ${r === 'viavel' ? '' : 'btn-acc'}" href="${NG.PORTAL_PAP_NOVO_PEDIDO}" target="_blank" rel="noopener" data-f="consultar-portal" title="${esc(NG.ajuda.viab_consultar)}">Consultar no portal ↗</a>
        <button type="button" class="btn" data-f="viab-form" title="${esc(NG.ajuda.viab_registrar)}">Registrar resultado</button></div>` : ''}
      ${form}
      <div class="pista-dfv" title="${esc(NG.ajuda.dfv_pista)}"><span>Pista do DFV (foto da Nio de ${esc(pd.foto)})</span> ${esc(pd.txt)}</div>
      </div>
    </section>`;
  }

  // Campos na ordem das etapas do Novo Pedido. [rótulo, valor, obrigatório, só conferência]
  function camposPortal(v) {
    const adics = d.adics.map((a) => `${(a.config_adicionais || {}).nome || '?'} × ${a.qtd}`).join(', ');
    return [
      ['Etapa 2 · Viabilidade', [
        ['CEP', v.cep ? NG.fmtCep(v.cep) : '', true],
        ['Número', v.numero || '', true],
        ['Complemento', v.complemento || '', false],
        ['Referência', v.ponto_referencia || '', true],
        ['Rua (conferir)', v.logradouro || '', false, true],
        ['Bairro (conferir)', v.bairro || '', false, true],
        ['Cidade (conferir)', [v.cidade, v.uf].filter(Boolean).join('/'), false, true],
      ]],
      ['Etapa 3 · Cliente', [
        [NG.soDigitos(v.cliente_cpf_cnpj).length === 14 ? 'CNPJ' : 'CPF', v.cliente_cpf_cnpj ? fmtDoc(v.cliente_cpf_cnpj) : '', true],
        ['Nome (o portal traz da Receita — conferir)', v.cliente_nome || '', true, true],
      ]],
      ['Etapa 4 · Contato', [
        ['Telefone', v.cliente_whatsapp ? fmtTel(v.cliente_whatsapp) : '', true],
        ['E-mail', v.cliente_email || '', true],
      ]],
      ['Etapa 5 · Oferta', [
        ['Plano', v.plano_nome || '', true],
        ['Adicionais', adics || 'nenhum', false],
        ['Forma de pagamento', FORMAS[v.forma_pagamento] || '', true],
      ]],
      ['Etapa 7 · Agendamento', [
        ['Período preferido e observação', v.instalacao_preferencia || '', true],
      ]],
    ];
  }
  const FALTA = { CEP: 'o CEP', Número: 'o número', Referência: 'a referência', CPF: 'o CPF', CNPJ: 'o CNPJ', Telefone: 'o telefone', 'E-mail': 'o e-mail',
    Plano: 'o plano', 'Forma de pagamento': 'a forma de pagamento', 'Período preferido e observação': 'o período preferido' };
  const rotCurto = (rot) => rot.replace(/ \(.*\)$/, '');
  function textoPortal(v) {
    return camposPortal(v).flatMap(([, cs]) => cs.map(([rot, val]) => `${rotCurto(rot)}: ${val || '—'}`)).join('\n');
  }

  function cartaoPortal(v) {
    if (!mostraCartoesPortal(v)) return '';
    let i = 0;
    const secoes = camposPortal(v).map(([etapa, cs]) => `<div class="pp-etapa"><div class="f-sub">${esc(etapa)}</div>${cs.map(([rot, val, obrig, conf]) => {
      const idx = i++;
      const falta = !val && obrig;
      const valor = val ? `<span class="${conf ? 'apagado' : 'mono'}">${esc(val)}</span>` : falta ? `<span class="bad-txt">falta ${esc(FALTA[rotCurto(rot)] || rotCurto(rot).toLowerCase())}</span>` : '<span class="apagado">—</span>';
      const extra = rot === 'Referência' && v.status !== 'saida' && formAtivo !== 'ref' ? ` <button type="button" class="btn btn-sm" data-f="ref-form">${val ? 'Editar' : 'Registrar'}</button>` : '';
      return `<div class="pp-linha${falta ? ' falta' : ''}"><span class="pp-rot">${esc(rot)}</span><span class="pp-val">${valor}${extra}</span>
        ${val ? `<button type="button" class="btn btn-sm pp-copiar" data-f="copiar-campo" data-i="${idx}" aria-label="Copiar ${esc(rotCurto(rot))}" title="Copiar ${esc(rotCurto(rot))}">⧉</button>` : '<span></span>'}</div>`;
    }).join('')}</div>`).join('');
    const faltam = camposPortal(v).flatMap(([, cs]) => cs).filter(([, val, obrig]) => obrig && !val).length;
    // 07/11: recolhido por padrão (status + "Copiar tudo" na linha); abre no clique ou ao editar a referência.
    const aberto = abertos.has('c_portal') || formAtivo === 'ref';
    return `<section class="conf-card portal-card recolhe${aberto ? ' aberto' : ''}" aria-label="Dados para o portal PAP">
      <div class="cc-cab"><button type="button" class="cc-tog" data-f="cartao" data-c="c_portal" aria-expanded="${aberto}"><b>Dados para o portal PAP</b>${faltam ? `<span class="pill cf-reprovada">${faltam} ${faltam === 1 ? 'falta' : 'faltam'}</span>` : '<span class="pill cf-aprovada">completo</span>'}</button>${NG.dicaTxt(NG.ajuda.portal_dados)}
        <button type="button" class="btn btn-sm" data-f="copiar-tudo" title="Um campo por linha, &quot;Rótulo: valor&quot;. O que falta vai como &quot;—&quot;.">Copiar tudo</button></div>
      <div class="cc-corpo">
      ${secoes}
      ${formAtivo === 'ref' ? FORMS.ref(v) : ''}
      <span class="nota-campo">"Copiar tudo": um campo por linha, "Rótulo: valor". O que falta vai como "—".</span>
      </div>
    </section>`;
  }

  // Só o fato vai para eventos_venda (quem e quando) — nunca o conteúdo copiado. No máximo 1 registro a cada 10 min por venda.
  let ultimaCopia = { id: null, em: 0 };
  async function registrarCopia(oQue) {
    if (ultimaCopia.id === d.v.id && Date.now() - ultimaCopia.em < 600000) return;
    ultimaCopia = { id: d.v.id, em: Date.now() };
    await NG.sb.from('eventos_venda').insert({ venda_id: d.v.id, tipo: 'portal_dados_copiados', detalhe: { o_que: oQue } });
  }
  async function copiar(texto, ok) {
    try { await navigator.clipboard.writeText(texto); NG.toast(ok, 'ok'); return true; } catch (e) { NG.toast('Não deu para copiar — selecione e copie à mão.', 'bad'); return false; }
  }

  // ---------- desenho ----------
  const DESTINOS = [['0_qualificado', 'Qualificado'], ['1_vendido', 'Vendido'], ['2_aguardando_instalacao', 'Aguardando instalação'],
    ['3_instalado', 'Instalado'], ['saida', 'Saída']];   // Ativo não: vem da importação do OSAB

  function cabecalho(v) {
    const atual = NG.etapaDe(v.status).id;
    const ops = DESTINOS.filter(([st]) => NG.etapaDe(st).id !== atual);
    const local = [v.bairro, v.cidade].filter(Boolean).join(' · ');
    const ref = v.origem_ref && !/^mari:/i.test(v.origem_ref) ? ` · ${v.origem_ref}` : '';
    const menu = [
      d.chatwoot ? `<a role="menuitem" href="${esc(d.chatwoot)}" target="_blank" rel="noopener">Conversa no Chatwoot ↗</a>` : '',
      v.cliente_whatsapp ? '<button type="button" role="menuitem" data-f="copiar-tel">Copiar telefone</button>' : '',
      d.conversaId ? `<a role="menuitem" href="mari.html?conversa=${esc(d.conversaId)}">Ver conversa da Mari</a>` : '',
      `<a role="menuitem" href="vendas.html?vista=quadro&amp;etapa=${esc(atual)}">Ver no Quadro</a>`,
      modo === 'gaveta' ? `<a role="menuitem" href="venda.html?id=${esc(v.id)}" target="_blank" rel="noopener">Abrir em página cheia ↗</a>` : '',
    ].filter(Boolean).join('');
    return `<header class="f-cab">
      ${modo === 'pagina' ? '<a class="voltar" href="vendas.html">← Vendas</a>' : ''}
      <div class="f-linha1"><h2>${esc(v.cliente_nome)}</h2>${modo === 'gaveta' ? '<button type="button" class="g-fechar" data-f="fechar" aria-label="Fechar a ficha">×</button>' : ''}</div>
      ${local ? `<div class="f-local">${esc(local)}</div>` : ''}
      <div class="f-linha3">
        <div class="f-meta">${NG.pilulaEtapa(v.status)}<span>${esc(NG.origemTxt(v) + ref)}</span><span>· ${esc(v.vendedor_nome || 'sem vendedor')}</span></div>
        <div class="f-ctl">
          <select class="sel" data-mover aria-label="Mover para outra etapa"><option value="">Mover para…</option>${ops.map(([st, nome]) => `<option value="${st}">${esc(nome)}</option>`).join('')}</select>
          <div class="f-menu"><button type="button" class="btn f-mais" data-f="menu" aria-haspopup="menu" aria-expanded="false" aria-label="Mais ações">⋯</button>
            <div class="f-menu-lista" role="menu" hidden>${menu}</div></div>
        </div>
      </div>
      ${linhaDoTempo(v)}
    </header>`;
  }

  // ---------- conversa da Mari (orelha à esquerda da ficha, 07/11) ----------
  // Só para quem lê mari_conversas (admin/backoffice): sem conversaId, sem orelha. Mesmos balões da tela Mari, só texto.
  const limpaTurno = (t) => String(t || '').replace(/\[HANDOFF\][\s\S]*?(\[\/HANDOFF\]|$)/gi, '').replace(/\[[A-Z_]{3,}(?::[^\]]*)?\]/g, '').trim();
  function painelConversa(v) {
    if (!d.conversaId) return '';
    const pronta = conv && conv.id === d.conversaId;
    let corpo = '<div class="carregando">Carregando a conversa…</div>';
    let n = 0;
    if (pronta && conv.erro) corpo = `<div class="vazio">${esc(conv.erro)}</div>`;
    else if (pronta) {
      const quemDe = { lead: v.cliente_nome, mari: 'Mari', humano: 'Humano', sistema: 'Sistema' };
      const itens = conv.turnos.filter((t) => quemDe[t.papel] && limpaTurno(t.texto));
      n = itens.length;
      corpo = itens.map((t) => `<div class="balao ${t.papel}"><div class="b-quem">${esc(quemDe[t.papel])} · ${esc(NG.fmtDataHora(t.created_at))}</div><div class="b-txt">${esc(limpaTurno(t.texto))}</div></div>`).join('')
        || '<div class="vazio">Sem mensagens</div>';
    }
    return `<button type="button" class="f-orelha" data-f="conversa" aria-expanded="${convAberta}" aria-controls="f-conv" title="${convAberta ? 'Fechar a conversa' : 'Ler a conversa da Mari'}"><span>Conversa</span></button>
      <section class="f-conv" id="f-conv" aria-label="Conversa da Mari"${convAberta ? '' : ' hidden'}>
        <header class="f-conv-cab"><div><b>Conversa da Mari</b><small>${esc(v.cliente_nome)}${pronta && !conv.erro ? ` · ${n} ${n === 1 ? 'mensagem' : 'mensagens'}` : ''}</small></div>
          <div class="f-conv-acoes">${d.chatwoot ? `<a class="btn btn-sm" href="${esc(d.chatwoot)}" target="_blank" rel="noopener">Chatwoot ↗</a>` : ''}<a class="btn btn-sm" href="mari.html?conversa=${esc(d.conversaId)}">Na tela Mari</a>
          <button type="button" class="g-fechar" data-f="conversa" aria-label="Fechar a conversa">×</button></div></header>
        <div class="conversa f-conv-corpo">${corpo}</div>
      </section>`;
  }
  async function abrirConversa() {
    convAberta = true;
    convFim = true;
    render();
    if (conv && conv.id === d.conversaId) return;
    const id = d.conversaId;
    const { data, error } = await NG.sb.from('mari_turnos').select('id, papel, texto, created_at').eq('conversa_id', id).order('created_at').order('id').limit(400);
    if (!d || d.conversaId !== id) return;   // trocou de venda no meio
    conv = { id, turnos: data || [], erro: error ? NG.msgErro(error) : null };
    convFim = true;
    render();
  }
  // Esc fecha primeiro a conversa, depois a ficha (captura antes do Esc da gaveta).
  window.addEventListener('keydown', (ev) => {
    if (ev.key !== 'Escape' || !convAberta || !d || document.querySelector('dialog[open]') || document.querySelector('.dica-pop')) return;
    ev.stopPropagation();
    convAberta = false;
    render();
  }, true);

  function faixaProximo(v, pr) {
    let nota = '';
    if (pr.resolver === 'invalida') nota = 'Venda inválida não conta para meta nem comissão e pode gerar multa ou estorno (tolerância zero). Avise o Ricardo.';
    else if (v.status === '1_vendido') nota = 'Contrato: instalação agendada em até 4 h depois da venda.';
    else if (pr.resolver === 'dfv' || pr.resolver === 'viab') nota = NG.TEXTOS_DFV.trava;
    else if (pr.resolver === 'pendencia') nota = pr.vencida ? 'Chegou a data de revisão: confira com o terceiro e adie ou encerre a pendência (cartão abaixo).' : 'A venda está esperando um terceiro. Nada a fazer até a data de revisão; a cadência da Mari está pausada.';
    const botoes = [];
    // Viabilidade (prompt 27): 1º consultar no portal (abre e copia "CEP número"), depois registrar o resultado.
    if (pr.resolver === 'viab') {
      botoes.push(`<a class="btn btn-acc" href="${NG.PORTAL_PAP_NOVO_PEDIDO}" target="_blank" rel="noopener" data-f="consultar-portal" title="${esc(NG.ajuda.viab_consultar)}">Consultar no portal ↗</a>`);
    }
    if (pr.resolver && BOTAO[pr.resolver]) {
      const forte = pr.nivel === 'bad' || pr.nivel === 'warn' || ['pedido', 'portal', 'agendar', 'docs'].includes(pr.resolver);
      const rot = pr.resolver === 'sem_cobertura' && v.dfv_resultado === 'endereco_ocupado' ? 'Encerrar: já é cliente Nio' : BOTAO[pr.resolver];
      botoes.push(`<button type="button" class="btn ${forte ? 'btn-acc' : ''}" data-resolver="${pr.resolver}">${esc(rot)}</button>`);
    }
    // Em Qualificado o "Registrar venda" (pedido + biometria validada) sempre fica à mão.
    if (v.status === '0_qualificado' && pr.resolver !== 'pedido' && pr.resolver !== 'sem_cobertura') {
      botoes.push('<button type="button" class="btn btn-ghost" data-resolver="pedido">Registrar venda</button>');
    }
    const form = formAtivo && FORMS[formAtivo] && !formAtivo.startsWith('conf_') && !FORMS_NO_CARTAO.includes(formAtivo) ? FORMS[formAtivo](v) : '';
    return `<section class="f-prox ${pr.nivel || 'dim'}" aria-label="Próximo passo">
        <div class="f-prox-txt"><span class="f-rot">Próximo passo</span><b>${esc(pr.txt || '—')}</b>${nota ? `<span class="f-nota">${esc(nota)}</span>` : ''}</div>
        ${botoes.length && !form ? `<div class="f-prox-bts">${botoes.join('')}</div>` : ''}
      </section>${form}`;
  }

  function linhaDoTempo(v) {
    const ETAPAS_T = [['qualificado', 'Qualificado', v.criado_em], ['vendido', 'Vendido', v.vendido_em], ['aguardando', 'Aguardando', v.agendamento_registrado_em],
      ['instalado', 'Instalado', v.instalado_em], ['ativo', 'Ativo', v.ativado_em]];
    const atual = NG.etapaDe(v.status).id;
    const idx = ETAPAS_T.findIndex((e) => e[0] === atual);
    const saidaEv = v.status === 'saida' ? [...d.eventos].reverse().find((e) => e.tipo === 'status' && (e.detalhe || {}).para === 'saida') : null;
    const itens = ETAPAS_T.map(([id, nome, quando], i) => {
      const feito = !!quando || (idx >= 0 && i < idx);
      const cls = i === idx ? 'atual' : feito ? 'feito' : '';
      return `<li class="${cls}"><i></i><span>${esc(nome)}</span><small>${quando ? esc(NG.fmtData(quando)) : feito ? '✓' : '—'}</small></li>`;
    }).join('');
    return `<ol class="f-tempo" aria-label="Etapas da venda">${itens}</ol>
      ${v.status === 'saida' ? `<div class="f-saida-linha">Saída${saidaEv ? ` em ${esc(NG.fmtData(saidaEv.criado_em))}` : ''} · ${esc(v.motivo_saida || 'sem motivo')}${v.interesse_futuro_em ? ` · volta ${esc(NG.fmtDiaISO(v.interesse_futuro_em))}` : ''}</div>` : ''}`;
  }

  function trava(rotulo, valor, okTxt) {
    const cls = valor === true ? 'ok' : valor === false ? 'bad' : 'nd';
    const txt = valor === true ? (okTxt || '✓') : valor === false ? '✗' : 'não verificada';
    return `<div class="trava"><span>${esc(rotulo)}</span><span class="s ${cls}">${esc(txt)}</span></div>`;
  }

  // Cada bloco: título, resumo (fechado), corpo (aberto) e, quando editável, o formulário de edição.
  function blocos(v) {
    const m = NG.fmtMoeda;
    const valorAd = d.adics.reduce((s, a) => s + Number((a.config_adicionais || {}).preco || 0) * a.qtd, 0);
    const listaAd = d.adics.map((a) => `${a.qtd > 1 ? a.qtd + '× ' : ''}${(a.config_adicionais || {}).nome || '?'}`).join(', ');
    const cartao = v.forma_pagamento === 'cartao';
    const vendida = ['1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme'].includes(v.status);
    const formaTxt = FORMAS[v.forma_pagamento] || '—';
    const planoTxt = d.nomeCurto || v.plano_nome || 'sem plano';
    const dfvRot = (() => {
      if (NG.DFV_OK.includes(v.dfv_viabilidade)) return NG.dfvValido(v) ? `DFV viável${v.dfv_consultado_em ? ' · ' + NG.fmtData(v.dfv_consultado_em) : ''}` : 'DFV vencido';
      if (v.dfv_dispensado) return 'DFV dispensado';
      return NG.DFV_OPCOES[v.dfv_viabilidade] ? `DFV: ${NG.DFV_OPCOES[v.dfv_viabilidade].toLowerCase()}` : 'DFV não consultado';
    })();
    const recompra = d.eventos.filter((e) => e.tipo === 'alerta_recompra').pop();
    const ehAdmin = NG.usuario && NG.usuario.perfil === 'admin';
    const vendedores = d.usuarios.filter((u) => u.perfil !== 'backoffice');

    // Prompt 28: bolinhas dos avisos da Mari (acesa = enviada · piscando = próxima · apagada = futura; texto no mouse).
    const avisosMari = (codigos) => {
      if (!d.cad) return '';
      const nome = NG.nomeCadencia(v.cliente_nome);
      const ag = v.instalacao_agendada_para;
      const turnoTxt = (v.instalacao_turno || (ag && NG.janela(ag) === '13–17h' ? 'tarde' : 'manha')) === 'tarde';
      const diaLongo = ag ? `${new Intl.DateTimeFormat('pt-BR', { timeZone: NG.TZ, weekday: 'long' }).format(new Date(ag))}, ${NG.fmtData(ag)}` : '';
      const end = [v.logradouro, v.numero, v.complemento, v.bairro].map((x) => String(x || '').trim()).filter(Boolean).join(', ');
      const t = d.cad.tpl;
      const futuros = {
        BIO1: NG.renderTpl(t.nio_lembrete_biometria_v2, [nome]),
        BIO3: 'Não é mensagem: no D+3 do pedido sem biometria, o nosso time liga para o cliente (nunca automático).',
        INSTALACAO: NG.renderTpl(t.nio_instalacao_agendada, [nome, diaLongo, turnoTxt ? 'tarde, 13h às 17h' : 'manhã, 8h às 12h', end]),
        VESPERA: NG.renderTpl(t.nio_lembrete_instalacao, [nome, ag ? NG.fmtData(ag) : '', turnoTxt ? 'tarde' : 'manhã']),
      };
      const ROT = { BIO1: 'Lembrete da biometria (D+1 do pedido)', BIO3: 'D+3 sem biometria · o time liga', INSTALACAO: 'Aviso da instalação agendada (C2)', VESPERA: 'Véspera da instalação (C3)' };
      const k = d.cad.k;
      const proximo = k && codigos.includes(k.proximo_passo) ? { cod: k.proximo_passo, em: k.proximo_em, texto: k.texto, bloqueio: k.bloqueio } : null;
      const html = NG.cadBolinhas(codigos.map((cod) => ({ cod, rot: ROT[cod] })), { enviados: d.cad.enviados, proximo, futuros });
      return `<div class="d-l"><span>Avisos da Mari ${NG.dicaTxt(NG.ajuda.cad_avisos_venda)}</span><b>${html}</b></div>`;
    };

    // M-10: apurado no 11º mês após a ativação (texto do contrato em NG.TEXTOS_COMISSAO.m10).
    let m10 = '—';
    if (vendida) {
      if (v.nio_venda_valida === false) m10 = esc(NG.textoComissao('m10Nao', 'a Nio marcou a venda como inválida'));
      else if (!Number(v.bonus_m10_potencial)) m10 = esc(NG.textoComissao('m10Nao', 'o plano não tem bônus M-10 na política vigente'));
      else {
        let quando = 'no 11º mês após a ativação';
        if (v.ativado_em || v.instalado_em) {
          const x = new Date(v.ativado_em || v.instalado_em);
          x.setMonth(x.getMonth() + 11);
          quando = `em ${new Intl.DateTimeFormat('pt-BR', { timeZone: NG.TZ, month: '2-digit', year: 'numeric' }).format(x)} (11º mês)`;
        }
        m10 = `${esc(m(v.bonus_m10_potencial))} · apurado ${esc(quando)} ${NG.dica('m10')}`;
      }
    }

    return [
      {
        id: 'cliente', titulo: 'Cliente e contato',
        resumo: [v.cliente_cpf_cnpj ? fmtDoc(v.cliente_cpf_cnpj) : 'sem CPF/CNPJ', fmtTel(v.cliente_whatsapp)].join(' · '),
        corpo: () => `${linha('Nome', esc(v.cliente_nome))}
          ${linha('CPF / CNPJ', v.cliente_cpf_cnpj ? `<span class="mono">${esc(fmtDoc(v.cliente_cpf_cnpj))}</span>` : '—')}
          ${linha('WhatsApp', esc(fmtTel(v.cliente_whatsapp)))}
          ${linha('E-mail', esc(v.cliente_email || '—'))}
          ${linha('Segmento', esc(SEGMENTOS[v.segmento] || '—'))}
          ${linha('Contato confirmado', v.trava_contato_confirmado === true ? '<span class="ok-txt">sim ✓</span>' : v.trava_contato_confirmado === false ? '<span class="bad-txt">não</span>' : 'não verificado')}`,
        editar: () => `<form class="f-formulario" data-form="ed_cliente" novalidate>
          <label class="campo">Nome<input type="text" name="nome" value="${esc(v.cliente_nome || '')}" required></label>
          <div class="grade2"><label class="campo">CPF / CNPJ<input type="text" name="doc" inputmode="numeric" value="${esc(fmtDoc(v.cliente_cpf_cnpj) === '—' ? '' : fmtDoc(v.cliente_cpf_cnpj))}"></label>
          <label class="campo">WhatsApp<input type="tel" name="whatsapp" value="${esc(v.cliente_whatsapp ? fmtTel(v.cliente_whatsapp) : '')}"></label></div>
          <label class="campo">E-mail<input type="email" name="email" value="${esc(v.cliente_email || '')}"></label>
          <label class="check"><input type="checkbox" name="contato_ok" ${v.trava_contato_confirmado ? 'checked' : ''}> Endereço e telefone confirmados com o cliente</label>
          <span class="nota-campo">O segmento (PF/MEI/NMEI) muda o plano e a comissão: não se edita aqui.</span>
          ${acoesForm('Salvar')}</form>`,
      },
      {
        id: 'endereco', titulo: 'Endereço e viabilidade',
        resumo: [[v.logradouro, v.numero].filter(Boolean).join(', ') || 'sem endereço',
          `portal: ${v.nio_viab_resultado ? (NG.VIAB_NIO[v.nio_viab_resultado] || v.nio_viab_resultado).toLowerCase() : 'não consultado'}`, `pista ${dfvRot}`].join(' · '),
        corpo: () => `${linha('Endereço', esc([v.logradouro, v.numero, v.complemento].filter(Boolean).join(', ') || '—'))}
          ${linha('Bairro · cidade', esc([v.bairro, [v.cidade, v.uf].filter(Boolean).join('/')].filter(Boolean).join(' · ') || '—'))}
          ${linha('CEP', `<span class="mono">${esc(v.cep || '—')}</span>`)}
          ${linha('Referência', v.ponto_referencia ? esc(v.ponto_referencia) : '<span class="bad-txt">falta (o portal exige)</span>')}
          ${linha('Área de atuação', v.trava_area === true ? '<span class="ok-txt">dentro ✓</span>' : v.trava_area === false ? '<span class="bad-txt">fora</span>' : 'não verificada')}
          ${linha('Viabilidade Nio (portal)', v.nio_viab_resultado ? `<span class="${v.nio_viab_resultado === 'viavel' ? 'ok-txt' : 'warn-txt'}">${esc(NG.VIAB_NIO[v.nio_viab_resultado] || v.nio_viab_resultado)}</span>${esc([v.nio_viab_velocidade ? ` · até ${v.nio_viab_velocidade}` : '', v.nio_viab_origem ? ` · ${v.nio_viab_origem === 'manual' ? 'registrada à mão' : v.nio_viab_origem}` : '', v.nio_viab_em ? ` · ${NG.fmtDataHora(v.nio_viab_em)}` : ''].join(''))}` : 'não registrada')}
          ${v.nio_viab_endereco_portal ? linha('Como a Nio cadastrou', esc(v.nio_viab_endereco_portal)) : ''}
          ${v.nio_viab_interesse_id ? linha('Interesse no portal', `<span class="mono">${esc(v.nio_viab_interesse_id)}</span>`) : ''}
          ${v.nio_viab_resultado && v.nio_viab_resultado !== 'viavel' ? '<span class="nota-campo">Portal ≠ viável não nega a venda: confira variações de CEP, rua e número no portal antes de encerrar.</span>' : ''}
          ${linha('Pista do DFV', `<span title="${esc(NG.ajuda.dfv_pista)}">${esc(pistaDfv(v).txt)}</span>`)}
          <span class="nota-campo">${v.dfv_consultado_em ? `Última consulta ${esc(NG.fmtDataHora(v.dfv_consultado_em))}${v.dfv_dias != null ? ` · há ${esc(v.dfv_dias)} d` : ''}` : 'Ainda não consultado'} · ${esc(NG.TEXTOS_DFV.trava)}</span>
          ${v.dfv_dispensado ? `<span class="nota-campo">Dispensado pelo admin: ${esc(v.dfv_dispensa_motivo || '')}</span>` : ''}`,
        rotuloEditar: 'Consultar a pista do DFV',
        // Prompt 27: a viabilidade oficial se registra no cartão "Viabilidade" (topo da ficha); aqui fica só a pista do DFV.
        editar: () => `<div class="dfv-bloco" data-dfv>
          <div class="f-sub">Base DFV (pista — não decide a venda)</div>
          <div data-dfv-campos>${NG.dfvCampos(v)}</div>
          <div class="f-form-acoes">
            <button type="button" class="btn btn-ghost" data-f="cancelar">Cancelar</button>
            ${ehAdmin && !v.dfv_dispensado ? '<button type="button" class="btn btn-ghost" data-f="dfv-dispensar">Dispensar (admin)</button>' : ''}
            <button type="button" class="btn btn-acc" data-f="dfv-salvar">Salvar consulta do DFV</button>
          </div>
          <label class="campo" data-dispensa hidden>Motivo da dispensa (fica no histórico)<input type="text" placeholder="DFV fora do ar; confirmado no portal PAP"></label>
          <span class="nota-campo">O endereço não se edita aqui: as travas de área e de duplicidade rodam na entrada da venda.</span>
        </div>`,
      },
      {
        id: 'plano', titulo: 'Plano, valor e pagamento',
        resumo: [planoTxt, v.valor_mensal != null ? m(Number(v.valor_mensal) + valorAd) : null, formaTxt].filter(Boolean).join(' · '),
        corpo: () => `${linha('Plano', esc(v.plano_nome || '—'))}
          ${v.plano_velocidade ? linha('Velocidade', esc(v.plano_velocidade)) : ''}
          ${linha('Valor mensal', v.valor_mensal != null ? `<span class="mono">${esc(m(Number(v.valor_mensal) + valorAd))}</span>${valorAd ? ` <small class="apagado">plano ${esc(m(v.valor_mensal))} + ${esc(m(valorAd))}</small>` : ''}` : '—')}
          ${linha('Adicionais', esc(listaAd || '—'))}
          ${linha('Forma', esc(formaTxt))}
          ${linha('1º vencimento', esc(v.primeiro_vencimento ? `${NG.fmtDiaISO(v.primeiro_vencimento)} · ${cartao ? 'cobra todo dia' : 'depois todo dia'} ${v.vencimento_dia}` : cartao ? 'no dia da instalação' : '25 dias após a instalação'))}
          ${v.plano_taxa_a_vista ? linha('Fidelidade', 'sem fidelidade · taxa de habilitação à vista na 1ª fatura') : ''}
          <span class="nota-campo">Plano e forma de pagamento saem da tabela vigente na entrada da venda; para trocar, fale com o backoffice.</span>`,
      },
      {
        id: 'pedido', titulo: 'Pedido e biometria',
        resumo: [v.nio_pedido ? `Pedido #${v.nio_pedido}` : 'sem pedido no portal',
          v.biometria_status === 'pendente' && v.biometria_link_enviado_em
            ? `pedido aberto · link enviado pela Nio ${NG.fmtDataHora(v.biometria_link_enviado_em)}`
            : `biometria ${NG.BIOMETRIA[v.biometria_status] || NG.BIOMETRIA.nao_enviada}`,
          v.credito_resultado ? `crédito ${NG.CREDITO[v.credito_resultado]}` : null].filter(Boolean).join(' · '),
        corpo: () => `${linha('Nº do pedido (portal)', `<span class="mono">${esc(v.nio_pedido || '—')}</span>`)}
          ${linha('Contrato Nio', `<span class="mono">${esc(v.nio_contrato || '—')}</span>`)}
          ${linha('Interesse no portal', `<span class="mono">${esc(v.nio_viab_interesse_id || '—')}</span>`)}
          ${linha('Análise de crédito', esc(v.credito_resultado ? `${NG.CREDITO[v.credito_resultado]}${v.credito_em ? ' · ' + NG.fmtDataHora(v.credito_em) : ''}` : '—'))}
          ${linha('Biometria (link da Nio)', esc(`${NG.BIOMETRIA[v.biometria_status] || NG.BIOMETRIA.nao_enviada}${v.biometria_link_enviado_em ? ' · link enviado pela Nio ' + NG.fmtDataHora(v.biometria_link_enviado_em) : ''}${v.biometria_validada_em ? ' · validada ' + NG.fmtDataHora(v.biometria_validada_em) : ''}`))}
          ${avisosMari(['BIO1', 'BIO3'])}
          ${linha('Vendida em', esc(v.vendido_em ? NG.fmtDataHora(v.vendido_em) : '—'))}
          ${linha('Vendedor', esc(v.vendedor_nome || '—'))}
          ${v.status === '0_qualificado' ? botoesPortal : ''}
          <div class="f-sub">Conferências do contrato</div>
          ${trava('Sem produto ativo / não era cliente Nio', v.trava_sem_produto_ativo, 'não ✓')}
          ${trava('Sem cancelamento nos últimos 30 d', v.trava_sem_cancelamento_30d, 'não ✓')}
          ${trava('Dentro da área de atuação', v.trava_area, v.cidade ? `${v.cidade} ✓` : '✓')}
          ${trava('Cobertura Nio no endereço', v.trava_cobertura)}
          ${trava('CPF/CNPJ válido', v.trava_cpf_valido)}
          ${trava('Endereço e telefone confirmados', v.trava_contato_confirmado)}`,
        editar: () => `<form class="f-formulario" data-form="ed_pedido" novalidate>
          <div class="grade2"><label class="campo">Nº do pedido (portal PAP)<input type="text" name="pedido" value="${esc(v.nio_pedido || '')}" autocomplete="off"></label>
          <label class="campo">Contrato Nio<input type="text" name="contrato" value="${esc(v.nio_contrato || '')}"></label>
          <label class="campo">Interesse no portal<input type="text" name="interesse" value="${esc(v.nio_viab_interesse_id || '')}" autocomplete="off"></label>
          <label class="campo">Análise de crédito<select name="credito">${NG.opcoes(NG.CREDITO, v.credito_resultado)}</select></label>
          <label class="campo">Biometria (link)<select name="biometria">${optBiometria(v.biometria_status)}</select></label>
          <label class="campo">Vendedor<select name="vendedor"><option value="">—</option>${vendedores.map((u) => `<option value="${u.id}" ${u.id === v.vendedor_id ? 'selected' : ''}>${esc(u.nome)}</option>`).join('')}</select></label></div>
          <label class="campo">Link da biometria<input type="url" name="link" value="${esc(v.biometria_link || '')}" placeholder="https://…" autocomplete="off"></label>
          <span class="nota-campo">A etapa muda pelo "Mover para…" ou pelo próximo passo. Qualificado → Vendido exige pedido do portal + biometria validada (o banco confere).</span>
          ${acoesForm('Salvar')}</form>`,
      },
      {
        id: 'instalacao', titulo: 'Instalação',
        resumo: v.instalado_em ? `instalada ${NG.fmtData(v.instalado_em)}${v.docs_entregues_em ? ' · docs ✓' : v.docs_prazo_em ? ` · docs até ${NG.fmtData(v.docs_prazo_em)}` : ''}`
          : v.instalacao_agendada_para ? `${diaSemanaData(v.instalacao_agendada_para)} · ${NG.janela(v.instalacao_agendada_para)}` : vendida ? 'sem data' : 'depois da venda',
        corpo: () => {
          const h = v.vendido_em && v.agendamento_registrado_em ? (new Date(v.agendamento_registrado_em) - new Date(v.vendido_em)) / 3600000 : null;
          return `${linha('Agendada para', esc(v.instalacao_agendada_para ? `${diaSemanaData(v.instalacao_agendada_para)} · ${NG.janela(v.instalacao_agendada_para)}` : '—'))}
            ${v.biometria_validada_em ? linha('Biometria validada', esc(NG.fmtDataHora(v.biometria_validada_em))) : ''}
            ${linha('Agendamento', h != null ? `${esc(NG.fmtHoras(h))} depois da venda · ${h <= 4 ? '<span class="ok-txt">dentro das 4 h</span>' : '<span class="warn-txt">fora das 4 h</span>'}` : v.status === '1_vendido' && v.horas_sem_agendamento != null ? `<span class="${Number(v.horas_sem_agendamento) > 4 ? 'bad-txt' : 'warn-txt'}">sem agendamento há ${esc(NG.fmtHoras(v.horas_sem_agendamento))}</span>` : '—')}
            ${avisosMari(['INSTALACAO', 'VESPERA'])}
            ${linha('Preferência do cliente', esc(v.instalacao_preferencia || '—'))}
            ${v.instalacao_turno ? linha('Turno agendado no portal', esc(TURNO[v.instalacao_turno] || v.instalacao_turno)) : ''}
            ${linha('Instalada em', esc(v.instalado_em ? NG.fmtDataHora(v.instalado_em) : '—'))}
            ${linha('Situação OSAB', esc(v.nio_situacao || '—'))}
            ${v.nio_pendencia_cod || v.nio_pendencia_desc ? linha('Pendência Nio', `<span class="warn-txt">${esc([v.nio_pendencia_cod, v.nio_pendencia_desc].filter(Boolean).join(' · '))}</span>`) : ''}
            ${linha('Documentos à Nio', esc(v.docs_entregues_em ? `entregues ${NG.fmtDataAno(v.docs_entregues_em)}` : v.docs_prazo_em ? `prazo ${NG.fmtData(v.docs_prazo_em)} (15 dias)` : '—'))}`;
        },
        editar: vendida && v.status !== 'saida' ? () => `<form class="f-formulario" data-form="ed_instalacao" novalidate>
          <div class="grade2">${campoData('Data da instalação', 'dia', v.instalacao_agendada_para ? NG.diaSP(v.instalacao_agendada_para) : '')}
          ${campoPeriodo('periodo', v.instalacao_agendada_para ? periodoDe(v.instalacao_agendada_para) : '08:00')}
          ${campoData('Docs entregues à Nio em', 'docs', v.docs_entregues_em ? NG.diaSP(v.docs_entregues_em) : '')}</div>
          <span class="nota-campo">Mudar a data conta como reagendamento e limpa a pendência da Nio. Instalada/ativa chega pelo OSAB.</span>
          ${acoesForm('Salvar')}</form>` : null,
      },
      {
        id: 'comissao', titulo: 'Comissão',
        resumo: v.comissao_paga != null ? `paga ${m(v.comissao_paga)}` : v.status === 'saida' ? '—' : v.comissao_prevista != null ? `prevista ${m(v.comissao_prevista)}` : '—',
        corpo: () => `${linha('Prevista', `<span class="mono">${esc(m(v.comissao_prevista))}</span>`)}
          <span class="nota-campo">${esc(`${m(v.comissao_nominal)} nominal · ${m(v.comissao_adicionais)} adicionais · ${m(v.bonus_transicao_previsto)} transição · ${m(v.bonus_nmei_previsto)} NMEI`)}</span>
          ${linha('Paga', v.comissao_paga != null ? `<span class="mono ok-txt">${esc(m(v.comissao_paga))}</span>${v.ciclo_pago ? ` · ciclo ${esc(v.ciclo_pago)}` : ''}` : 'aguardando o extrato da Nio')}
          ${Number(v.estorno_previsto || 0) ? linha('Estorno', `<span class="bad-txt">${esc(m(v.estorno_previsto))} previsto · a Nio desconta no extrato</span>`) : ''}
          ${linha('Transição', esc(Number(v.bonus_transicao_previsto) ? `${m(v.bonus_transicao_previsto)} na comissão prevista` : '—'))}
          ${linha('Bônus M-10', m10)}
          ${NG.avisoDowngrade(v) && v.status !== 'saida' ? `<div class="faixa amarelo">${esc(NG.avisoDowngrade(v))}</div>` : ''}
          ${recompra ? `<div class="faixa amarelo">Possível recompra: o endereço já teve ${esc((recompra.detalhe || {}).anteriores || 1)} venda que saiu ou foi cancelada. A Nio aplica multa de R$ 500 por pedido — confirme com o Ricardo.</div>` : ''}`,
      },
      {
        id: 'contatos', titulo: 'Contatos e cadência',
        resumo: `hoje ${d.lim.hoje} de 2 · mês ${d.lim.mes} de 15${d.contatos[0] ? ` · último ${NG.quando(d.contatos[0].em)}` : ''}`,
        corpo: () => `<div class="faixa ${d.lim.hoje >= 2 || d.lim.mes >= 15 ? 'amarelo' : 'cinza'}">Contatos que nós fizemos: hoje ${esc(d.lim.hoje)} de 2 · mês ${esc(d.lim.mes)} de 15. Seg–sex 9–21, sáb 10–16, nunca domingo ou feriado.</div>
          ${d.contatos.length ? `<div class="timeline">${d.contatos.slice(0, 10).map((c) => `<div class="tl-item"><span class="tl-dot ${c.direcao === 'entrada' ? '' : 'futuro'}"></span><div class="tl-txt"><strong>${esc(CANAIS[c.canal] || c.canal)} · ${c.direcao === 'entrada' ? 'recebido' : 'enviado'} · ${esc(c.por)}</strong><span>${esc(NG.fmtDataHora(c.em))}${c.resumo ? ' · ' + esc(c.resumo) : ''}</span></div></div>`).join('')}</div>` : '<span class="nota-campo">Nenhum contato registrado.</span>'}`,
        rotuloEditar: 'Registrar contato',
        editar: v.status === 'saida' ? null : () => FORMS.contato(v),
      },
      {
        id: 'historico', titulo: 'Histórico de eventos',
        resumo: d.eventos.length ? `${d.eventos.length} ${d.eventos.length === 1 ? 'evento' : 'eventos'} · último ${NG.quando(d.eventos[d.eventos.length - 1].criado_em)}` : 'sem eventos',
        corpo: () => `<div class="timeline">${[...d.eventos].reverse().map((e) => eventoHtml(e, v)).join('') || '<span class="carregando">Sem eventos</span>'}${proximosMarcos(v)}</div>`,
      },
    ];
  }

  function render() {
    if (!raiz || !d) return;
    const v = d.v;
    const pr = NG.proximoPasso(v, (d.contatos[0] || {}).em);
    if (!abertos) { abertos = new Set(); const b = blocoPadrao(v, pr); if (b) abertos.add(b); }
    if (edicao) abertos.add(edicao);
    const destaque = pr.resolver ? BLOCO_DO_PASSO[pr.resolver] : null;
    const corpoAntes = raiz.querySelector('.f-corpo');
    const rolagem = corpoAntes ? corpoAntes.scrollTop : 0;
    const convAntes = raiz.querySelector('.f-conv-corpo');
    const rolagemConv = convAntes ? convAntes.scrollTop : 0;
    if (modo === 'gaveta') document.title = `${v.cliente_nome} · ${document.title.split(' · ').pop()}`;
    else document.title = `${v.cliente_nome} · NIOGEN`;

    raiz.innerHTML = `<div class="ficha f-${modo}${convAberta && d.conversaId ? ' conv-on' : ''}">
      ${painelConversa(v)}
      ${cabecalho(v)}
      <div class="f-corpo">
        ${faixaProximo(v, pr)}
        ${v.status === 'saida' ? '' : NG.selosFicha(d.avisos, { ignorar: v.id })}
        ${cartaoPendencia(v)}
        ${cartaoViabilidade(v)}
        ${cartaoPortal(v)}
        ${cartaoConferencia(v)}
        ${blocos(v).map((b) => {
          const aberto = abertos.has(b.id);
          const editando = edicao === b.id && b.editar;
          return `<section class="f-bloco${aberto ? ' aberto' : ''}${destaque === b.id ? ' marcado' : ''}" data-bloco="${b.id}">
            <button type="button" class="f-bloco-cab" data-f="bloco" aria-expanded="${aberto}"><b>${esc(b.titulo)}</b><span>${esc(b.resumo)}</span></button>
            <div class="f-bloco-corpo">
              ${editando ? b.editar() : b.corpo()}
              ${!editando && b.editar ? `<div class="f-bloco-pe"><button type="button" class="btn btn-sm" data-f="editar">${esc(b.rotuloEditar || 'Editar')}</button></div>` : ''}
            </div>
          </section>`;
        }).join('')}
      </div>
    </div>`;
    const corpo = raiz.querySelector('.f-corpo');
    if (corpo && modo === 'gaveta') corpo.scrollTop = rolagem;
    const convCorpo = raiz.querySelector('.f-conv-corpo');
    if (convCorpo) {
      if (convFim && conv && conv.id === d.conversaId) { convCorpo.scrollTop = convCorpo.scrollHeight; convFim = false; } else convCorpo.scrollTop = rolagemConv;
    }
    ligarDfvSeEditando();
    const f = raiz.querySelector('[data-form] [autofocus]');
    if (f) f.focus({ preventScroll: true });
  }

  function ligarDfvSeEditando() {
    consultarDfv = null;
    const bloco = raiz.querySelector('[data-dfv-campos]');
    if (!bloco) return;
    NG.ligarLinkDfv(raiz.querySelector('[data-dfv]'));
    consultarDfv = NG.ligarDfvAuto(bloco, () => ({ cep: d.v.cep, numero: d.v.numero, complemento: d.v.complemento }), {
      // Escolher a unidade do prédio grava o complemento (igual à venda.html).
      aoEscolher: async (comp) => {
        const { error } = await NG.sb.from('vendas').update({ complemento: comp || null }).eq('id', d.v.id);
        if (error) { NG.toast(NG.msgErro(error), 'bad'); return; }
        d.v.complemento = comp || null;
      },
      aoMudar: (r) => { if (r && r.resultado !== 'precisa_numero') NG.toast('Base DFV consultada — confira e toque em "Salvar consulta do DFV".', 'ok'); },
    });
  }

  async function recarregar() {
    if (!idAtual) return;
    const id = idAtual;
    const r = await carregar(id);
    if (id !== idAtual) return;   // trocou de venda no meio
    if (r.erro) {
      d = null;
      raiz.innerHTML = `<div class="ficha f-${modo}"><header class="f-cab"><div class="f-linha1"><h2>Venda</h2>${modo === 'gaveta' ? '<button type="button" class="g-fechar" data-f="fechar" aria-label="Fechar">×</button>' : ''}</div></header>
        <div class="f-corpo"><div class="placeholder">${esc(r.erro)} <a href="vendas.html">Voltar a Vendas</a></div></div></div>`;
      return;
    }
    d = r;
    render();
  }

  // ---------- eventos (delegação na raiz) ----------
  function fecharMenus() {
    raiz && raiz.querySelectorAll('.f-menu-lista').forEach((m) => { m.hidden = true; });
    raiz && raiz.querySelectorAll('[data-f="menu"]').forEach((b) => b.setAttribute('aria-expanded', 'false'));
  }
  function ligar(el) {
    el.addEventListener('click', async (ev) => {
      const r = ev.target.closest('[data-resolver]');
      if (r && d) {
        const qual = r.dataset.resolver;
        if (qual === 'pendencia') {   // 0064: leva ao cartão Pendência (vencida já abre o "Encerrar" para quem pode)
          formAtivo = d.pend && d.pend.vencida && ['admin', 'backoffice'].includes((NG.usuario || {}).perfil) ? 'pend_encerrar' : null;
          render();
          const c = raiz.querySelector('[data-pend-card]');
          if (c) c.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
          return;
        }
        if (qual === 'dfv') {   // abre o bloco Endereço em edição e já consulta a base
          edicao = 'endereco';
          formAtivo = null;
          render();
          if (consultarDfv) consultarDfv();
          const b = raiz.querySelector('[data-bloco="endereco"]');
          if (b) b.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
          return;
        }
        formAtivo = qual === 'reagendar' ? 'agendar' : qual;
        render();
        if (FORMS_NO_CARTAO.includes(formAtivo)) {
          const f = raiz.querySelector(`[data-form="${formAtivo}"]`);
          if (f) f.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
        }
        return;
      }
      const b = ev.target.closest('[data-f]');
      if (!b) { if (!ev.target.closest('.f-menu')) fecharMenus(); return; }
      const acao = b.dataset.f;
      if (acao !== 'menu') fecharMenus();
      if (acao === 'fechar') { NG.gaveta.fechar(); return; }
      if (acao === 'menu') {
        const lista = b.parentElement.querySelector('.f-menu-lista');
        lista.hidden = !lista.hidden;
        b.setAttribute('aria-expanded', String(!lista.hidden));
        return;
      }
      if (acao === 'copiar-endereco') {
        const t = enderecoPortal(d.v);
        try { await navigator.clipboard.writeText(t); NG.toast('Endereço copiado para colar no portal', 'ok'); } catch (e) { NG.toast(t); }
        return;
      }
      // Prompt 27: "Consultar no portal" é um link (abre a aba nova sozinho); aqui só copia "CEP número" para colar na busca.
      if (acao === 'consultar-portal') { copiar(cepNumero(d.v), `Copiado "${cepNumero(d.v)}" — cole na viabilidade do portal`); return; }
      if (acao === 'viab-form' || acao === 'ref-form') {
        formAtivo = acao === 'viab-form' ? 'viab' : 'ref';
        render();
        const f = raiz.querySelector(`[data-form="${formAtivo}"]`);
        if (f) f.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
        return;
      }
      if (acao === 'copiar-campo') {
        const todos = camposPortal(d.v).flatMap(([, cs]) => cs);
        const c = todos[Number(b.dataset.i)];
        if (c && c[1] && await copiar(c[1], `${rotCurto(c[0])} copiado`)) registrarCopia('campo');
        return;
      }
      if (acao === 'copiar-tudo') {
        if (await copiar(textoPortal(d.v), 'Dados copiados — cole no portal campo a campo')) registrarCopia('tudo');
        return;
      }
      if (acao === 'copiar-tel') {
        const t = fmtTel(d.v.cliente_whatsapp);
        try { await navigator.clipboard.writeText(t); NG.toast(`Telefone copiado: ${t}`, 'ok'); } catch (e) { NG.toast(t); }
        return;
      }
      if (acao === 'conversa') {
        if (convAberta) { convAberta = false; render(); } else abrirConversa();
        return;
      }
      if (acao === 'cartao') {
        const id = b.dataset.c;
        const forcado = (id === 'c_viab' && formAtivo === 'viab') || (id === 'c_portal' && formAtivo === 'ref');
        if (abertos.has(id) || forcado) { abertos.delete(id); if (forcado) formAtivo = null; } else abertos.add(id);
        render();
        return;
      }
      if (acao === 'bloco') {
        const id = b.closest('[data-bloco]').dataset.bloco;
        if (abertos.has(id)) { abertos.delete(id); if (edicao === id) edicao = null; } else abertos.add(id);
        render();
        return;
      }
      if (acao === 'editar') { edicao = b.closest('[data-bloco]').dataset.bloco; formAtivo = null; render(); return; }
      if (acao === 'cancelar') {
        if (b.closest('.f-bloco')) edicao = null; else formAtivo = null;
        saidaPreset = null;
        render();
        return;
      }
      if (acao === 'conf-tent-ok' || acao === 'conf-tent-nao') { b.disabled = true; await confTentativa(acao === 'conf-tent-ok'); return; }
      if (acao === 'conf-aprovar') { b.disabled = true; const ok = await gravar({ conferencia_status: 'aprovada' }, 'Conferência aprovada'); if (!ok && b.isConnected) b.disabled = false; return; }
      if (acao === 'conf-form-reprovar' || acao === 'conf-form-devolver') { formAtivo = acao === 'conf-form-reprovar' ? 'conf_reprovar' : 'conf_devolver'; render(); return; }
      if (acao === 'conf-gerar') { b.disabled = true; await confGerar(); return; }
      if (acao === 'pend-abrir' || acao === 'pend-adiar' || acao === 'pend-encerrar') {
        formAtivo = acao.replace('-', '_');
        render();
        const f = raiz.querySelector(`[data-form="${formAtivo}"]`);
        if (f) f.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
        return;
      }
      if (acao === 'pend-saida') { saidaPreset = d.pend ? d.pend.saida_sugerida : null; formAtivo = 'saida'; render(); return; }
      if (acao === 'dfv-salvar') { b.disabled = true; await salvarDfv(); b.disabled = false; return; }
      if (acao === 'dfv-dispensar') { await dispensarDfv(); }
    });
    el.addEventListener('submit', async (ev) => {
      const form = ev.target.closest('[data-form]');
      if (!form) return;
      ev.preventDefault();
      const salvar = SALVAR[form.dataset.form];
      if (!salvar) return;
      const bt = form.querySelector('[type=submit]');
      if (bt) bt.disabled = true;
      const ok = await salvar(new FormData(form), form);
      if (!ok && bt && bt.isConnected) bt.disabled = false;
    });
    el.addEventListener('change', (ev) => {
      const sel = ev.target.closest('[data-mover]');
      if (sel && sel.value && d) { mover(sel.value); return; }
      const mot = ev.target.closest('[name="motivo"]');
      if (mot) { const f = mot.form.querySelector('[data-futuro]'); if (f) f.hidden = !mot.value.startsWith('Interesse futuro'); return; }
    });
  }

  // "Mover para…": os mesmos destinos e campos de NG.moverStatus, mas o formulário abre na ficha.
  async function mover(destino) {
    const v = d.v;
    if (destino === v.status) return;
    if (destino === '1_vendido' && v.status === '0_qualificado') { formAtivo = 'pedido'; render(); return; }
    if (destino === '2_aguardando_instalacao') { formAtivo = 'mover_aguardando'; render(); return; }
    if (destino === 'saida') { formAtivo = 'saida'; render(); return; }
    formAtivo = null;
    await gravar({ status: destino }, `${NG.primeiroNome(v.cliente_nome)} → ${STATUS_MAP[destino].curto}`);
    if (raiz.querySelector('[data-mover]')) raiz.querySelector('[data-mover]').value = '';
  }

  document.addEventListener('click', (ev) => {
    // Links #venda=<id> (Quadro, Painel, Mari…): abrem a ficha sem recarregar. Ctrl/⌘/meio = nova aba (o hash abre a ficha lá).
    const a = ev.target.closest('a[href^="#venda="]');
    if (a && !ev.ctrlKey && !ev.metaKey && !ev.shiftKey && ev.button === 0) {
      const m = a.getAttribute('href').match(HASH);
      if (m) { ev.preventDefault(); abrir(m[1]); }
    }
    if (raiz && !ev.target.closest('.f-menu')) fecharMenus();
  });

  // ---------- gaveta + URL ----------
  function garantirGaveta() {
    if (gav) return;
    gav = document.createElement('aside');
    gav.className = 'gaveta larga';
    gav.id = 'ficha-venda';
    gav.setAttribute('aria-label', 'Ficha da venda');
    gav.setAttribute('aria-hidden', 'true');
    gav.innerHTML = '<div class="ficha-raiz"></div>';
    document.body.appendChild(gav);
    raiz = gav.querySelector('.ficha-raiz');
    ligar(raiz);
  }
  const idDoHash = () => { const m = location.hash.match(HASH); return m ? m[1] : null; };
  const semHash = () => `${location.pathname}${location.search}`;
  let tituloOriginal = document.title;

  function aoFecharGaveta() {
    idAtual = null;
    d = null;
    document.title = tituloOriginal;
    if (idDoHash()) {
      if (empurrou) { empurrou = false; history.back(); } else history.replaceState(history.state, '', semHash());
    }
  }
  async function mostrar(id) {
    garantirGaveta();
    if (idAtual !== id) {
      idAtual = id;
      d = null; abertos = null; edicao = null; formAtivo = null; convAberta = false; conv = null;
      raiz.innerHTML = '<div class="ficha f-gaveta"><div class="f-corpo"><div class="carregando">Carregando…</div></div></div>';
    }
    if (!gav.classList.contains('aberta')) {
      tituloOriginal = document.title;
      NG.gaveta.abrir(gav, { foco: false, aoFechar: aoFecharGaveta });
    }
    await recarregar();
  }
  function abrir(id) {
    if (!id) return;
    if (modo === 'pagina') { location.href = `venda.html?id=${id}`; return; }
    if (idDoHash() !== id) {
      if (idDoHash()) history.replaceState(null, '', `${semHash()}#venda=${id}`);   // troca de venda sem empilhar
      else { history.pushState({ ficha: id }, '', `${semHash()}#venda=${id}`); empurrou = true; }
    }
    mostrar(id);
  }
  function sincronizar() {
    if (modo === 'pagina') return;
    const id = idDoHash();
    if (id) { if (id !== idAtual) { empurrou = false; mostrar(id); } }
    else if (idAtual) { empurrou = false; NG.gaveta.fechar(); }
  }
  window.addEventListener('popstate', sincronizar);
  window.addEventListener('hashchange', sincronizar);

  // Página cheia (venda.html?id=): o mesmo componente, sem gaveta.
  async function pagina(el, id) {
    modo = 'pagina';
    raiz = el;
    ligar(raiz);
    idAtual = id;
    if (!id) { raiz.innerHTML = '<div class="placeholder">Venda não informada. <a href="vendas.html">Voltar a Vendas</a></div>'; return; }
    await recarregar();
  }

  window.NGFicha = {
    abrir,
    pagina,
    // Ouvinte chamado depois de cada gravação (a tela recarrega a lista).
    aoMudar(fn) { ouvintes.push(fn); },
    // Chamar depois do login: abre a ficha se a URL já vier com #venda=<id>.
    iniciar() { if (idDoHash()) { empurrou = false; mostrar(idDoHash()); } },
    get aberta() { return !!idAtual; },
  };
})();
