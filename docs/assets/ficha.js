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
 * 09/11 (0082, fluxo único do backoffice): os botões do próximo passo chamam backoffice_momento — Assumir · Registrar viabilidade ·
 * Gravar nº do pedido · Biometria Validada/Risco/Negado · Agendar — e atalhos "Devolver para a Mari" e "Cliente pediu para parar".
 * O banco grava a venda e enfileira etiqueta/nota/mensagem/resolver no Chatwoot (n8n backoffice_chatwoot); a ficha mostra em uma
 * linha o que o sistema fez. Validada abre o agendamento na sequência.
 * 09/11 (0089/0090, prompt Prompt_ajustes_operacao_ficha_conversa_091126_1535 · ponto 3): de cima para baixo — nome · cidade ·
 * plano · origem · barra CONVERSA (abre a conversa: no espaço da lista na Minha vez; à esquerda da ficha nas outras telas) ·
 * barra da JORNADA (5 etapas) · PRÓXIMO PASSO (um bloco, o botão e "o NIOGEN faz sozinho") · atalhos (Pendência, Devolver
 * para a Mari, Cliente pediu para parar, Saída) · 4 quadros de STATUS (NIOGEN · Nio · Chatwoot · Contrato) · LEMBRETES
 * automáticos · os blocos de antes recolhidos embaixo. A etapa só anda pelo botão: "Mover para…" ficou só para admin no "⋯".
 * Ordem: pedido → biometria → OS (é ela que faz a venda contar) → agendar (0096, "são etapas diferentes"). Texto e "precisa de ação" da v_jornada.
 * Ficha de CONVERSA (etapa 1, conversa sem venda): #conversa=<id> — NGFicha.abrirConversa(id).
 * Depende de app.js (NG) e conversa.js (NGConversa). Uso: NGFicha.abrir(id) · NGFicha.abrirConversa(id) · NGFicha.aoMudar(fn) ·
 * NGFicha.aoConversa(fn) (a tela abre a conversa no lugar dela) · NGFicha.lado(el) (ficha ao lado, sem gaveta) · NGFicha.pagina(el, id).
 */
(function () {
  'use strict';
  const { esc, STATUS_MAP, ORIGENS, FORMAS, SEGMENTOS } = NG;
  const HASH = /^#venda=([0-9a-f-]{36})$/i;
  const HASH_C = /^#conversa=([0-9a-f-]{36})$/i;

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
  let feitoUltimo = null;  // 0082: { resumo, aviso } do último momento (a linha "✓ …" embaixo do próximo passo)
  let detalhes = false;    // 0089: os blocos de antes, recolhidos embaixo
  let pendPreset = null;   // 0092: motivo pré-escolhido no "Abrir pendência" (ex.: viabilidade_confirmar)
  let planosCache = null;  // 0092: config_planos ativos (trocar plano / upsell)
  let linksCache = null;   // 0092: config_links (DFV, formulário de análise da Nio)
  let cvComp = null;       // 0090: NGConversa montado no painel da ficha
  let hostConversa = null; // 0090: a tela abre a conversa no lugar dela (Minha vez)
  let ladoEl = null;       // 0090: ficha ao lado (Minha vez · Lista), sem gaveta
  const ouvintes = [];
  const ehBO = () => ['admin', 'backoffice'].includes((NG.usuario || {}).perfil);

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
    '0_qualificado': 'Lead qualificado', '1_vendido': 'VENDA · OS aberta', '2_aguardando_instalacao': 'Aguardando instalação',
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
    } else if (e.tipo === 'backoffice') {
      // 0082: um botão do fluxo único — o que o sistema fez (etiqueta, nota, mensagem…) numa linha.
      const BIO_R = { validada: 'validada', risco: 'com risco', negado: 'crédito negado' };
      titulo = `NIOGEN · ${NG.MOMENTOS[dt.momento] || dt.momento}${dt.momento === 'biometria' && dt.resultado ? ` ${BIO_R[dt.resultado] || dt.resultado}` : ''}`;
      cor = dt.mensagem === 'bloqueada' || dt.aviso ? 'warn' : '';
      texto = `${NG.fmtDataHora(e.criado_em)}${quem}${dt.resumo ? ' · ' + esc(dt.resumo) : ''}${dt.aviso ? ' · ' + esc(dt.aviso) : ''}`;
    } else if (e.tipo === 'pedido_aberto_portal') {
      titulo = `Pedido aberto no portal${dt.pedido ? ` · nº ${dt.pedido}` : ''}`;
      texto = `${NG.fmtDataHora(e.criado_em)}${quem}${dt.origem === 'extensao' ? ' · pela extensão' : ''}`;
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
        ? NG.sb.from('mari_conversas').select('id, chatwoot_conversation_id, chatwoot_agente, chatwoot_time, chatwoot_status, chatwoot_etiquetas, humano_atribuido, nao_contatar, ultima_msg_lead_at').eq('venda_id', id).order('created_at', { ascending: false }).limit(1)
        : Promise.resolve({ data: [] }),
      NG.sb.from('contatos_cliente').select('id, canal, direcao, por, em, resumo, toque').eq('venda_id', id).order('em', { ascending: false }).limit(30),
      usuariosCache ? Promise.resolve(usuariosCache) : NG.carregarUsuarios(),
    ]);
    if (rv.error || !rv.data) return { erro: rv.error ? NG.msgErro(rv.error) : 'Venda não encontrada (ou sem permissão para vê-la).' };
    usuariosCache = ru;
    const v = rv.data;
    // 0048 (prompt 27): v_funil congela v.* — quem registrou a viabilidade do portal e a referência vêm da tabela.
    const rx27 = await NG.sb.from('vendas').select('nio_viab_por, ponto_referencia, nio_os, nio_os_em').eq('id', id).maybeSingle();
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
    const [rph, rmot, rav, rjo, rnm, rbq, rpl, rlk] = await Promise.all([
      NG.sb.from('venda_pendencias').select('*').eq('venda_id', id).order('aberta_em', { ascending: false }),
      motivosCache ? Promise.resolve({ data: motivosCache }) : NG.sb.from('config_motivos_pendencia').select('*').eq('ativo', true).order('ordem'),
      NG.sb.rpc('ficha_avisos', { p_venda: id }),
      NG.sb.from('v_jornada').select('*').eq('venda_id', id).maybeSingle(),   // 0090: etapa, próximo passo, precisa de ação
      convId ? NG.sb.from('mari_turnos').select('id', { count: 'exact', head: true }).eq('conversa_id', convId).in('papel', ['lead', 'mari', 'humano']) : Promise.resolve({ count: 0 }),
      convId ? NG.sb.from('chatwoot_acoes').select('id, payload, erro, criada_em').eq('conversa_id', convId).eq('status', 'bloqueada').order('criada_em', { ascending: false }).limit(1) : Promise.resolve({ data: [] }),
      planosCache ? Promise.resolve({ data: planosCache }) : NG.sb.from('config_planos').select('id, nome, nome_curto, preco, preco_cartao, cluster, portfolio, variante, forma_pagamento_permitida').eq('ativo', true).order('preco'),
      linksCache ? Promise.resolve({ data: linksCache }) : NG.sb.from('config_links').select('chave, url').in('chave', ['dfv_sudeste', 'nio_form_analise_viabilidade']),
    ]);
    // 10/11: faturas do M-10 (v_adimplencia), conciliação (v_conciliacao) e a regra de previsão do ciclo. As views ainda são
    // rascunho: sem elas, a ficha mostra "aguardando o extrato da Nio" (nunca dado de exemplo).
    const bo = ['admin', 'backoffice'].includes(perfil);
    const opc = (q) => q.then((x) => (x.error ? null : x.data), () => null);
    const [fatRow, concRow, cicloRow] = await Promise.all([
      v.instalado_em ? opc(NG.sb.from('v_adimplencia').select('faturas').eq('venda_id', id).maybeSingle()) : Promise.resolve(null),
      bo && v.comissao_paga != null ? opc(NG.sb.from('v_conciliacao').select('*').eq('venda_id', id).maybeSingle()) : Promise.resolve(null),
      bo ? opc(NG.sb.from('config_regras').select('valor').eq('chave', 'comissao_ciclo_regra').maybeSingle()) : Promise.resolve(null),
    ]);
    if (!rpl.error) planosCache = rpl.data || [];
    if (!rlk.error) linksCache = rlk.data || [];
    if (!rmot.error) motivosCache = rmot.data || [];
    const pendHist = (rph.data || []).filter((p) => p.encerrada_em).map((p) => ({ ...p, autor: nomeDe[p.encerrada_por] || nomeDe[p.aberta_por] }));
    const pendAberta = (rph.data || []).find((p) => !p.encerrada_em) || null;
    return {
      jor: rjo && !rjo.error ? rjo.data : null,
      faturas: fatRow && Array.isArray(fatRow.faturas) ? fatRow.faturas : null,
      concil: concRow || null,
      cicloRegra: cicloRow && cicloRow.valor && typeof cicloRow.valor === 'object' ? cicloRow.valor : null,
      planos: planosCache || [],
      links: Object.fromEntries((linksCache || []).map((l) => [l.chave, l.url])),
      nMsgs: rnm && rnm.count != null ? rnm.count : null,
      bloqueada: ((rbq && rbq.data) || [])[0] || null,
      avisos: rav && !rav.error ? rav.data : null,
      pend: NG.pendencia(v), pendAberta, pendHist, motivos: motivosCache || [],
      cad,
      parc, semResposta,
      v,
      eventos: (re.data || []).map((e) => ({ ...e, autor: nomeDe[e.criado_por] })),
      lim: rl.data || { hoje: 0, mes: 0 },
      adics: ra.data || [],
      conversaId: ((rc.data || [])[0] || {}).id || null,
      convInfo: (rc.data || [])[0] || null,   // 0082: dono no Chatwoot (Assumir só aparece sem dono)
      chatwoot: NG.linkChatwoot(((rc.data || [])[0] || {}).chatwoot_conversation_id),
      contatos: rk.data || [],
      usuarios: ru,
      nomeCurto,
    };
  }

  // ---------- próximo passo: botão e formulário que resolvem ----------
  const BOTAO = {
    pedido: 'Registrar pedido + OS', portal: 'Registrar pedido + OS (venda)', bio_status: 'Atualizar biometria', contato: 'Registrar contato',
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
    pedido: (v) => FORMS.portal(v),   // 0087: "Registrar venda" = pedido + OS (o mesmo formulário do portal)
    // Venda remota: o nosso time abre o pedido no portal e roda o crédito. Prompt 19: o link da biometria é disparado pela
    // própria Nio (WhatsApp + e-mail) na hora do pedido — salvar o nº do pedido marca a biometria pendente e a contagem
    // 24/72 h e o D+1 partem dali (trigger vendas_antes_biometria, 0032). O backoffice só avisa o cliente na conversa.
    portal: (v) => formWrap('portal', 'Pedido no portal',
      'Portal PAP (perfil BO): viabilidade · cadastro e crédito · oferta → grave o nº do pedido (etapa 3). A Nio manda o link da biometria ao cliente. A OS se abre DEPOIS da biometria validada, já com o dia e o período (é isso que faz a venda contar). Nunca abra pedido com CPF de teste.',
      `${botoesPortal}<span class="nota-campo mono">${esc(enderecoPortal(v))}</span>
       <div class="grade2"><label class="campo">Nº do pedido (portal PAP)<input type="text" name="pedido" value="${esc(v.nio_pedido || '')}" autocomplete="off" autofocus></label></div>
       <label class="campo">Análise de crédito<select name="credito">${NG.opcoes(NG.CREDITO, v.credito_resultado)}</select></label>
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
    agendar: (v) => formWrap('agendar', v.instalacao_agendada_para ? 'Reagendar a instalação' : 'Agendar a instalação',
      v.instalacao_agendada_para ? 'Exceção: só quando a Nio ou o cliente mudar a data. O NIOGEN confirma a nova data ao cliente sozinho.'
        : 'OS aberta. Agende no portal o dia e o período combinados com o cliente e grave aqui — o NIOGEN confirma ao cliente sozinho. Contrato: até 4 h da biometria validada.',
      `<div class="grade2">${campoData('Data da instalação', 'dia', v.instalacao_agendada_para ? NG.diaSP(v.instalacao_agendada_para) : amanhaISO(), 'required')}
       ${campoPeriodo('periodo', v.instalacao_agendada_para ? periodoDe(v.instalacao_agendada_para) : '08:00')}</div>`, v.instalacao_agendada_para ? 'Reagendar' : 'Agendar'),
    // 0089: etapa 2 → 3. Só o nº do pedido (a OS vem depois da biometria).
    pedido_so: (v) => formWrap('pedido_so', 'Gravar o pedido',
      'Viabilidade ok. Abra o Novo Pedido no portal (a extensão preenche), rode o crédito e grave aqui o nº do pedido. A Nio manda o link da biometria ao cliente e <b>o NIOGEN avisa o cliente sozinho</b> — não mande o aviso à mão.',
      `${botoesPortal}<div class="grade2"><label class="campo">Nº do pedido (portal PAP)<input type="text" name="pedido" value="${esc(v.nio_pedido || '')}" autocomplete="off" autofocus></label>
       <label class="campo">Análise de crédito<select name="credito">${NG.opcoes(NG.CREDITO, v.credito_resultado)}</select></label></div>
       <label class="check"><input type="checkbox" name="sem_aviso"> Já avisei o cliente do link da biometria (o NIOGEN não manda o aviso)</label>`, 'Gravar pedido'),
    // 0096: etapa 3 → 4 (VENDA). Só o nº da OS; agendar é o passo seguinte.
    os: (v) => formWrap('os', 'Abrir a OS = VENDA',
      'Biometria validada. Abra a OS no portal e grave aqui o número — com isso a venda conta. Depois vem o agendamento. Contrato: até 4 h da biometria validada.',
      `${botoesPortal}<div class="grade2"><label class="campo">Nº da OS<input type="text" name="os" value="${esc(v.nio_os || '')}" autocomplete="off" autofocus></label></div>`, 'Gravar a OS → vira Venda'),
    // 0089 (mantido): OS + dia + período num formulário só.
    os_agendar: (v) => formWrap('os_agendar', 'Abrir a OS e agendar = VENDA',
      'Biometria validada. No portal, abra a OS já com o dia e o período combinados com o cliente e grave aqui. Com isso, a venda conta. Contrato: até 4 h da biometria validada.',
      `${botoesPortal}<div class="grade2"><label class="campo">Nº da OS<input type="text" name="os" value="${esc(v.nio_os || '')}" autocomplete="off" autofocus></label>
       ${campoData('Dia da instalação', 'dia', amanhaISO(), `min="${hojeISO()}" required`)}
       ${campoPeriodo('periodo', '08:00')}</div>`, 'Gravar OS e agendamento → vira Venda'),
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
      `<label class="campo">Motivo<select name="motivo_pend" required autofocus><option value="">Escolher…</option>${(d.motivos || []).map((m) => `<option value="${esc(m.codigo)}"${pendPreset === m.codigo ? ' selected' : ''}>${esc(m.nome)} · destrava: ${esc(NG.QUEM_DESTRAVA[m.quem_destrava] || m.quem_destrava)}${m.exige_descricao ? ' (descreva)' : ''}</option>`).join('')}</select></label>
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
    avisarOuvintes(null);
    return true;
  }
  const quandoDe = (fd) => `${fd.get('dia')}T${fd.get('periodo')}:00-03:00`;
  // 0082: o botão do momento — o banco grava a venda e enfileira o Chatwoot; a ficha guarda a linha do que foi feito.
  function avisarOuvintes(r) { ouvintes.forEach((f) => { try { f(d && d.v, r || null); } catch (e) { /* tela que ouve */ } }); }
  async function rodarMomento(qual, dados) {
    const r = await NG.momento(d.v.id, qual, dados);
    if (!r) return null;
    feitoUltimo = { resumo: r.resumo, aviso: r.aviso || null };
    formAtivo = null;
    edicao = null;
    abertos = null;
    saidaPreset = null;
    await recarregar();
    avisarOuvintes(r);
    return r;
  }
  async function rodarMomentoConversa(qual) {
    if (qual === 'parar' && !window.confirm('O cliente pediu para parar?\n\nA conversa ganha a etiqueta nao-contatar, uma nota, é resolvida e ninguém mais chama esse cliente.')) return null;
    const r = await NG.momento(null, qual, { conversa_id: d.conversaId });
    if (!r) return null;
    feitoUltimo = { resumo: r.resumo, aviso: r.aviso || null };
    await recarregar();
    avisarOuvintes(r);
    return r;
  }
  // 0064: as três ações da pendência vão por RPC (SECURITY DEFINER, checam admin/backoffice e gravam em eventos_venda).
  async function rpcPendencia(fn, args, msgOk) {
    const { error } = await NG.sb.rpc(fn, args);
    if (error) { NG.toast(NG.msgErro(error), 'bad'); return false; }
    NG.toast(msgOk, 'ok');
    formAtivo = null;
    abertos = null;
    await recarregar();
    avisarOuvintes(null);
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
      // 0089: pedido novo = momento "pedido" (etapa 3: etiqueta, nota e aviso da biometria pelo sistema). A OS vem depois.
      if (campos.nio_pedido && campos.nio_pedido !== (v.nio_pedido || null) && v.status === '0_qualificado' && ehBO()) {
        return !!(await rodarMomento('pedido', { pedido: campos.nio_pedido, credito: campos.credito_resultado, link: link || null }));
      }
      return gravar(campos, 'Pedido no portal atualizado');
    },
    async bio_status(fd) {
      return gravar({ biometria_status: fd.get('biometria') || null, credito_resultado: fd.get('credito') || null }, 'Biometria e crédito atualizados');
    },
    async viab(fd) {
      // 0082: momento "viabilidade" (grava os mesmos campos e deixa a nota no Chatwoot).
      return !!(await rodarMomento('viabilidade', { resultado: fd.get('viab') || null, velocidade: fd.get('vel') || null,
        interesse: fd.get('interesse') || null, endereco_portal: fd.get('endp') || null }));
    },
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
      avisarOuvintes(null);
      return true;
    },
    async agendar(fd) {
      if (!fd.get('dia')) { NG.toast('Informe a data da instalação.', 'bad'); return false; }
      // 0089: reagendar (exceção, depois da venda) — confirma ao cliente e resolve a conversa, pelo sistema.
      return !!(await rodarMomento('agendar', { dia: fd.get('dia'), periodo: fd.get('periodo') }));
    },
    async pedido_so(fd) {
      const pedido = String(fd.get('pedido') || '').trim();
      if (!pedido) { NG.toast('Informe o nº do pedido.', 'bad'); return false; }
      return !!(await rodarMomento('pedido', { pedido, credito: fd.get('credito') || null, sem_aviso: !!fd.get('sem_aviso') }));
    },
    async os(fd) {
      const os = String(fd.get('os') || '').trim();
      if (!os) { NG.toast('Informe o nº da OS.', 'bad'); return false; }
      return !!(await rodarMomento('os', { os }));
    },
    async os_agendar(fd) {
      const os = String(fd.get('os') || '').trim();
      if (!os) { NG.toast('Informe o nº da OS.', 'bad'); return false; }
      if (!fd.get('dia')) { NG.toast('Informe o dia da instalação.', 'bad'); return false; }
      return !!(await rodarMomento('os_agendar', { os, dia: fd.get('dia'), periodo: fd.get('periodo') }));
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
      pendPreset = null;
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
    async ed_plano(fd) {
      const id = fd.get('plano');
      const forma = fd.get('forma');
      if (!id || !forma) { NG.toast('Escolha o plano e a forma de pagamento.', 'bad'); return false; }
      const p = (d.planos || []).find((x) => x.id === id);
      const antes = `${d.nomeCurto || d.v.plano_nome || '—'} · ${FORMAS[d.v.forma_pagamento] || '—'}`;
      const ok = await gravar({ plano_id: id, forma_pagamento: forma }, `Plano trocado: ${p ? p.nome : 'novo plano'} · ${FORMAS[forma]}`);
      if (ok) {
        await NG.sb.from('eventos_venda').insert({ venda_id: d.v.id, tipo: 'plano_trocado', detalhe: { antes, depois: `${p ? p.nome : id} · ${FORMAS[forma]}` } });
      }
      return ok;
    },
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
        nio_os: String(fd.get('os') || '').trim() || null,
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
  const DESTINOS = [['0_qualificado', 'Lead qualificado'], ['2_aguardando_instalacao', 'Ativação/Agenda'],
    ['3_instalado', 'Instalada'], ['saida', 'Saída']];   // só admin (menu ⋯); ativo vem do OSAB

  function cabecalho(v) {
    const ehAdmin = (NG.usuario || {}).perfil === 'admin';
    const atual = NG.etapaDe(v).id;
    const ops = DESTINOS.filter(([st]) => NG.etapaDe(st).id !== atual);
    const ref = v.origem_ref && !/^mari:/i.test(v.origem_ref) ? ` · ${v.origem_ref}` : '';
    const linha2 = [[v.bairro, v.cidade].filter(Boolean).join(' · '), NG.origemTxt(v) + ref].filter(Boolean).join(' · ');
    const menu = [
      d.chatwoot ? `<a role="menuitem" href="${esc(d.chatwoot)}" target="_blank" rel="noopener">Conversa no Chatwoot ↗</a>` : '',
      v.cliente_whatsapp ? '<button type="button" role="menuitem" data-f="copiar-tel">Copiar telefone</button>' : '',
      d.conversaId ? `<a role="menuitem" href="mari.html?conversa=${esc(d.conversaId)}">Ver na tela Mari</a>` : '',
      `<a role="menuitem" href="vendas.html?vista=quadro&amp;etapa=${esc(atual)}">Ver no Funil (Quadro)</a>`,
      modo !== 'pagina' ? `<a role="menuitem" href="venda.html?id=${esc(v.id)}" target="_blank" rel="noopener">Abrir em página cheia ↗</a>` : '',
      // 0089: a etapa só anda pelo botão. "Mover para…" fica só para o admin corrigir à mão (as travas do banco valem igual).
      ehAdmin ? `<span class="f-menu-sep" role="separator">Admin · mover para</span>${ops.map(([st, nome]) => `<button type="button" role="menuitem" data-f="mover" data-st="${st}">${esc(nome)}</button>`).join('')}` : '',
    ].filter(Boolean).join('');
    return `<header class="f-cab">
      ${modo === 'pagina' ? '<a class="voltar" href="vendas.html">← Funil de vendas</a>' : ''}
      <div class="f-linha1"><div class="f-nome"><h2>${esc(v.cliente_nome)}</h2>${linhaPlano(d.nomeCurto || v.plano_nome, v.valor_mensal, v.forma_pagamento)}${seloData(v)}</div>
        <div class="f-ctl">${botaoVoltar()}<div class="f-menu"><button type="button" class="btn f-mais" data-f="menu" aria-haspopup="menu" aria-expanded="false" aria-label="Mais ações">⋯</button>
          <div class="f-menu-lista" role="menu" hidden>${menu}</div></div>
        ${modo !== 'pagina' ? '<button type="button" class="g-fechar" data-f="fechar" aria-label="Fechar a ficha">×</button>' : ''}</div></div>
      <div class="f-local">${linkConversa()}${chipsConversa(d.convInfo)}<span class="f-local-txt">${esc(linha2 || '—')}</span></div>
    </header>`;
  }

  // ---------- 10/11 (Prompt_pendencia_some_ao_responder, Parte 2): ficha mais leve — nada sai, muda o lugar e o peso ----------
  const FORMA_TXT = { cartao: 'cartão', boleto: 'boleto', debito: 'débito em conta', debito_automatico: 'débito automático', pix: 'Pix' };
  // Plano embaixo do nome, em letra menor: "nome do plano · R$ valor · forma". Sem plano, não mostra.
  function linhaPlano(nome, valor, forma) {
    if (!nome) return '';
    const p = [nome, valor != null && Number(valor) ? NG.fmtMoeda(valor) : null, forma ? FORMA_TXT[forma] || String(forma).replace(/_/g, ' ') : null].filter(Boolean);
    return `<p class="f-plano">${esc(p.join(' · '))}</p>`;
  }
  const ICO_CAL = '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/></svg>';
  const periodoTxt = (v) => (v.instalacao_turno === 'tarde' || (v.instalacao_turno !== 'manha' && periodoDe(v.instalacao_agendada_para) === '13:00') ? 'tarde' : 'manhã');
  const dataCurta = (x) => `${NG.fmtDiaSemana(x)} ${NG.fmtData(x)}`.toLowerCase();
  // Data logo de cara: agendada (azul) ou instalada (verde). Sem data, nada.
  function seloData(v) {
    if (v.instalado_em) return `<span class="f-data ok">${ICO_CAL}Instalada em ${esc(NG.fmtData(v.instalado_em))}</span>`;
    if (v.instalacao_agendada_para && v.status !== 'saida') return `<span class="f-data">${ICO_CAL}Instalação agendada · ${esc(dataCurta(v.instalacao_agendada_para))} · ${esc(periodoTxt(v))}</span>`;
    return '';
  }
  // Status da conversa ao lado da pílula "💬 Conversa · #nº" (Aberta · dono · janela), no mesmo tamanho pequeno.
  function chipsConversa(cv) {
    if (!cv || !cv.chatwoot_conversation_id) return d.conversaId ? '' : '<span class="f-chip">sem conversa</span>';
    const dono = donoConversa(cv);
    return `<span class="f-chip">${cv.chatwoot_status === 'resolved' ? 'Resolvida' : 'Aberta'}</span><span class="f-chip">${dono.html}</span><span class="f-chip">Janela ${esc(janelaTxt(cv))}</span>`;
  }
  // Régua de 5 passos numa linha (mesma largura): ícone + nome e, embaixo, o detalhe. Ordem da jornada.
  function regua(passos) {
    return `<ol class="f-regua" aria-label="Passos da venda">${passos.map((p) => `<li class="f-rp ${p.s}"><span class="f-rp-t"><i aria-hidden="true">${p.s === 'ok' ? '✓' : p.s === 'wa' ? '⚠' : '○'}</i>${esc(p.nome)}</span><small class="f-rp-d${p.azul ? ' azul' : ''}" title="${esc(p.d || '')}">${esc(p.d || '—')}</small></li>`).join('')}</ol>`;
  }
  function passosVenda(v) {
    const viab = v.nio_viab_resultado;
    const pViab = NG.portalViavel(v) ? { s: 'ok', d: 'portal · ok' }
      : viab === 'viavel' ? { s: 'wa', d: 'vencida · consultar de novo' }
      : ['sem_viabilidade', 'nao_encontrado', 'posse'].includes(viab) ? { s: 'wa', d: (NG.VIAB_NIO[viab] || viab).toLowerCase() }
      : { s: 'no', d: '' };
    const bio = v.biometria_status;
    const pBio = bio === 'validada' ? { s: 'ok', d: v.biometria_validada_em ? `validada ${NG.fmtData(v.biometria_validada_em)}` : 'validada' }
      : v.credito_resultado === 'negado' ? { s: 'wa', d: 'crédito negado' }
      : bio === 'com_risco' ? { s: 'wa', d: 'com risco' }
      : v.biometria_link_enviado_em ? { s: 'no', d: `link da Nio ${NG.fmtData(v.biometria_link_enviado_em)}` }
      : { s: 'no', d: '' };
    const pendNio = v.nio_pendencia_cod || v.nio_pendencia_desc;
    const pInst = v.instalado_em ? { s: 'ok', d: NG.fmtData(v.instalado_em) }
      : pendNio ? { s: 'wa', d: `pendência Nio${v.nio_pendencia_cod ? ' ' + v.nio_pendencia_cod : ''}` }
      : v.instalacao_agendada_para ? { s: 'no', d: `${dataCurta(v.instalacao_agendada_para)} · ${periodoTxt(v)}`, azul: true }
      : { s: 'no', d: '' };
    return [
      { nome: 'Viabilidade', ...pViab },
      { nome: 'Pedido', s: v.nio_pedido ? 'ok' : 'no', d: v.nio_pedido ? `nº ${v.nio_pedido}` : '' },
      { nome: 'Biometria', ...pBio },
      { nome: 'OS', s: v.nio_os ? 'ok' : 'no', d: v.nio_os ? `nº ${v.nio_os}` : '' },
      { nome: 'Instalação', ...pInst },
    ];
  }
  // Próximo passo: TODO quadro nasce recolhido e com a mesma altura (rótulo + uma linha); clique expande as ações.
  let passoAberto = new Set();
  function quadroPasso(k, cls, rot, txt, corpo, forcar) {
    const aberto = !!corpo && (forcar || passoAberto.has(k));
    return `<section class="f-prox f-pp ${cls}${aberto ? ' aberto' : ''}" aria-label="Próximo passo">
      <button type="button" class="f-pp-cab" data-f="passo" data-k="${esc(k)}" aria-expanded="${aberto}" title="${esc(txt)}"${corpo ? '' : ' disabled'}>
        <span class="f-rot f-pp-rot"><span>${esc(rot)}</span>${corpo ? `<span aria-hidden="true">${aberto ? '▾' : '▸'}</span>` : ''}</span><b>${esc(txt || '—')}</b></button>
      ${aberto ? `<div class="f-pp-corpo">${corpo}</div>` : ''}</section>`;
  }
  // Estorno: o que já foi conferido (travas do contrato). Com trava, chip vermelho com o motivo.
  function linhaEstorno(falhas, conferidos) {
    return `<div class="f-st-g"><span class="f-rot">ESTORNO</span>${falhas.length ? falhas.map((x) => `<span class="f-chip bad">✕ ${esc(x)}</span>`).join('')
      : `<span class="f-chip ok" title="${esc(`Conferido: ${conferidos}`)}">✓ sem risco</span><span class="f-st-nota">${esc(conferidos)}</span>`}</div>`;
  }
  const MES_CURTO = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'];
  const partesSP = (x) => { const s = NG.diaSP(x); return { a: Number(s.slice(0, 4)), m: Number(s.slice(5, 7)), dia: Number(s.slice(8, 10)) }; };
  const mesAno = (a, m) => { const mm = ((m - 1) % 12 + 12) % 12; const aa = a + Math.floor((m - 1) / 12); return `${MES_CURTO[mm]}/${String(aa).slice(2)}`; };
  // Previsão do ciclo da comissão (config_regras.comissao_ciclo_regra — placeholder até a Nio confirmar; sempre "previsão").
  function cicloPrevisto(base) {
    const r = d.cicloRegra;
    if (!base || !r) return null;
    const p = partesSP(base);
    const corte = Number(r.corte_dia) || 15;
    return p.dia <= corte ? `${r.rotulo_ate_corte || '2ª quinz.'} ${mesAno(p.a, p.m)}` : `${r.rotulo_depois || '1ª quinz.'} ${mesAno(p.a, p.m + 1)}`;
  }
  // Comissão de relance (admin e backoffice): um chip por fato. O quadro detalhado continua em "Mais detalhes".
  function linhaComissao(v) {
    if (!ehBO() || v.status === 'saida' || (v.comissao_prevista == null && v.comissao_paga == null)) return '';
    const m = NG.fmtMoeda;
    const c = [];
    if (v.comissao_paga != null) {
      c.push(`<span class="f-chip ok">✓ paga ${esc(m(v.comissao_paga))}</span>`);
      if (v.ciclo_pago) c.push(`<span class="f-chip">ciclo ${esc(v.ciclo_pago)}</span>`);
      const k = d.concil;
      if (k && k.situacao === 'bate') c.push('<span class="f-chip ok">conciliação · bate</span>');
      else if (k && k.situacao === 'falta_nio') c.push('<span class="f-chip bad">falta na Nio</span>');
      else if (k && k.situacao === 'diferenca') {
        const ate = k.contestar_ate ? NG.fmtData(k.contestar_ate) : null;
        const perto = k.contestar_ate && (new Date(k.contestar_ate) - Date.now()) / 86400000 <= 15;
        c.push(`<span class="f-chip ${perto ? 'bad' : 'wa'}">⚠ diferença ${esc(m(k.diferenca))}${ate ? ` · contestar até ${esc(ate)}` : ''}</span>`);
      } else c.push('<span class="f-st-nota">conciliação: aguardando o extrato da Nio</span>');
    } else {
      c.push(`<span class="f-chip">prevista ${esc(m(v.comissao_prevista))}</span>`);
      const ciclo = cicloPrevisto(v.instalado_em || v.instalacao_agendada_para);
      if (ciclo) c.push(`<span class="f-chip info" title="Regra do ciclo ainda não confirmada pela Nio">previsão: ciclo ${esc(ciclo)}</span>`);
      c.push('<span class="f-st-nota">aguardando o extrato da Nio</span>');
    }
    if (Number(v.estorno_previsto || 0)) c.push(`<span class="f-chip bad">estorno ${esc(m(v.estorno_previsto))} · desconta no próximo ciclo</span>`);
    if (Number(v.bonus_m10_potencial || 0)) {
      const base = v.ativado_em || v.instalado_em;
      const p = base ? partesSP(base) : null;
      c.push(`<span class="f-st-nota">M-10 ${esc(m(v.bonus_m10_potencial))}${p ? ` · previsto ${esc(mesAno(p.a, p.m + 10))}` : ' · potencial'}</span>`);
    }
    return `<div class="f-st-g"><span class="f-rot">COMISSÃO</span>${c.join('')}</div>`;
  }
  // As 10 bolinhas das faturas (M-10) — a mesma regra da Adimplência (NG.faturasBolas). Sem extrato: contorno, nunca exemplo.
  function linhaFaturas(v) {
    if (!v.instalado_em || v.status === 'saida') return '';
    const fat = Array.isArray(d.faturas) ? d.faturas : [];
    const bolas = NG.faturasBolas(fat);
    if (!fat.length) {
      return `<div class="f-st-g"><span class="f-rot">FATURAS</span>${NG.faturasBolinhas(bolas, 'Faturas ainda não chegaram')}<span class="f-st-nota">aguardando o extrato da Nio</span></div>`;
    }
    const pagas = bolas.filter((b) => b.e.cls === 'paga').length;
    const base = v.ativado_em || v.instalado_em;
    const p = partesSP(base);
    const m10 = Number(v.bonus_m10_potencial || 0) ? ` · bônus M-10 ${NG.fmtMoeda(v.bonus_m10_potencial)} apurado em ${mesAno(p.a, p.m + 10)}` : '';
    return `<div class="f-st-g"><span class="f-rot">FATURAS</span>${NG.faturasBolinhas(bolas)}<span class="f-st-nota">${esc(`${pagas}/${NG.N_FATURAS} pagas${m10}`)}</span></div>`;
  }
  // Modo foco da Minha vez: "← Lista" no cabeçalho da ficha (a tela diz o que fazer).
  let voltarFn = null;
  let largo = false;
  const botaoVoltar = () => (voltarFn && modo === 'lado' ? '<button type="button" class="btn btn-sm f-voltar" data-f="voltar-lista" title="Volta para a lista (Esc)">← Lista</button>' : '');

  // ---------- conversa da Mari (orelha à esquerda da ficha, 07/11) ----------
  // Só para quem lê mari_conversas (admin/backoffice): sem conversaId, sem orelha. Mesmos balões da tela Mari, só texto.
  function barraConversa(info) {
    if (!d.conversaId) return '';
    const cv = d.convInfo || info || {};
    const dono = donoConversa(cv);
    const st = cv.chatwoot_status === 'resolved' ? 'resolvida' : 'aberta';
    const n = d.nMsgs != null ? `${d.nMsgs} ${d.nMsgs === 1 ? 'mensagem' : 'mensagens'} · ` : '';
    return `<button type="button" class="f-convbar${convAberta ? ' on' : ''}" data-f="conversa" aria-expanded="${convAberta}">
      <span class="f-cb-ico" aria-hidden="true">💬</span><span class="f-cb-txt"><b>Conversa no WhatsApp</b><small>${esc(n)}${esc(st)} · ${dono.html}</small></span>
      <span class="f-cb-acao">${convAberta ? 'fechar' : 'abrir ⟵'}</span></button>`;
  }
  function painelConversa() {
    if (!d.conversaId || hostConversa) return '';
    return `<section class="f-conv" id="f-conv" aria-label="Conversa"${convAberta ? '' : ' hidden'}><div class="f-conv-host"></div></section>`;
  }
  function montarConversaInterna() {
    const host = raiz.querySelector('.f-conv-host');
    if (!host || !convAberta) { if (cvComp && !convAberta) { cvComp.destruir(); cvComp = null; } return; }
    if (cvComp && cvComp.id === d.conversaId && host.firstChild) return;
    if (cvComp) cvComp.destruir();
    cvComp = NGConversa.montar(host, { conversaId: d.conversaId, nome: d.v ? d.v.cliente_nome : null, rotuloFechar: '× Fechar',
      aoFechar: () => { convAberta = false; render(); }, aoMudar: (r) => recarregar({ quieto: !!(r && r.eco) }) });
  }
  function reporConversa(vivo, foco) {
    const host = raiz.querySelector('.f-conv-host');
    if (vivo && host && cvComp && cvComp.id === d.conversaId) {
      host.appendChild(vivo);
      if (foco && vivo.contains(foco)) foco.focus({ preventScroll: true });   // mover o nó tira o cursor da caixa: devolve
      return;
    }
    if (cvComp) { cvComp.destruir(); cvComp = null; }
    montarConversaInterna();
  }
  function abrirConversa() {
    if (hostConversa) { hostConversa({ conversaId: d.conversaId, nome: d.v ? d.v.cliente_nome : (d.conv && d.conv.nome), aoMudar: (r) => recarregar({ quieto: !!(r && r.eco) }) }); return; }
    convAberta = true;
    render();
  }
  // Esc fecha primeiro a conversa, depois a ficha (captura antes do Esc da gaveta).
  window.addEventListener('keydown', (ev) => {
    if (ev.key !== 'Escape' || !convAberta || !d || hostConversa || document.querySelector('dialog[open]') || document.querySelector('.dica-pop')) return;
    ev.stopPropagation();
    convAberta = false;
    render();
  }, true);

  // Dono da conversa com ícone de traço: robô = Mari, pessoa = humano (o nome; "você" só quando é você).
  const ICO_ROBO = '<svg class="ico-dono" viewBox="0 0 16 16" aria-hidden="true"><rect x="3" y="5" width="10" height="8" rx="2"/><path d="M8 2v3M6 9h0M10 9h0"/></svg>';
  const ICO_PESSOA = '<svg class="ico-dono" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="5" r="2.5"/><path d="M3 14c0-2.8 2.2-4.5 5-4.5s5 1.7 5 4.5"/></svg>';
  function donoConversa(cv) {
    const eu = ((NG.usuario || {}).nome || '').trim();
    if (!cv || !cv.chatwoot_conversation_id) return { tipo: null, html: 'sem conversa' };
    if (cv.nao_contatar) return { tipo: null, html: 'não contatar' };
    // 0091: assumida vale mesmo com a conversa resolvida (o Chatwoot sincroniza depois).
    if (cv.chatwoot_agente) return { tipo: 'pessoa', html: `${ICO_PESSOA} ${esc(cv.chatwoot_agente === eu ? 'você' : cv.chatwoot_agente)}` };
    if (cv.humano_atribuido) return { tipo: 'pessoa', html: `${ICO_PESSOA} time (assumida)` };
    if (cv.chatwoot_status === 'resolved') return { tipo: 'mari', html: `${ICO_ROBO} sem dono (a Mari volta se o cliente escrever)` };
    if (cv.chatwoot_time) return { tipo: 'time', html: `${ICO_PESSOA} time backoffice` };
    return { tipo: 'mari', html: `${ICO_ROBO} Mari atendendo` };
  }
  const NIVEL_ROT = { agora: 'PRÓXIMO PASSO · AGORA', hoje: 'PRÓXIMO PASSO · HOJE', espera: 'PRÓXIMO PASSO · AGUARDANDO', ok: 'PRÓXIMO PASSO · NADA A FAZER', fora: 'FORA DA JORNADA' };
  const NIVEL_CLS = { agora: 'bad', hoje: 'warn', espera: 'espera', ok: 'ok', fora: 'dim' };
  // O que o NIOGEN faz sozinho em cada botão (o texto que aparece embaixo do botão).
  const SOZINHO = {
    assumir: 'atribui a você no Chatwoot, cala a Mari e para a cadência.',
    viabilidade: 'nota no Chatwoot. Sem viabilidade: tente variações de CEP/rua/nº ou abra a pendência "Nio confirma".',
    pedido: 'etiqueta biometria-pendente · nota · avisa o cliente do link da biometria.',
    biometria: 'Validada: o próximo passo vira abrir a OS (4 h). Negado: pede outro CPF ao cliente e abre a pendência.',
    os: 'nota no Chatwoot. Com a OS a venda conta; o próximo passo é agendar a instalação.',
    agendar: 'etiqueta instalacao-agendada · nota · confirma o dia ao cliente · resolve a conversa (sem dono; a Mari volta se ele escrever).',
    os_agendar: 'etiqueta instalacao-agendada · nota · confirma o dia ao cliente · resolve a conversa (sem dono; a Mari volta se ele escrever).',
    reagendar: 'confirma a nova data ao cliente e resolve a conversa.',
    docs: 'registra a entrega (contrato: 15 dias depois da instalação).',
    pendencia: 'a venda sai da sua vez até a data de revisão e a cadência da Mari pausa.',
    manual: 'conta no limite do contrato e sai da sua vez.',
    responder: 'a resposta sai como pessoa (a Mari não responde).',
  };

  function faixaProximo(v, pr) {
    const jReal = d.jor;
    // Alerta da CONVERSA (mensagem que não saiu, cliente esperando): faixa própria em cima; o passo da VENDA segue com os botões dele.
    const alertaConv = jReal && ['manual', 'responder'].includes(jReal.botao) && jReal.nivel === 'agora';
    const j = alertaConv ? null : jReal;
    const nivel = j ? j.nivel : (pr.nivel === 'bad' ? 'agora' : pr.nivel === 'warn' ? 'hoje' : pr.espera ? 'espera' : 'ok');
    const texto = j ? j.o_que_fazer : pr.txt;
    const etapa = j ? j.etapa : (NG.etapaDe(v).n || 0);
    const bo = ehBO();
    const cv = d.convInfo;
    const semDono = bo && cv && cv.chatwoot_conversation_id && donoConversa(cv).tipo === 'mari' && !cv.nao_contatar && v.status !== 'saida';
    const B = (attrs, rot, forte) => `<button type="button" class="btn ${forte ? 'btn-acc' : ''}" ${attrs}>${esc(rot)}</button>`;
    const bts = [];
    let sozinho = '';
    let nota = '';
    const form = formAtivo && FORMS[formAtivo] && !formAtivo.startsWith('conf_') && !FORMS_NO_CARTAO.includes(formAtivo) ? FORMS[formAtivo](v) : '';
    if (!bo) {
      // Vendedor: o passo de sempre (contato, documentos…). Os botões dos momentos são do backoffice.
      if (pr.resolver && BOTAO[pr.resolver] && !['pedido', 'portal', 'bio_status', 'os', 'agendar', 'reagendar', 'os_agendar'].includes(pr.resolver)) bts.push(`<button type="button" class="btn" data-resolver="${pr.resolver}">${esc(BOTAO[pr.resolver])}</button>`);
      if (etapa >= 2 && etapa <= 3) nota = 'O backoffice anda a venda pelo portal (pedido → biometria → OS → agendamento).';
    } else if (j && j.botao === 'pendencia') {
      bts.push(B('data-resolver="pendencia"', 'Ver a pendência', nivel === 'agora'));
      sozinho = '';
    } else if (j && j.botao === 'conferencia') {
      bts.push(B('data-f="ir-conferencia"', 'Conferir a venda do parceiro', true));
    } else if (semDono && etapa <= 3 && v.status !== 'saida') {
      bts.push(B('data-momento="assumir"', 'Assumir', true));
      sozinho = SOZINHO.assumir;
    } else if (etapa === 2 && v.status === '0_qualificado') {
      if (!NG.portalViavel(v) && ['sem_viabilidade', 'nao_encontrado'].includes(v.nio_viab_resultado)) {
        // 0092 (Rogério): portal negou → DFV; endereço viável a até 200 m → formulário de análise da Nio + pendência.
        const L = d.links || {};
        bts.push(L.dfv_sudeste ? `<a class="btn" href="${esc(L.dfv_sudeste)}" target="_blank" rel="noopener">Conferir no DFV ↗</a>` : '',
          L.nio_form_analise_viabilidade ? `<a class="btn" href="${esc(L.nio_form_analise_viabilidade)}" target="_blank" rel="noopener">Formulário de análise da Nio ↗</a>` : '',
          B('data-f="pend-viab"', '⏸ Pendência: Nio confirma', true),
          B('data-f="viab-rapido" data-r="viavel"', 'Deu Viável', false));
        nota = 'Antes de desistir: tente variações de CEP, rua e número no portal. No DFV, se houver endereço viável a até 200 m do cliente, mande o formulário de análise da Nio e abra a pendência — a venda sai da sua vez até a resposta.';
        sozinho = 'a pendência tira a venda da sua vez até a data de revisão e pausa os lembretes da Mari.';
      } else if (!NG.portalViavel(v)) {
        bts.push(`<a class="btn" href="${NG.PORTAL_PAP_NOVO_PEDIDO}" target="_blank" rel="noopener" data-f="consultar-portal" title="${esc(NG.ajuda.viab_consultar)}">Abrir o portal ↗</a>`,
          B('data-f="viab-rapido" data-r="viavel"', 'Viável', true), B('data-f="viab-rapido" data-r="sem_viabilidade"', 'Sem viabilidade', false),
          B('data-f="viab-form"', 'Detalhes…', false));
        sozinho = SOZINHO.viabilidade + ' Também dá para registrar pela extensão, na etapa 2 do portal.';
      } else {
        if (!form) { formAtivoPadrao = 'pedido_so'; }
        sozinho = SOZINHO.pedido;
      }
    } else if (etapa === 3) {
      if (v.biometria_status === 'validada') {
        if (!form) formAtivoPadrao = 'os';
        sozinho = SOZINHO.os;
      } else {
        bts.push(B('data-momento="biometria" data-r="validada"', '✓ Biometria validada', true), B('data-momento="biometria" data-r="risco"', 'Com risco', false),
          B('data-momento="biometria" data-r="negado"', 'Crédito negado', false));
        sozinho = SOZINHO.biometria;
      }
    } else if (etapa === 4 && !v.instalacao_agendada_para) {
      if (!form) formAtivoPadrao = 'agendar';
      sozinho = SOZINHO.agendar;
    } else if (etapa === 4) {
      bts.push(B('data-resolver="reagendar"', 'Reagendar', nivel === 'agora' || nivel === 'hoje'));
      sozinho = SOZINHO.reagendar;
      if (nivel === 'espera' || nivel === 'ok') nota = 'Nada a fazer: vira Instalada sozinha quando a baixa da Nio chega no OSAB. Só volta para a sua vez se a data passar sem baixa.';
    } else if (etapa === 5 && v.status === '3_instalado' && !v.docs_entregues_em) {
      bts.push(B('data-resolver="docs"', 'Documentos ok', true));
      sozinho = SOZINHO.docs;
    }
    // Formulário padrão do passo (pedido / OS / agendar) aparece aberto dentro do bloco.
    let corpoForm = form;
    if (!corpoForm && formAtivoPadrao && FORMS[formAtivoPadrao]) corpoForm = FORMS[formAtivoPadrao](v).replace(`data-f="cancelar">Cancelar`, 'data-f="cancelar" hidden>Cancelar');
    formAtivoPadrao = null;
    const feito = feitoUltimo ? `<div class="f-feito${feitoUltimo.aviso ? ' warn' : ''}" role="status">${esc(feitoUltimo.resumo)}${feitoUltimo.aviso ? `<span>${esc(feitoUltimo.aviso)}</span>` : ''}</div>` : '';
    let faixaConv = '';
    if (alertaConv && bo) {
      const bc = jReal.botao === 'manual' && d.bloqueada
        ? [B('data-f="manual-copiar"', 'Copiar o texto', false), d.chatwoot ? `<a class="btn" href="${esc(d.chatwoot)}" target="_blank" rel="noopener">Chatwoot ↗</a>` : '', B('data-f="manual-mandei"', 'Já mandei', true)]
        : [B('data-f="conversa"', 'Abrir a conversa e responder', true)];
      faixaConv = quadroPasso('conv', 'bad f-alerta-conv', 'CONVERSA · AGORA', jReal.o_que_fazer,
        `<div class="f-prox-bts">${bc.filter(Boolean).join('')}</div><span class="f-sozinho">O NIOGEN faz sozinho: ${esc(jReal.botao === 'manual' ? SOZINHO.manual : SOZINHO.responder)}</span>`);
    }
    // 10/11: o quadro nasce recolhido (rótulo + uma linha); expandido mostra o botão principal, o "faz sozinho" e as ações do passo.
    const corpo = `${nota ? `<span class="f-nota">${esc(nota)}</span>` : ''}
        ${bts.filter(Boolean).length && !form ? `<div class="f-prox-bts">${bts.filter(Boolean).join('')}</div>` : ''}
        ${corpoForm ? `<div class="f-prox-form">${corpoForm}</div>` : ''}
        ${sozinho && !form ? `<span class="f-sozinho">O NIOGEN faz sozinho: ${esc(sozinho)}</span>` : ''}
        ${atalhos(v)}`;
    return `${faixaConv}${quadroPasso('venda', NIVEL_CLS[nivel] || 'dim', NIVEL_ROT[nivel] || 'PRÓXIMO PASSO', texto, corpo, !!form)}${feito}`;
  }
  let formAtivoPadrao = null;

  function atalhos(v) {
    const bo = ehBO();
    const cv = d.convInfo;
    const temCw = cv && cv.chatwoot_conversation_id;
    const dono = temCw ? donoConversa(cv).tipo : null;
    const b = [];
    if (bo && !d.pend && NG.etapaDe(v).n <= 4) b.push('<button type="button" class="btn btn-ghost btn-sm" data-f="pend-abrir" title="A venda sai da sua vez até a data de revisão; a cadência da Mari pausa">⏸ Pendência</button>');
    if (bo && temCw && (dono === 'pessoa' || dono === 'time')) b.push('<button type="button" class="btn btn-ghost btn-sm" data-momento="devolver_mari" title="Tira a atribuição no Chatwoot e deixa nota: a Mari continua com o contexto">Devolver para a Mari</button>');
    if (bo && temCw && !cv.nao_contatar) b.push('<button type="button" class="btn btn-ghost btn-sm" data-momento="parar" title="Etiqueta nao-contatar, nota, resolve a conversa e para tudo">Cliente pediu para parar</button>');
    if (bo && NG.etapaDe(v).n >= 2 && NG.etapaDe(v).n <= 4) b.push('<button type="button" class="btn btn-ghost btn-sm" data-f="trocar-plano" title="Upsell ou troca feita no portal: o valor e a comissão se recalculam">Trocar plano</button>');
    b.push('<button type="button" class="btn btn-ghost btn-sm" data-f="saida-form">Saída…</button>');
    return b.length ? `<div class="f-atalhos">${b.join('')}</div>` : '';
  }

  function barraJornada(etapaAtual, datas = {}) {
    const passos = NG.JORNADA.map((e) => {
      const feito = etapaAtual > e.n || (etapaAtual === 5 && e.n === 5 && datas.fim);
      const atual = etapaAtual === e.n;
      return `<li class="${feito ? 'feito' : ''}${atual ? ' atual' : ''}"><i style="--c:${e.cor}"></i><span>${esc(e.nome)}${feito ? ' ✓' : ''}</span>${datas[e.n] ? `<small>${esc(NG.fmtData(datas[e.n]))}</small>` : ''}</li>`;
    }).join('');
    return `<div class="f-jornada"><span class="f-rot">JORNADA</span><ol>${passos}</ol></div>`;
  }

  const ck = (ok, txt) => `<span class="f-ck ${ok ? 'ok' : 'no'}"><b>${ok ? '✓' : '○'}</b> ${txt}</span>`;
  function janelaTxt(cv) {
    if (!cv || !cv.ultima_msg_lead_at) return 'fechada (o cliente não escreveu)';
    const h = 24 - (Date.now() - new Date(cv.ultima_msg_lead_at)) / 3600000;
    return h <= 1 ? 'fechada · só template' : `fecha em ${Math.floor(h - 1)} h`;
  }
  function quadrosStatus(v) {
    const j = d.jor || {};
    const etapa = j.etapa != null ? j.etapa : (NG.etapaDe(v).n || 0);
    const et = NG.JORNADA.find((e) => e.n === etapa);
    const cv = d.convInfo;
    const dono = donoConversa(cv);
    const pe = d.pend;
    const agTxt = v.instalacao_agendada_para ? `${NG.fmtDiaSemana(v.instalacao_agendada_para)} ${NG.fmtData(v.instalacao_agendada_para)} ${NG.janela(v.instalacao_agendada_para)}` : '';
    const nio = [
      ck(NG.portalViavel(v), `Viabilidade${v.nio_viab_resultado ? `: ${esc((NG.VIAB_NIO[v.nio_viab_resultado] || v.nio_viab_resultado).toLowerCase())}` : ''}`),
      ck(!!v.nio_pedido, `Pedido${v.nio_pedido ? `: ${esc(v.nio_pedido)}` : ''}`),
      ck(v.biometria_status === 'validada', `Biometria${v.biometria_status ? `: ${esc((NG.BIOMETRIA[v.biometria_status] || v.biometria_status).split(' (')[0])}` : ''}`),
      ck(!!v.nio_os, `OS${v.nio_os ? `: ${esc(v.nio_os)}` : ''}`),
      ck(!!v.instalado_em, v.instalado_em ? `Instalada ${esc(NG.fmtData(v.instalado_em))}` : `Instalação${agTxt ? `: ${esc(agTxt)}` : ''}`),
    ].join('');
    const cw = !cv || !cv.chatwoot_conversation_id ? '<span>Sem conversa no Chatwoot (venda de rua ou parceiro).</span>'
      : `<strong>${cv.chatwoot_status === 'resolved' ? 'Resolvida' : 'Aberta'}</strong>
         <span class="f-dono">${dono.html}</span>
         <span>${dono.tipo === 'mari' ? (cv.chatwoot_status === 'resolved' ? 'Mari calada até o cliente escrever' : 'Mari atendendo') : 'Mari calada (tem dono)'}</span>
         <span>Janela 24 h: ${esc(janelaTxt(cv))}</span>`;
    return `<div class="f-status">
      <div class="f-sb"><span class="f-rot">NIOGEN</span><strong style="color:${et ? et.cor : 'inherit'}">${esc(j.etapa_nome || NG.etapaDe(v).nome)}</strong>
        <span>${etapa >= 4 ? 'venda conta' : etapa === 0 ? 'fora da jornada' : 'ainda não é venda'}</span>
        <span class="f-dono">dono: ${cv && cv.chatwoot_conversation_id ? dono.html : `${ICO_PESSOA} ${esc(v.vendedor_nome || 'sem dono')}`}</span>
        <span>${pe ? `⏸ pendência: ${esc(pe.nome)} · revisar ${esc(pe.diaTxt)}` : 'sem pendência'}</span></div>
      <div class="f-sb"><span class="f-rot">NIO · PORTAL E INSTALAÇÃO</span>${nio}</div>
      <div class="f-sb"><span class="f-rot">CHATWOOT · CONVERSA</span>${cw}</div>
      <div class="f-sb"><span class="f-rot">CONTRATO</span>
        ${ck(v.trava_sem_produto_ativo !== false, 'não é cliente Nio')}${ck(v.trava_sem_cancelamento_30d !== false, 'sem cancelamento em 30 d')}${ck(v.trava_area !== false, 'dentro da área')}
        <span>Contatos hoje ${esc(d.lim.hoje)}/2 · mês ${esc(d.lim.mes)}/15</span></div>
    </div>`;
  }

  // 0096 (Ricardo, 09/11: "a ficha é muito confusa, não sabe pra onde olhar"): UM destaque (o próximo passo); o status vira
  // uma linha curta de chips; o resto fica em "Mais detalhes".
  const chip = (ok, txt, cls) => `<span class="f-chip ${cls || (ok ? 'ok' : 'no')}">${ok === true ? '✓' : ok === false ? '○' : ''} ${txt}</span>`;
  // 10/11: o checklist da Nio virou a régua (em cima) e o status da conversa foi para a linha do nome. Aqui fica:
  // COMISSÃO (admin/backoffice) · FATURAS (instalada) · ESTORNO (o que foi conferido) · pendência.
  function linhaStatus(v) {
    const travas = [v.trava_sem_produto_ativo === false && 'já é cliente Nio', v.trava_sem_cancelamento_30d === false && 'cancelou há < 30 d',
      v.trava_area === false && 'fora da área', v.trava_cobertura === false && 'sem cobertura no endereço'].filter(Boolean);
    return `<div class="f-linha-status">
      ${linhaComissao(v)}
      ${linhaFaturas(v)}
      ${linhaEstorno(travas, 'cliente Nio · cancelou < 30 d · área · viabilidade')}
      ${d.pend ? `<div class="f-st-g"><span class="f-rot">PENDÊNCIA</span><span class="f-chip espera">⏸ ${esc(d.pend.nome)} · ${esc(d.pend.diaTxt)}</span></div>` : ''}
    </div>`;
  }
  const botaoConversa = (n) => (d.conversaId ? `<button type="button" class="btn btn-sm f-bt-conv" data-f="conversa">💬 ${convAberta && !hostConversa ? 'Fechar a conversa' : 'Conversa'}${n != null ? ` · ${n}` : ''}</button>` : '');
  // 0096: a conversa vira link no começo da linha do nome — "💬 Conversa · #32 | cidade · plano · origem".
  const linkConversa = () => {
    if (!d.conversaId) return '';
    const cw = d.convInfo && d.convInfo.chatwoot_conversation_id;
    const rot = convAberta && !hostConversa ? 'Fechar a conversa' : 'Conversa';
    return `<button type="button" class="f-link-conv" data-f="conversa" title="${convAberta && !hostConversa ? 'Fechar a conversa' : 'Abrir a conversa'}${d.nMsgs != null ? ` · ${d.nMsgs} mensagens` : ''}">💬 ${rot}${cw ? ` · #${esc(cw)}` : ''}</button>`;
  };

  // Lembretes automáticos da etapa: o que já saiu (✓), o próximo com horário, parada quando há dono, Pausar = pendência.
  function lembretes(v) {
    const etapa = d.jor ? d.jor.etapa : (NG.etapaDe(v).n || 0);
    const cv = d.convInfo;
    const comDono = cv && ['pessoa', 'time'].includes(donoConversa(cv).tipo);
    const k = d.cad && d.cad.k;
    const env = (d.cad && d.cad.enviados) || {};
    let nome = '', passos = [], obs = '';
    const prox = k && k.proximo_passo ? { cod: k.proximo_passo, em: k.proximo_em, bloqueio: k.bloqueio } : null;
    const PASSO_ROT = { P1: '1º contato', F1: '+1 h', F2: '+4 h', D3: 'D3', D7: 'D7', D15: 'D15', L15: '15 min', BIO1: 'D+1 do pedido', BIO3: 'Ligar (D+3)', INSTALACAO: 'Confirmação', VESPERA: 'Véspera' };
    if (v.status === 'saida') { nome = 'Lembretes automáticos'; obs = 'Nenhum — fora da jornada.'; }
    else if (d.pend) { nome = 'Lembretes automáticos'; obs = `Pausados pela pendência até ${d.pend.diaTxt}.`; }
    else if (etapa <= 2) {
      nome = 'Cadência do lead';
      passos = ['24 h', 'D3', 'Ligação', 'D7', 'D15'].map((x) => ({ rot: x }));
      if (comDono) obs = 'Parada: a conversa está com uma pessoa. Volta se devolver para a Mari.';
      else if (cv && cv.chatwoot_status === 'resolved') obs = 'Parada: conversa resolvida. Volta se o cliente escrever.';
    } else if (etapa === 3) {
      nome = 'Lembretes da biometria';
      passos = [['BIO1', 'D+1 do pedido'], ['BIO3', 'Ligar (D+3)']].map(([c, r]) => ({ cod: c, rot: r }));
      if (v.biometria_status === 'validada') obs = 'Encerrados: biometria validada.';
    } else if (etapa === 4) {
      nome = 'Lembretes da instalação';
      passos = [['INSTALACAO', 'Confirmação'], ['VESPERA', 'Véspera']].map(([c, r]) => ({ cod: c, rot: r }));
    } else {
      nome = 'Régua de pagamento';
      passos = ['D−2', 'D0', 'D+5', 'Ligação'].map((x) => ({ rot: x }));
      obs = v.forma_pagamento === 'cartao' ? 'Não se aplica: no cartão a cobrança é automática.' : 'Começa com a 1ª fatura (o extrato da Nio ainda não chega no NIOGEN).';
    }
    const trilha = passos.length ? `<div class="f-cad">${passos.map((p, i) => {
      const saiu = p.cod && env[p.cod];
      const proxEste = prox && p.cod && prox.cod === p.cod;
      return `${i ? '<i class="f-cad-s">›</i>' : ''}<span class="f-cad-p ${saiu ? 'ok' : proxEste ? 'cur' : ''}" title="${esc(saiu ? `enviada ${NG.fmtDataHora(saiu.em)}` : proxEste && prox.em ? `próxima ${NG.fmtDataHora(prox.em)}` : '')}">${saiu ? '✓ ' : ''}${esc(p.rot)}</span>`;
    }).join('')}</div>` : '';
    const proxTxt = prox && !comDono && !d.pend && v.status !== 'saida' && prox.em
      ? `<span>Próximo: <b>${esc(PASSO_ROT[prox.cod] || prox.cod)} · ${esc(NG.fmtDiaSemana(prox.em))} ${esc(NG.fmtDataHora(prox.em))}</b>${prox.bloqueio && prox.bloqueio !== 'aguardando' ? ` · ${esc(prox.bloqueio)}` : ''}</span>` : '';
    const pausar = ehBO() && v.status !== 'saida' && !d.pend ? '<button type="button" class="btn btn-sm" data-f="pend-abrir" title="Pausar = abrir uma pendência com data de revisão (a cadência para até lá)">Pausar</button>' : '';
    return `<div class="f-lembretes"><div class="f-lb-cab"><span class="f-rot">LEMBRETES AUTOMÁTICOS · ${esc(nome.toUpperCase())}</span>${pausar}</div>${trilha}${proxTxt}${obs ? `<span class="apagado">${esc(obs)}</span>` : ''}</div>`;
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
          `portal: ${v.nio_viab_resultado ? (NG.VIAB_NIO[v.nio_viab_resultado] || v.nio_viab_resultado).toLowerCase() : 'não consultado'}`,
          NG.portalViavel(v) ? null : `DFV ${dfvRot.replace(/^DFV:? ?/, '')}`].filter(Boolean).join(' · '),
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
          <span class="nota-campo">Plano e forma de pagamento saem da tabela vigente. Upsell ou troca no portal: use <b>Trocar plano ou pagamento</b> (backoffice) — o valor e a comissão se recalculam.</span>`,
        rotuloEditar: 'Trocar plano ou pagamento',
        editar: ehBO() && v.status !== 'saida' ? () => {
          const atual = (d.planos || []).find((x) => x.id === v.plano_id) || {};
          const opcoes = (d.planos || []).filter((x) => (!atual.cluster || x.cluster === atual.cluster) && (!atual.portfolio || x.portfolio === atual.portfolio));
          const preco = (x) => `${m(x.preco)} boleto${x.preco_cartao ? ` · ${m(x.preco_cartao)} cartão` : ''}`;
          return `<form class="f-formulario" data-form="ed_plano" novalidate>
            <label class="campo">Plano (mesma faixa de preço da cidade)<select name="plano">${opcoes.map((x) => `<option value="${esc(x.id)}"${x.id === v.plano_id ? ' selected' : ''}>${esc(x.nome)} — ${esc(preco(x))}</option>`).join('')}</select></label>
            <label class="campo">Forma de pagamento<select name="forma">${Object.entries(FORMAS).map(([k, tx]) => `<option value="${k}"${k === v.forma_pagamento ? ' selected' : ''}>${esc(tx)}</option>`).join('')}</select></label>
            <span class="nota-campo">O valor sai da tabela: o preço do cartão só vale com cartão. Prometer o preço do cartão a quem paga no boleto é desconto fora da tabela (contrato).</span>
            ${acoesForm('Trocar')}</form>`;
        } : null,
      },
      {
        id: 'pedido', titulo: 'Pedido, biometria e OS',
        resumo: [v.nio_pedido ? `Pedido #${v.nio_pedido}${v.nio_os ? ` · OS ${v.nio_os}` : ' · OS depois da biometria'}` : 'sem pedido ainda',
          v.biometria_status === 'pendente' && v.biometria_link_enviado_em
            ? `pedido aberto · link enviado pela Nio ${NG.fmtDataHora(v.biometria_link_enviado_em)}`
            : `biometria ${NG.BIOMETRIA[v.biometria_status] || NG.BIOMETRIA.nao_enviada}`,
          v.credito_resultado ? `crédito ${NG.CREDITO[v.credito_resultado]}` : null].filter(Boolean).join(' · '),
        corpo: () => `${linha('Nº do pedido (portal)', `<span class="mono">${esc(v.nio_pedido || '—')}</span>`)}
          ${linha('Nº da OS (venda)', `<span class="mono">${esc(v.nio_os || '—')}</span>${v.nio_os_em ? ' · ' + esc(NG.fmtDataHora(v.nio_os_em)) : ''}`)}
          ${linha('Contrato Nio', `<span class="mono">${esc(v.nio_contrato || '—')}</span>`)}
          ${linha('Interesse no portal', `<span class="mono">${esc(v.nio_viab_interesse_id || '—')}</span>`)}
          ${linha('Análise de crédito', esc(v.credito_resultado ? `${NG.CREDITO[v.credito_resultado]}${v.credito_em ? ' · ' + NG.fmtDataHora(v.credito_em) : ''}` : '—'))}
          ${linha('Biometria (link da Nio)', esc(`${NG.BIOMETRIA[v.biometria_status] || NG.BIOMETRIA.nao_enviada}${v.biometria_link_enviado_em ? ' · link enviado pela Nio ' + NG.fmtDataHora(v.biometria_link_enviado_em) : ''}${v.biometria_validada_em ? ' · validada ' + NG.fmtDataHora(v.biometria_validada_em) : ''}`))}
          ${avisosMari(['BIO1', 'BIO3'])}
          ${linha('Venda (OS aberta) em', esc(v.vendido_em ? NG.fmtDataHora(v.vendido_em) : '— ainda não é venda'))}
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
          <label class="campo">Nº da OS<input type="text" name="os" value="${esc(v.nio_os || '')}" autocomplete="off"></label>
          <label class="campo">Contrato Nio<input type="text" name="contrato" value="${esc(v.nio_contrato || '')}"></label>
          <label class="campo">Interesse no portal<input type="text" name="interesse" value="${esc(v.nio_viab_interesse_id || '')}" autocomplete="off"></label>
          <label class="campo">Análise de crédito<select name="credito">${NG.opcoes(NG.CREDITO, v.credito_resultado)}</select></label>
          <label class="campo">Biometria (link)<select name="biometria">${optBiometria(v.biometria_status)}</select></label>
          <label class="campo">Vendedor<select name="vendedor"><option value="">—</option>${vendedores.map((u) => `<option value="${u.id}" ${u.id === v.vendedor_id ? 'selected' : ''}>${esc(u.nome)}</option>`).join('')}</select></label></div>
          <label class="campo">Link da biometria<input type="url" name="link" value="${esc(v.biometria_link || '')}" placeholder="https://…" autocomplete="off"></label>
          <span class="nota-campo">A etapa só anda pelo botão do próximo passo. Venda = pedido + biometria validada + OS aberta + viabilidade do portal (o banco confere); o agendamento vem depois.</span>
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
    if (d.soConversa) { renderConversa(); return; }
    const v = d.v;
    const pr = NG.proximoPasso(v, (d.contatos[0] || {}).em);
    if (!abertos) abertos = new Set();   // 0089: tudo recolhido embaixo; abre o que o operador pedir
    if (edicao) { abertos.add(edicao); detalhes = true; }
    if (formAtivo && (FORMS_NO_CARTAO.includes(formAtivo) || formAtivo.startsWith('conf_'))) detalhes = true;
    const corpoAntes = raiz.querySelector('.f-corpo');
    const rolagem = corpoAntes ? corpoAntes.scrollTop : 0;
    if (modo === 'gaveta') document.title = `${v.cliente_nome} · ${document.title.split(' · ').pop()}`;
    else if (modo === 'pagina') document.title = `${v.cliente_nome} · NIOGEN`;
    const etapa = d.jor ? d.jor.etapa : (NG.etapaDe(v).n || 0);
    const datas = { 2: v.criado_em, 3: v.nio_pedido_em || v.biometria_link_enviado_em, 4: v.vendido_em, 5: v.instalado_em, fim: !!v.docs_entregues_em };
    const vivo = cvComp && convAberta ? raiz.querySelector('.f-conv-host > .cvp-raiz') : null;   // a conversa aberta não perde o rascunho
    const focoAntes = document.activeElement;

    raiz.innerHTML = `<div class="ficha f-${modo}${largo ? ' f-largo' : ''}${convAberta && d.conversaId && !hostConversa ? ' conv-on' : ''}">
      ${painelConversa()}
      ${cabecalho(v)}
      <div class="f-corpo"><div class="f-col-a">
        ${etapa === 0 ? `<div class="f-saida-linha">Saída · ${esc(v.motivo_saida || 'sem motivo')}${v.interesse_futuro_em ? ` · volta ${esc(NG.fmtDiaISO(v.interesse_futuro_em))}` : ''}</div>` : ''}
        ${regua(passosVenda(v))}
        ${faixaProximo(v, pr)}
        ${formAtivo === 'saida' || formAtivo === 'pend_abrir' ? `<div class="f-form-solto">${FORMS[formAtivo](v)}</div>` : ''}
        ${v.status === 'saida' ? '' : NG.selosFicha(d.avisos, { ignorar: v.id })}
        ${linhaStatus(v)}
        </div><div class="f-col-b">
        ${cartaoPendencia(v)}
        <button type="button" class="f-detalhes-cab" data-f="detalhes" aria-expanded="${detalhes}"><b>${detalhes ? '▾' : '▸'} 📋 Dados do cliente e da venda</b><span>cliente, endereço, plano, dados para o portal, viabilidade, pedido, instalação, comissão, lembretes, histórico</span></button>
        <div class="f-detalhes"${detalhes ? '' : ' hidden'}>
        ${detalhes ? `${lembretes(v)}
        ${cartaoViabilidade(v)}
        ${cartaoPortal(v)}
        ${cartaoConferencia(v)}
        ${blocos(v).map((b) => {
          const aberto = abertos.has(b.id);
          const editando = edicao === b.id && b.editar;
          return `<section class="f-bloco${aberto ? ' aberto' : ''}" data-bloco="${b.id}">
            <button type="button" class="f-bloco-cab" data-f="bloco" aria-expanded="${aberto}"><b>${esc(b.titulo)}</b><span>${esc(b.resumo)}</span></button>
            <div class="f-bloco-corpo">
              ${editando ? b.editar() : b.corpo()}
              ${!editando && b.editar ? `<div class="f-bloco-pe"><button type="button" class="btn btn-sm" data-f="editar">${esc(b.rotuloEditar || 'Editar')}</button></div>` : ''}
            </div>
          </section>`;
        }).join('')}` : ''}
        </div>
      </div></div>
    </div>`;
    const corpo = raiz.querySelector('.f-corpo');
    if (corpo && modo !== 'pagina') corpo.scrollTop = rolagem;
    reporConversa(vivo, focoAntes);
    ligarDfvSeEditando();
    const f = raiz.querySelector('[data-form] [autofocus]');
    if (f && formAtivo) f.focus({ preventScroll: true });
  }

  // ---------- ficha de CONVERSA (etapa 1: conversa sem venda) ----------
  async function carregarConversa(cid) {
    const [rc, rj, rq, rk] = await Promise.all([
      NG.sb.from('mari_conversas').select('id, venda_id, telefone, cidade, origem, nome_contato, dados, plano_escolhido, chatwoot_conversation_id, chatwoot_status, chatwoot_agente, chatwoot_time, chatwoot_etiquetas, humano_atribuido, nao_contatar, ultima_msg_lead_at, nio_viab_resultado, status, handoff_motivo').eq('id', cid).maybeSingle(),
      NG.sb.from('v_jornada').select('*').eq('conversa_id', cid).maybeSingle(),
      NG.sb.from('v_mari_quadro').select('coluna, itens, itens_total, itens_validados, faltam, contatos_hoje, contatos_mes, plano_nome, trava_cliente_nio, trava_endereco_nio, trava_viabilidade').eq('id', cid).maybeSingle(),
      NG.sb.from('v_mari_cadencia').select('*').eq('conversa_id', cid).maybeSingle(),
    ]);
    if (rc.error || !rc.data) return { erro: rc.error ? NG.msgErro(rc.error) : 'Conversa não encontrada (ou sem permissão).' };
    if (rc.data.venda_id) return { venda: rc.data.venda_id };
    const [rn, rt, rb] = await Promise.all([
      NG.sb.from('mari_turnos').select('id', { count: 'exact', head: true }).eq('conversa_id', cid).in('papel', ['lead', 'mari', 'humano']),
      NG.sb.from('mari_turnos').select('texto, tags, created_at').eq('conversa_id', cid).eq('papel', 'mari').not('tags->>cadencia', 'is', null).order('created_at'),
      NG.sb.from('chatwoot_acoes').select('id, payload, erro, criada_em').eq('conversa_id', cid).eq('status', 'bloqueada').order('criada_em', { ascending: false }).limit(1),
    ]);
    const c = rc.data;
    return {
      soConversa: true, conv: { ...c, nome: (c.dados && c.dados.nome) || c.nome_contato || 'Contato' },
      jor: rj.error ? null : rj.data, q: rq.error ? {} : (rq.data || {}),
      cad: { k: rk.error ? null : rk.data, enviados: NG.cadEnviados(rt.data) },
      conversaId: c.id, convInfo: c, nMsgs: rn.count, bloqueada: ((rb && rb.data) || [])[0] || null,
      chatwoot: NG.linkChatwoot(c.chatwoot_conversation_id),
    };
  }
  // 0096 (Ricardo: "não estou vendo opção para ver os demais dados do cliente"): os valores que a Mari coletou, com copiar.
  function dadosConversa(c) {
    const x = (c.dados && typeof c.dados === 'object') ? c.dados : {};
    const rua = x.rua_confirmada || x.rua_informada;
    const L = [
      ['Nome', x.nome || c.nome_contato], ['Telefone', c.telefone || x.telefone], ['CPF', x.cpf], ['E-mail', x.email],
      ['CEP', x.cep_origem], ['Endereço', rua], ['Complemento', x.complemento_ok === true ? 'sem complemento' : typeof x.complemento_ok === 'string' ? x.complemento_ok : null],
      ['Referência', x.referencia], ['Cidade', c.cidade], ['Operadora atual', x.operadora_atual], ['Plano escolhido', c.plano_escolhido],
    ].filter(([, val]) => val != null && String(val).trim() !== '');
    return `<div class="f-lembretes f-dados-conv"><div class="f-lb-cab"><span class="f-rot">DADOS DO CLIENTE (COLETADOS PELA MARI)</span></div>
      ${L.length ? `<dl class="f-dl">${L.map(([k, val]) => `<dt>${esc(k)}</dt><dd><span>${esc(String(val))}</span><button type="button" class="f-copia" data-copiar="${esc(String(val))}" title="Copiar ${esc(k)}">⧉</button></dd>`).join('')}</dl>`
        : '<span class="apagado">A Mari ainda não coletou dados deste cliente.</span>'}</div>`;
  }
  function renderConversa() {
    const vivo = cvComp && convAberta ? raiz.querySelector('.f-conv-host > .cvp-raiz') : null;
    const focoAntes = document.activeElement;
    const c = d.conv;
    const j = d.jor || {};
    const q = d.q || {};
    const dono = donoConversa(c);
    const nivel = j.nivel || 'espera';
    const bo = ehBO();
    const bts = [];
    let sozinho = '';
    if (bo && j.botao === 'manual' && d.bloqueada) {
      bts.push('<button type="button" class="btn" data-f="manual-copiar">Copiar o texto</button>', '<button type="button" class="btn btn-acc" data-f="manual-mandei">Já mandei</button>');
      sozinho = SOZINHO.manual;
    } else if (bo && dono.tipo === 'mari' && !c.nao_contatar) {
      bts.push('<button type="button" class="btn btn-acc" data-momento="assumir">Assumir</button>');
      sozinho = SOZINHO.assumir;
    } else if (bo && (dono.tipo === 'pessoa' || dono.tipo === 'time')) {
      bts.push('<button type="button" class="btn btn-acc" data-f="conversa">Abrir a conversa e responder</button>');
      sozinho = SOZINHO.responder;
    }
    const at = [];
    if (bo && (dono.tipo === 'pessoa' || dono.tipo === 'time')) at.push('<button type="button" class="btn btn-ghost btn-sm" data-momento="devolver_mari">Devolver para a Mari</button>');
    if (bo && !c.nao_contatar && c.chatwoot_conversation_id) at.push('<button type="button" class="btn btn-ghost btn-sm" data-momento="parar">Cliente pediu para parar</button>');
    at.push(`<a class="btn btn-ghost btn-sm" href="mari.html?conversa=${esc(c.id)}">Ver na tela Mari</a>`);
    const itens = Array.isArray(q.itens) ? q.itens.filter((x) => x.obrigatorio !== false) : [];
    const ESTADO = { validado: 'ok', coletado: 'meio', vazio: 'no' };
    const feito = feitoUltimo ? `<div class="f-feito${feitoUltimo.aviso ? ' warn' : ''}" role="status">${esc(feitoUltimo.resumo)}${feitoUltimo.aviso ? `<span>${esc(feitoUltimo.aviso)}</span>` : ''}</div>` : '';
    const k = d.cad.k;
    const viabC = c.nio_viab_resultado;
    const passosConv = [
      { nome: 'Viabilidade', s: viabC === 'viavel' ? 'ok' : ['sem_viabilidade', 'nao_encontrado', 'posse'].includes(viabC) ? 'wa' : 'no', d: viabC ? (viabC === 'viavel' ? 'portal · ok' : (NG.VIAB_NIO[viabC] || viabC).toLowerCase()) : '' },
      { nome: 'Pedido', s: 'no', d: '' }, { nome: 'Biometria', s: 'no', d: '' }, { nome: 'OS', s: 'no', d: '' }, { nome: 'Instalação', s: 'no', d: '' },
    ];
    const travasC = [q.trava_cliente_nio === 'bloqueia' && 'já é cliente Nio', q.trava_endereco_nio === 'bloqueia' && 'endereço com Nio', q.trava_viabilidade === 'bloqueia' && 'sem viabilidade'].filter(Boolean);
    const corpoPasso = `${dono.tipo === 'mari' && nivel !== 'agora' ? '<span class="f-nota">Não precisa fazer nada. Se quiser entrar, assuma antes de escrever.</span>' : ''}
          ${bts.length ? `<div class="f-prox-bts">${bts.join('')}</div>` : ''}
          ${sozinho ? `<span class="f-sozinho">O NIOGEN faz sozinho: ${esc(sozinho)}</span>` : ''}
          <div class="f-atalhos">${at.join('')}</div>`;
    raiz.innerHTML = `<div class="ficha f-${modo}${largo ? ' f-largo' : ''}${convAberta && !hostConversa ? ' conv-on' : ''}">
      ${painelConversa()}
      <header class="f-cab"><div class="f-linha1"><div class="f-nome"><h2>${esc(c.nome)}</h2>${linhaPlano(q.plano_nome || c.plano_escolhido, null, null)}</div><div class="f-ctl">${botaoVoltar()}${modo !== 'pagina' ? '<button type="button" class="g-fechar" data-f="fechar" aria-label="Fechar a ficha">×</button>' : ''}</div></div>
        <div class="f-local">${linkConversa()}${chipsConversa(c)}<span class="f-local-txt">${esc([c.cidade, NG.ORIGENS[c.origem] || c.origem].filter(Boolean).join(' · ') || '—')}</span></div></header>
      <div class="f-corpo"><div class="f-col-a">
        ${regua(passosConv)}
        ${quadroPasso('conversa', NIVEL_CLS[nivel] || 'dim', NIVEL_ROT[nivel] || 'PRÓXIMO PASSO', j.o_que_fazer || 'Mari atendendo', corpoPasso)}${feito}
        <div class="f-linha-status">
          <div class="f-st-g"><span class="f-rot">MARI</span><span class="f-chip">dados ${esc(q.itens_validados ?? 0)}/${esc(q.itens_total ?? 0)}</span></div>
          ${linhaEstorno(travasC, 'cliente Nio · cancelou < 30 d · endereço · área · viabilidade')}
        </div>
        </div><div class="f-col-b">
        <button type="button" class="f-detalhes-cab" data-f="detalhes" aria-expanded="${detalhes}"><b>${detalhes ? '▾' : '▸'} 📋 Dados do cliente</b><span>o que a Mari coletou (nome, CPF, endereço, contato) e os lembretes</span></button>
        <div class="f-detalhes"${detalhes ? '' : ' hidden'}>
        ${detalhes ? `${dadosConversa(c)}<div class="f-lembretes"><div class="f-lb-cab"><span class="f-rot">LEMBRETES AUTOMÁTICOS · CADÊNCIA DO LEAD</span></div>
          <div class="f-cad">${['24 h', 'D3', 'Ligação', 'D7', 'D15'].map((x, i) => `${i ? '<i class="f-cad-s">›</i>' : ''}<span class="f-cad-p">${esc(x)}</span>`).join('')}</div>
          ${dono.tipo === 'pessoa' || dono.tipo === 'time' ? '<span class="apagado">Parada: a conversa está com uma pessoa. Volta se devolver para a Mari.</span>'
            : k && k.proximo_passo && k.proximo_em ? `<span>Próximo: <b>${esc(k.proximo_passo)} · ${esc(NG.fmtDiaSemana(k.proximo_em))} ${esc(NG.fmtDataHora(k.proximo_em))}</b>${k.bloqueio && k.bloqueio !== 'aguardando' ? ` · ${esc(k.bloqueio)}` : ''}</span>` : '<span class="apagado">Nenhum lembrete marcado agora.</span>'}</div>
        ${itens.length ? `<div class="f-lembretes"><div class="f-lb-cab"><span class="f-rot">DADOS QUE A MARI COLETOU</span></div><div class="f-itens">${itens.map((x) => `<span class="f-item ${ESTADO[x.estado] || 'no'}">${x.estado === 'validado' ? '✓' : x.estado === 'vazio' ? '○' : '◐'} ${esc(x.nome)}</span>`).join('')}</div></div>` : ''}` : ''}
        </div>
      </div></div>
    </div>`;
    reporConversa(vivo, focoAntes);
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

  // quieto (10/11): recarga automática (eco da conversa, refresh de 60 s da Minha vez) — só redesenha se o dado mudou e nunca
  // por cima de um formulário aberto (não apaga o que a pessoa está digitando).
  let sigDados = '';
  async function recarregar(op) {
    if (!idAtual) return;
    const quieto = !!(op && op.quieto);
    if (quieto && (formAtivo || edicao)) return;
    const id = idAtual;
    const ehConv = String(id).startsWith('c:');
    const r = ehConv ? await carregarConversa(id.slice(2)) : await carregar(id);
    if (id !== idAtual) return;   // trocou de venda no meio
    let sig = '';
    try { sig = JSON.stringify(r); } catch (e) { sig = String(Date.now()); }
    if (quieto && (sig === sigDados || formAtivo || edicao)) return;
    sigDados = sig;
    if (r.venda) { idAtual = r.venda; abrir(r.venda); return; }   // a conversa virou venda: abre a ficha da venda
    if (r.erro) {
      d = null;
      raiz.innerHTML = `<div class="ficha f-${modo}"><header class="f-cab"><div class="f-linha1"><h2>${ehConv ? 'Conversa' : 'Venda'}</h2>${modo !== 'pagina' ? '<button type="button" class="g-fechar" data-f="fechar" aria-label="Fechar">×</button>' : ''}</div></header>
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
      const cp = ev.target.closest('[data-copiar]');
      if (cp) { copiar(cp.dataset.copiar, 'Copiado.'); return; }
      const mo = ev.target.closest('[data-momento]');
      if (mo && d) {
        const qual = mo.dataset.momento;
        const res = mo.dataset.r || null;
        if (qual === 'parar' && !window.confirm('O cliente pediu para parar?\n\nA conversa ganha a etiqueta nao-contatar, uma nota, é resolvida e ninguém mais chama esse cliente.')) return;
        if (res === 'negado' && !window.confirm('Crédito negado no CPF do cliente?\n\nO sistema manda ao cliente o pedido de outro CPF e abre a pendência "aguardando outro CPF".')) return;
        mo.disabled = true;
        const r = d.soConversa ? await rodarMomentoConversa(qual) : await rodarMomento(qual, res ? { resultado: res } : {});
        if (!r && mo.isConnected) mo.disabled = false;
        return;
      }
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
      if (acao === 'fechar') { if (modo === 'lado') fecharLado(); else NG.gaveta.fechar(); return; }
      if (acao === 'passo') {   // 10/11: próximo passo recolhido ▸ / expandido ▾
        const k = b.dataset.k;
        if (passoAberto.has(k)) { passoAberto.delete(k); if (formAtivo && !formAtivo.startsWith('conf_') && !FORMS_NO_CARTAO.includes(formAtivo) && formAtivo !== 'saida' && formAtivo !== 'pend_abrir') formAtivo = null; } else passoAberto.add(k);
        render();
        return;
      }
      if (acao === 'voltar-lista') { if (voltarFn) voltarFn(); return; }
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
        if (convAberta && !hostConversa) { convAberta = false; render(); } else abrirConversa();
        return;
      }
      if (acao === 'detalhes') { detalhes = !detalhes; render(); return; }
      if (acao === 'trocar-plano') {
        detalhes = true; edicao = 'plano'; formAtivo = null; render();
        const bl = raiz.querySelector('[data-bloco="plano"]');
        if (bl) bl.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
        return;
      }
      if (acao === 'pend-viab') { pendPreset = 'viabilidade_confirmar'; formAtivo = 'pend_abrir'; render(); return; }
      if (acao === 'saida-form') { formAtivo = formAtivo === 'saida' ? null : 'saida'; render(); return; }
      if (acao === 'mover') { await mover(b.dataset.st); return; }
      if (acao === 'viab-rapido') {
        if (b.dataset.r !== 'viavel' && !window.confirm('O portal respondeu sem viabilidade?\n\nAntes de encerrar, tente variações de CEP, rua e número. Se só a Nio pode confirmar, abra a pendência.')) return;
        b.disabled = true;
        const r = await rodarMomento('viabilidade', { resultado: b.dataset.r });
        if (!r && b.isConnected) b.disabled = false;
        return;
      }
      if (acao === 'ir-conferencia') { detalhes = true; render(); const c = raiz.querySelector('[data-conf-card], .f-conf'); if (c) c.scrollIntoView({ block: 'nearest', behavior: 'smooth' }); return; }
      if (acao === 'manual-copiar') {
        const txt = d.bloqueada && d.bloqueada.payload ? d.bloqueada.payload.content : '';
        try { await navigator.clipboard.writeText(txt); NG.toast('Texto copiado — cole na conversa do Chatwoot', 'ok'); } catch (e) { NG.toast('Não deu para copiar: abra os detalhes e copie à mão.', 'bad'); }
        return;
      }
      if (acao === 'manual-mandei') {
        if (!d.bloqueada) return;
        b.disabled = true;
        const { error } = await NG.sb.rpc('backoffice_acao_manual', { p_id: d.bloqueada.id, p_enviei: true });
        if (error) { NG.toast(NG.msgErro(error), 'bad'); b.disabled = false; return; }
        feitoUltimo = { resumo: '✓ registrado: mensagem enviada à mão (conta no limite do contrato)' };
        await recarregar();
        avisarOuvintes({ resumo: feitoUltimo.resumo });
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
        if (formAtivo !== 'pend_abrir') detalhes = true;
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
    if (['1_vendido', '2_aguardando_instalacao'].includes(destino) && v.status === '0_qualificado') { formAtivo = 'os'; render(); return; }
    if (destino === '2_aguardando_instalacao') { formAtivo = 'mover_aguardando'; render(); return; }
    if (destino === 'saida') { formAtivo = 'saida'; render(); return; }
    formAtivo = null;
    await gravar({ status: destino }, `${NG.primeiroNome(v.cliente_nome)} → ${STATUS_MAP[destino].curto}`);
  }

  document.addEventListener('click', (ev) => {
    // Links #venda=<id> / #conversa=<id> (Quadro, Painel, Mari…): abrem a ficha sem recarregar. Ctrl/⌘/meio = nova aba.
    const a = ev.target.closest('a[href^="#venda="], a[href^="#conversa="]');
    if (a && !ev.ctrlKey && !ev.metaKey && !ev.shiftKey && ev.button === 0) {
      const h = a.getAttribute('href');
      const m = h.match(HASH);
      const mc = h.match(HASH_C);
      if (m) { ev.preventDefault(); abrir(m[1]); } else if (mc) { ev.preventDefault(); abrirConversaFicha(mc[1]); }
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
  const idDoHash = () => { const m = location.hash.match(HASH); if (m) return m[1]; const c = location.hash.match(HASH_C); return c ? `c:${c[1]}` : null; };
  const hashDe = (id) => (String(id).startsWith('c:') ? `#conversa=${id.slice(2)}` : `#venda=${id}`);
  const semHash = () => `${location.pathname}${location.search}`;
  let tituloOriginal = document.title;

  const ouvintesFechar = [];
  function aoFecharGaveta() {
    idAtual = null;
    d = null;
    if (cvComp) { cvComp.destruir(); cvComp = null; }
    ouvintesFechar.forEach((f) => { try { f(); } catch (e) { /* */ } });
    document.title = tituloOriginal;
    if (idDoHash()) {
      if (empurrou) { empurrou = false; history.back(); } else history.replaceState(history.state, '', semHash());
    }
  }
  async function mostrar(id) {
    if (modo === 'lado') {
      if (idAtual !== id) { idAtual = id; d = null; abertos = null; edicao = null; formAtivo = null; convAberta = false; conv = null; feitoUltimo = null; detalhes = largo; passoAberto = new Set(); sigDados = '';
        raiz.innerHTML = '<div class="ficha f-lado"><div class="f-corpo"><div class="carregando">Carregando…</div></div></div>'; }
      ladoEl.hidden = false;
      document.body.classList.add('ficha-ao-lado');
      await recarregar();
      return;
    }
    garantirGaveta();
    if (idAtual !== id) {
      idAtual = id;
      d = null; abertos = null; edicao = null; formAtivo = null; convAberta = false; conv = null; feitoUltimo = null; detalhes = largo; passoAberto = new Set(); sigDados = '';
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
    if (modo === 'pagina') { location.href = String(id).startsWith('c:') ? `fila.html#conversa=${id.slice(2)}` : `venda.html?id=${id}`; return; }
    if (idDoHash() !== id) {
      if (idDoHash()) history.replaceState(null, '', `${semHash()}${hashDe(id)}`);   // troca de venda sem empilhar
      else { history.pushState({ ficha: id }, '', `${semHash()}${hashDe(id)}`); empurrou = true; }
    }
    mostrar(id);
  }
  const abrirConversaFicha = (cid) => abrir(`c:${cid}`);
  function fecharLado() {
    idAtual = null; d = null;
    if (cvComp) { cvComp.destruir(); cvComp = null; }
    if (ladoEl) { ladoEl.hidden = true; raiz.innerHTML = ''; }
    document.body.classList.remove('ficha-ao-lado');
    if (idDoHash()) { if (empurrou) { empurrou = false; history.back(); } else history.replaceState(history.state, '', semHash()); }
    ouvintesFechar.forEach((f) => { try { f(); } catch (e) { /* */ } });
  }
  function sincronizar() {
    if (modo === 'pagina') return;
    const id = idDoHash();
    if (id) { if (id !== idAtual) { empurrou = false; mostrar(id); } }
    else if (idAtual) { empurrou = false; if (modo === 'lado') fecharLado(); else NG.gaveta.fechar(); }
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

  // 0090: ficha AO LADO (Minha vez · Lista): a mesma ficha, sem gaveta, dentro de um elemento da tela.
  function lado(el) {
    modo = 'lado';
    ladoEl = el;
    raiz = el;
    ligar(raiz);
  }
  // Troca o modo (Minha vez: Lista = ao lado · Quadro = gaveta) sem recarregar a página.
  function usarGaveta() {
    if (modo !== 'lado') return;
    if (idAtual) fecharLado();
    modo = 'gaveta';
    raiz = gav ? gav.querySelector('.ficha-raiz') : null;
  }
  function usarLado() {
    if (!ladoEl || modo === 'lado') return;
    if (idAtual && gav && gav.classList.contains('aberta')) NG.gaveta.fechar();
    modo = 'lado';
    raiz = ladoEl;
  }

  window.NGFicha = {
    abrir,
    abrirConversa: abrirConversaFicha,
    lado, usarGaveta, usarLado,
    // A tela abre a conversa no lugar dela (Minha vez: no espaço da lista). fn({conversaId, nome, aoMudar}); null desliga.
    aoConversa(fn) { hostConversa = fn; },
    aoFechar(fn) { ouvintesFechar.push(fn); },
    recarregar: (op) => recarregar(op),
    // 10/11 (modo foco da Minha vez): fn = "← Lista" no cabeçalho (null tira) · largo(true) = ficha em 2 colunas, dados à direita.
    aoVoltar(fn) { voltarFn = fn; if (d) render(); },
    largo(on) { largo = !!on; if (largo) detalhes = true; if (d) render(); },
    get atual() { return idAtual; },
    pagina,
    // Ouvinte chamado depois de cada gravação (a tela recarrega a lista).
    aoMudar(fn) { ouvintes.push(fn); },
    // Chamar depois do login: abre a ficha se a URL já vier com #venda=<id>.
    iniciar() { if (idDoHash()) { empurrou = false; mostrar(idDoHash()); } },
    get conversaAtual() { return d ? d.conversaId : null; },
    get aberta() { return !!idAtual; },
  };
})();
