/* NIOGEN | docs/assets/ficha.js | 05/11/2026 00h30 — Claude Code, rodada noturna de layout
 * Ficha da venda: UM componente para a gaveta larga (Vendas, Instalações, Painel, Mari) e para a página cheia (venda.html?id=).
 * URL: #venda=<id> abre a ficha; o voltar do navegador fecha; link com o hash abre direto.
 * Ordem: cabeçalho fixo (nome, local, etapa, origem, vendedor, "Mover para…", menu ⋯) · faixa "Próximo passo" com o botão que
 * resolve o passo (o formulário abre DENTRO da ficha) · linha do tempo das etapas · blocos recolhíveis com resumo de uma linha.
 * Gravação: os mesmos updates de antes (vendas / contatos_cliente) com os mesmos campos; as travas são do banco (triggers)
 * e a mensagem do RAISE volta como toast. Nada de regra de negócio aqui.
 * 06/11 (prompt 25): cartão da CONFERÊNCIA DE QUALIDADE (só origem parceiro_pap), origem "Parceiro PAP · nome" e "Gerar lançamentos".
 * 10/11 (Pocket do Parceiro, 0115): no mesmo cartão, "Marcar venda indevida…" / "Desmarcar" (só admin; RPC parceiro_marcar_indevida).
 * 06/11 (prompt 27): cartão VIABILIDADE com o portal PAP na frente (Consultar no portal · Registrar resultado; DFV vira "pista")
 * e cartão DADOS PARA O PORTAL PAP (campos na ordem das etapas do Novo Pedido, copiar por campo e Copiar tudo; em
 * eventos_venda só o fato "dados copiados"). Os dois aparecem em Qualificado e em Saída.
 * 08/11 (0064): cartão PENDÊNCIA ("Em espera": abrir · adiar · encerrar por RPC, só admin/backoffice; atalho para a Saída sugerida;
 * histórico) logo abaixo do próximo passo; eventos tipo "pendencia" no histórico.
 * 09/11 (0082, fluxo único do backoffice): os botões do próximo passo chamam backoffice_momento — Assumir · Registrar viabilidade ·
 * Gravar o crédito (0111: sem número) · Biometria Validada/Risco/Negado · Agendar — e atalhos "Devolver para a Mari" e "Cliente pediu para parar".
 * O banco grava a venda e enfileira etiqueta/nota/mensagem/resolver no Chatwoot (n8n backoffice_chatwoot); a ficha mostra em uma
 * linha o que o sistema fez. Validada abre o agendamento na sequência.
 * 09/11 (0089/0090, prompt Prompt_ajustes_operacao_ficha_conversa_091126_1535 · ponto 3): de cima para baixo — nome · cidade ·
 * plano · origem · barra CONVERSA (abre a conversa: no espaço da lista no Live; à esquerda da ficha nas outras telas) ·
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
  let convEsperaFechado = false;   // 0103: o operador fechou o ⏸ Aguardar sugerido — não reabrir sozinho
  let planosCache = null;  // 0092: config_planos ativos (trocar plano / upsell)
  let linksCache = null;   // 0092: config_links (DFV, formulário de análise da Nio)
  let cicloCache;          // 11/11: config_regras.comissao_ciclo_regra (lida uma vez por página)
  let cvComp = null;       // 0090: NGConversa montado no painel da ficha
  let hostConversa = null; // 0090: a tela abre a conversa no lugar dela (Live)
  let ladoEl = null;       // 0090: ficha ao lado (Live · Lista), sem gaveta
  let leadCfgCache = null; // 13/11 (4a): config_lead (degraus, status e motivos de saída), lida uma vez por página
  let globalEl = null;     // 13/11 (4a): a ficha única em tela cheia fora da Live (um elemento só, por cima da tela)
  let liveOpts = null;     // opções da tela cheia da Live (posição na fila, navegar, concluir)
  let paginaVolta = null;  // venda.html: para onde o "Voltar" leva
  // A chave: a ficha única vale para todas as telas; a gaveta antiga volta por Configurações ou ?ficha=antiga (por navegador).
  try { const q = new URLSearchParams(location.search).get('ficha'); if (q === 'antiga' || q === 'nova') localStorage.setItem('niogen.ficha', q); } catch (e) { /* sem armazenamento */ }
  const fichaAntiga = () => { try { return localStorage.getItem('niogen.ficha') === 'antiga'; } catch (e) { return false; } };   // 13/11: a ficha única é o padrão; a gaveta antiga só com niogen.ficha = 'antiga'
  const leadCfg = () => (leadCfgCache ? Promise.resolve(leadCfgCache)
    : Promise.resolve(NG.sb.from('config_lead').select('tipo, codigo, nome, ordem, ajuda, volta').order('ordem')).then((r) => { if (!r.error) leadCfgCache = r.data || []; return leadCfgCache || []; }, () => []));
  const opcL = (q) => Promise.resolve(q).then((x) => (x.error ? null : (x.data || [])[0] || null), () => null);
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
    } else if (e.tipo === 'portal_status') {
      // 0105: leitura do Histórico de Pedidos do portal (extensão 0.4).
      titulo = `Portal: ${dt.de ? `${dt.de} → ` : ''}${dt.para || ''}`;
      cor = dt.para === 'NÃO VENDA' ? 'bad' : dt.para === 'SEM CONTATO COM O CLIENTE' ? 'warn' : '';
      texto = `${NG.fmtDataHora(e.criado_em)}${quem} · pedido ${esc(dt.pedido || '')}`;
    } else if (e.tipo === 'portal_pedido_casado') {
      titulo = `Pedido do portal casado com esta venda · nº ${dt.pedido || ''}`;
      texto = `${NG.fmtDataHora(e.criado_em)}${quem}${dt.pedido_na_venda && dt.pedido_na_venda !== dt.pedido ? ` · nº na venda: ${esc(dt.pedido_na_venda)}` : ''}`;
    } else if (e.tipo === 'biometria_ged360') {
      titulo = `Biometria (GED360): ${dt.para || ''}`;
      cor = /RISCO|EXPIRADO|REPROVADO/.test(dt.para || '') ? 'bad' : /APTO|APROVADO/.test(dt.para || '') ? '' : 'warn';
      texto = `${NG.fmtDataHora(e.criado_em)} · protocolo ${esc(dt.protocolo || '')}`;
    } else if (e.tipo === 'biometria_validada') {
      titulo = `Biometria validada · ${dt.origem === 'ged360' ? 'GED360' : dt.origem === 'portal' ? 'status do portal' : dt.origem || ''}`;
      texto = `${NG.fmtDataHora(e.criado_em)}${quem}`;
    } else if (e.tipo === 'instalada_portal') {
      titulo = 'Instalada · portal (Gross)';
      texto = `${NG.fmtDataHora(e.criado_em)}${quem}`;
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
  // 11/11 (Live lenta): eram ~8 esperas em fila (cada uma ~0,3 s de rede); agora são 2 rodadas em paralelo — a 1ª com tudo
  // o que só depende do id da venda, a 2ª com o que depende da conversa/da própria venda. A linha da jornada vem da carga
  // compartilhada (NG.jornadaLinha). fresco = depois de uma ação: descarta o cache antes.
  async function carregar(id, fresco) {
    if (fresco) NG.limparCache();
    const perfil = (NG.usuario || {}).perfil;
    const bo = ['admin', 'backoffice'].includes(perfil);
    const opc = (q) => Promise.resolve(q).then((x) => (x.error ? null : x.data), () => null);
    // O que depende da conversa (cadência, nº de mensagens, bloqueio, última fala). Se a jornada em memória já diz qual é a
    // conversa da venda, isso sai junto com a 1ª rodada; a 2ª só confere (e refaz se a conversa for outra).
    const daConversa = (cid) => Promise.all([
      // Prompt 28: avisos automáticos da Mari para a venda (BIO1 · BIO3 · INSTALACAO · VESPERA) — só admin/backoffice.
      Promise.all([
        NG.sb.rpc('mari_cadencia_avaliar', { p_conversa: cid }).maybeSingle(),   // 13/11: só esta conversa (60 ms; a view avalia todas)
        NG.sb.from('mari_turnos').select('texto, tags, created_at').eq('conversa_id', cid).eq('papel', 'mari')
          .not('tags->>cadencia', 'is', null).order('created_at'),
        NG.tplCadencia(),
      ]),
      NG.sb.from('mari_turnos').select('id', { count: 'exact', head: true }).eq('conversa_id', cid).in('papel', ['lead', 'mari', 'humano']),
      NG.sb.from('chatwoot_acoes').select('id, payload, erro, criada_em').eq('conversa_id', cid).eq('status', 'bloqueada').order('criada_em', { ascending: false }).limit(1),
      ultimaFalaTime(cid),   // 0103: sugestão do motivo quando o cliente só confirmou
    ]);
    const convPrev = bo ? ((NG.jornadaEspia({ venda: id }) || {}).conversa_id || null) : null;
    const pPrev = convPrev ? daConversa(convPrev).catch(() => null) : null;
    const [rv, re, rl, ra, rc, rk, ru, rx27, rph, rmot, rav, jo, rpl, rlk, andRow, cicloRow, teto, fnome, lead, din, lcfg] = await Promise.all([
      NG.sb.from('v_vendas').select('*').eq('id', id).maybeSingle(),
      NG.sb.from('eventos_venda').select('*').eq('venda_id', id).order('criado_em'),
      NG.sb.from('v_contatos_limite').select('*').eq('venda_id', id).maybeSingle(),
      NG.sb.from('venda_adicionais').select('qtd, comissao_prevista, config_adicionais(nome, preco)').eq('venda_id', id).order('id'),
      // Conversa da Mari que gerou a venda (a tabela só abre para admin/backoffice; para os outros vem vazia).
      ['admin', 'backoffice'].includes(perfil)
        ? NG.sb.from('mari_conversas').select('id, chatwoot_conversation_id, chatwoot_agente, chatwoot_time, chatwoot_status, chatwoot_etiquetas, humano_atribuido, nao_contatar, ultima_msg_lead_at, handoff_briefing, handoff_em, handoff_motivo, funil_etapa, funil_destino, funil_detalhe, funil_alerta, status, origem, created_at, cadencia_passo, cadencia_retorno_em, agendamento_retorno, chatwoot_resolvida, time_atribuido, venda_id, bio_lembrete_em, instalacao_avisada_para, instalacao_avisada_em').eq('venda_id', id).order('created_at', { ascending: false }).limit(1)
        : Promise.resolve({ data: [] }),
      NG.sb.from('contatos_cliente').select('id, canal, direcao, por, em, resumo, toque').eq('venda_id', id).order('em', { ascending: false }).limit(30),
      usuariosCache ? Promise.resolve(usuariosCache) : NG.carregarUsuarios(),
      // 0048 (prompt 27): v_funil congela v.* — quem registrou a viabilidade do portal e a referência vêm da tabela. Na mesma
      // leitura, a obs. interna e quem/quando aprovou a conferência (só usadas em venda de parceiro, por admin/backoffice).
      NG.sb.from('vendas').select('nio_viab_por, ponto_referencia, nio_os, nio_os_em, docs_dispensados_em, conferencia_obs, conferencia_em, conferencia_por, parceiro_indevida, parceiro_indevida_motivo, parceiro_indevida_em').eq('id', id).maybeSingle(),
      // 0064: pendências da venda (aberta + histórico) e a lista de motivos (config). 0076: avisos de ficha única (só aviso).
      NG.sb.from('venda_pendencias').select('*').eq('venda_id', id).order('aberta_em', { ascending: false }),
      motivosCache ? Promise.resolve({ data: motivosCache }) : NG.sb.from('config_motivos_pendencia').select('*').eq('ativo', true).order('ordem'),
      NG.sb.rpc('ficha_avisos', { p_venda: id }),
      NG.jornadaLinha({ venda: id }),   // 0090: etapa, próximo passo, precisa de ação
      planosCache ? Promise.resolve({ data: planosCache }) : NG.sb.from('config_planos').select('id, nome, nome_curto, preco, preco_cartao, cluster, portfolio, variante, forma_pagamento_permitida').eq('ativo', true).order('preco'),
      linksCache ? Promise.resolve({ data: linksCache }) : NG.sb.from('config_links').select('chave, url').in('chave', ['dfv_sudeste', 'nio_form_analise_viabilidade']),
      // 0105: andamento na Nio — status do portal PAP (extensão 0.4) e biometria do GED360 (robô n8n). Só admin/backoffice.
      bo ? opc(NG.sb.from('v_venda_andamento').select('*').eq('venda_id', id).maybeSingle()) : null,
      bo ? (cicloCache !== undefined ? cicloCache : opc(NG.sb.from('config_regras').select('valor').eq('chave', 'comissao_ciclo_regra').maybeSingle())) : null,
      NG.tetoContato(),   // 0102: nulo = sem teto (Ricardo, 10/11)
      NG.funilNomes(),    // 0147: nomes de etapa e destino (cache da página)
      // 13/11 (4a): as trilhas do topo — a escada (v_leads) e o dinheiro (v_dinheiro: só existe depois de instalar). Mesma rodada.
      opcL(NG.sb.from('v_leads').select('*').eq('venda_id', id).limit(1)),
      opcL(NG.sb.from('v_dinheiro').select('*').eq('venda_id', id).limit(1)),
      leadCfg(),
    ]);
    if (rv.error || !rv.data) return { erro: rv.error ? NG.msgErro(rv.error) : 'Venda não encontrada (ou sem permissão para vê-la).' };
    usuariosCache = ru;
    if (bo && cicloRow) cicloCache = cicloRow;
    if (!rpl.error) planosCache = rpl.data || [];
    if (!rlk.error) linksCache = rlk.data || [];
    if (!rmot.error) motivosCache = rmot.data || [];
    const v = rv.data;
    const ehParc = v.origem === 'parceiro_pap' && bo;
    if (rx27.data) {
      const { conferencia_obs, conferencia_em, conferencia_por, parceiro_indevida, parceiro_indevida_motivo, parceiro_indevida_em, ...viab } = rx27.data;
      Object.assign(v, viab, ehParc ? { conferencia_obs, conferencia_em, conferencia_por, parceiro_indevida, parceiro_indevida_motivo, parceiro_indevida_em } : {});
    }
    const convId = ((rc.data || [])[0] || {}).id || null;
    const planoLista = v.plano_id ? (planosCache || []).find((p) => p.id === v.plano_id) : null;
    // 2ª rodada: o que depende da conversa (se não saiu adiantado) e da venda (parceiro, faturas).
    const [rpCurto, rparc, rconv, fatRow, concRow] = await Promise.all([
      v.plano_id && !planoLista ? NG.sb.from('config_planos').select('nome_curto').eq('id', v.plano_id).maybeSingle() : null,   // plano inativo: fora da lista
      // Venda de parceiro (admin/backoffice): máximo de tentativas, comissão configurada e se o lançamento já saiu.
      ehParc ? Promise.all([
        NG.sb.from('config_parceiros').select('conferencia_max_tentativas').maybeSingle(),
        v.plano_id ? NG.sb.from('parceiro_comissao').select('parceiro_id, valor').eq('plano_id', v.plano_id) : Promise.resolve({ data: [] }),
        NG.sb.from('parceiro_pagamentos').select('id, tipo, status').eq('venda_id', id),
      ]) : null,
      !convId ? null : (convId === convPrev && pPrev ? pPrev.then((x) => x || daConversa(convId)) : daConversa(convId)),
      // 10/11: faturas do M-10 (v_adimplencia) e conciliação (v_conciliacao). As views ainda são rascunho: sem elas, a ficha
      // mostra "aguardando o extrato da Nio" (nunca dado de exemplo).
      v.instalado_em ? opc(NG.sb.from('v_adimplencia').select('faturas').eq('venda_id', id).maybeSingle()) : null,
      bo && v.comissao_paga != null ? opc(NG.sb.from('v_conciliacao').select('*').eq('venda_id', id).maybeSingle()) : null,
    ]);
    const [rcad, rnm, rbq, rut] = rconv || [null, { count: 0 }, { data: [] }, null];
    const nomeCurto = planoLista ? planoLista.nome_curto || null : ((rpCurto && rpCurto.data) || {}).nome_curto || null;
    const nomeDe = Object.fromEntries(ru.map((u) => [u.id, u.nome]));
    let parc = null;
    if (rparc) {
      const [rcfg, rcom, rpag] = rparc;
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
    let cad = null;
    if (rcad) {
      const [rkc, rtc, tpl] = rcad;
      cad = { k: rkc.error ? null : rkc.data, enviados: NG.cadEnviados(rtc.data), lista: rtc.data || [], tpl: tpl || {} };
    }
    const pendHist = (rph.data || []).filter((p) => p.encerrada_em).map((p) => ({ ...p, autor: nomeDe[p.encerrada_por] || nomeDe[p.aberta_por] }));
    const pendAberta = (rph.data || []).find((p) => !p.encerrada_em) || null;
    return {
      jor: jo || null,
      lead, din, leadCfg: lcfg || [],
      andamento: andRow || null,
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
      teto,
      ultTime: (rut && rut.txt) || null, ultTimeEm: (rut && rut.em) || null,
      adics: ra.data || [],
      conversaId: ((rc.data || [])[0] || {}).id || null,
      convInfo: (rc.data || [])[0] || null,   // 0082: dono no Chatwoot (Assumir só aparece sem dono)
      fnome,                                  // 0147: nomes do funil
      chatwoot: NG.linkChatwoot(((rc.data || [])[0] || {}).chatwoot_conversation_id),
      contatos: rk.data || [],
      usuarios: ru,
      nomeCurto,
    };
  }

  // ---------- próximo passo: botão e formulário que resolvem ----------
  const BOTAO = {
    pedido: 'Registrar pedido + OS', portal: 'Registrar pedido + OS (venda)', credito: 'Gravar o crédito', bio_status: 'Atualizar biometria', contato: 'Registrar contato',
    dfv: 'Consultar cobertura', sem_cobertura: 'Encerrar sem cobertura', agendar: 'Agendar instalação',
    reagendar: 'Reagendar', docs: 'Registrar envio dos documentos', viab: 'Registrar resultado do portal',
    pendencia: 'Ver a pendência',
  };
  // Bloco ligado a cada passo (é o único que abre sozinho).
  const BLOCO_DO_PASSO = {
    pedido: 'pedido', portal: 'pedido', credito: 'pedido', bio_status: 'pedido', invalida: 'pedido', contato: 'contatos', dfv: 'endereco', sem_cobertura: 'endereco',
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
  const TIT_SAIDA = 'SAÍDA · ENCERRAR COM MOTIVO';   // 13/11: o painel da ficha única diz que é a Saída (antes ficava o título do próximo passo)
  const formWrap = (id, titulo, texto, corpo, rotulo) => `<form class="f-formulario" data-form="${id}" novalidate>
      <h3>${esc(titulo)}</h3>${texto ? `<p>${texto}</p>` : ''}${corpo}${acoesForm(rotulo || 'Salvar')}</form>`;

  // 13/11 (4a): saída única. O porquê (sub-motivo) é texto livre no banco; a tela oferece a lista da decisão D4.
  const SAIDA_SUBS = { recusou: ['preço', 'concorrente', 'momento', 'desistiu', 'outro'], ja_cliente_nio: ['cliente ativo', 'pedido Nio em andamento', 'suporte'],
    nio_nao_instalou: ['inviabilidade', 'pendência sem solução', 'outro'] };
  const SAIDA_SO_VENDA = ['reprovado_biometria', 'nio_nao_instalou', 'venda_indevida_fraude'];
  // Nomes antigos (NG.MOTIVOS_SAIDA, saída sugerida pela pendência) → motivo e porquê da lista única.
  const SAIDA_DE_ANTIGO = { 'Sem cobertura': ['fachada_nao_atendida'], 'Já é cliente Nio': ['ja_cliente_nio'], Concorrente: ['recusou', 'concorrente'], 'Preço': ['recusou', 'preço'],
    'Sem contato (cadência esgotada)': ['sem_resposta'], Desistiu: ['recusou', 'desistiu'], 'Reprovado na biometria': ['reprovado_biometria'], 'Crédito negado': ['credito_negado'],
    'Fora da área': ['cidade_nao_atendida'], 'Interesse futuro (com data)': ['recusou', 'momento'] };
  function ajustarSaida(form, inicial) {
    const sel = form.querySelector('[data-saida-motivo]');
    if (!sel) return;
    const op = sel.selectedOptions[0];
    const cod = sel.value;
    const aj = form.querySelector('[data-saida-ajuda]');
    aj.hidden = !cod;
    aj.textContent = cod ? `${op.dataset.ajuda}${op.dataset.volta ? ` Volta: ${op.dataset.volta}.` : ''}` : '';
    const subs = SAIDA_SUBS[cod] || [];
    const box = form.querySelector('[data-saida-sub]');
    const pre = inicial ? sel.dataset.preSub : '';
    box.hidden = !subs.length;
    box.querySelector('select').innerHTML = subs.length ? `<option value="">Escolher…</option>${subs.map((x) => `<option${x === pre ? ' selected' : ''}>${esc(x)}</option>`).join('')}` : '';
    const volta = form.querySelector('[name="volta"]');
    if (cod === 'fachada_nao_atendida' && !volta.value) { volta.value = NG.somaDias(NG.diaSP(), 90); volta.dataset.auto = '1'; }   // a rede cresce: rever em 90 dias
    else if (cod !== 'fachada_nao_atendida' && volta.dataset.auto) { volta.value = ''; delete volta.dataset.auto; }
  }
  async function sairLead(motivo, sub, volta, obs, cancelou) {
    const { data, error } = await NG.sb.rpc('lead_sair', { p_conversa: d.soConversa ? d.conversaId : null, p_venda: d.soConversa ? null : d.v.id,
      p_motivo: motivo, p_sub: sub || null, p_volta: volta || null, p_obs: obs || null, p_cancelou_portal: cancelou });
    if (error) { NG.toast(NG.msgErro(error), 'bad'); return false; }
    NG.toast(data.resumo || 'Saída registrada', 'ok');
    feitoUltimo = { resumo: data.resumo || '✓ Saída registrada', aviso: data.pedido_aberto ? 'Falta cancelar o pedido na Nio: a linha "Cancelar na Nio" fica na Live até alguém confirmar.' : null };
    formAtivo = null; edicao = null; saidaPreset = null;
    await recarregar();
    avisarOuvintes(data);
    return true;
  }
  async function reabrirLead(bt) {
    if (!window.confirm('Reabrir este lead?\n\nEle sai da Saída e volta para o degrau onde parou. A conversa reabre no Chatwoot.')) return false;
    if (bt) bt.disabled = true;
    const { data, error } = await NG.sb.rpc('lead_reabrir', { p_conversa: d.soConversa ? d.conversaId : null, p_venda: d.soConversa ? null : d.v.id });
    if (error) { NG.toast(NG.msgErro(error), 'bad'); if (bt && bt.isConnected) bt.disabled = false; return false; }
    NG.toast(data.resumo || 'Reaberto', 'ok');
    feitoUltimo = { resumo: data.resumo || '✓ reaberto' };
    formAtivo = null;
    await recarregar();
    avisarOuvintes(data);
    return true;
  }

  const formMotivoConf = () => `<label class="campo">Motivo (o parceiro vê este texto)<select name="motivo_conf"><option value="">Escolher o motivo…</option>${Object.entries(NG.MOTIVOS_CONFERENCIA).map(([k, t]) => `<option value="${k}">${esc(t)}</option>`).join('')}</select></label>
      <label class="campo">Observação interna <span class="nota-campo">(não aparece para o parceiro)</span><textarea name="obs_conf" maxlength="500"></textarea></label>`;
  // Formulários (faixa do próximo passo, "Mover para…" e "Editar" dos blocos). Cada um grava o que a tela antiga gravava.
  const FORMS = {
    // Qualificado → Vendido (era o modal "Registrar venda": pedido + biometria; a trava do banco confere DFV e o resto).
    pedido: (v) => FORMS.portal(v),   // 0087: "Registrar venda" = pedido + OS (o mesmo formulário do portal)
    // Venda remota: o nosso time abre o pedido no portal e roda o crédito. Prompt 19: o link da biometria é disparado pela
    // própria Nio (WhatsApp + e-mail) na hora do pedido — salvar o nº do pedido marca a biometria pendente e a contagem
    // 24/72 h e o D+1 partem dali (trigger vendas_antes_biometria, 0032). O backoffice só avisa o cliente na conversa.
    // 0111 (Ricardo, 10/11): o nº do pedido só existe na OS (OS = nº do pedido, o único ID da Nio). Aqui só o crédito.
    portal: (v) => formWrap('portal', 'Crédito no portal',
      'Portal PAP (perfil BO): viabilidade · cadastro e crédito · oferta. Grave aqui o resultado do crédito — aprovado, a Nio manda o link da biometria ao cliente. O nº do pedido só existe quando a OS se abre (depois da biometria validada) e é gravado lá. Nunca abra pedido com CPF de teste.',
      `${botoesPortal}<span class="nota-campo mono">${esc(enderecoPortal(v))}</span>
       <label class="campo">Análise de crédito<select name="credito" autofocus>${NG.opcoes(NG.CREDITO, v.credito_resultado)}</select></label>
       <label class="campo">Link da biometria (opcional — só referência; quem manda é a Nio)<input type="url" name="link" value="${esc(v.biometria_link || '')}" placeholder="https://…" autocomplete="off"></label>${v.status === '0_qualificado' ? checkRecompra() : ''}`, 'Salvar'),
    bio_status: (v) => formWrap('bio_status', 'Biometria e crédito', 'O portal mostra a biometria como Pendente, com Risco ou Validada (Consulta OS). Validada libera abrir a OS (o nº do pedido = a OS).',
      `${botoesPortal}<div class="grade2"><label class="campo">Biometria<select name="biometria">${optBiometria(v.biometria_status)}</select></label>
       <label class="campo">Análise de crédito<select name="credito">${NG.opcoes(NG.CREDITO, v.credito_resultado)}</select></label></div>`, 'Salvar'),
    // Contato. 0102 (Ricardo, 10/11): sem teto 2/dia · 15/mês — só vale se alguém configurar contato_teto_dia/_mes.
    contato: () => formWrap('contato', 'Registrar contato', `Contatos ${NG.contatosTxt(d.lim.hoje, d.lim.mes, d.teto)}.`,
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
    // 0111: etapa 2 → 3 pelo CRÉDITO (sem número). Aprovado = a Nio manda o link da biometria; negado = outro CPF + pendência.
    credito: (v) => formWrap('credito', 'Gravar o crédito',
      'Viabilidade ok. Abra o Novo Pedido no portal (a extensão preenche), rode a análise de crédito e grave aqui o resultado — <b>não precisa de número</b>: o nº do pedido só existe na OS. Aprovado: a Nio manda o link da biometria e <b>o NIOGEN avisa o cliente sozinho</b>. Negado: o NIOGEN pede outro CPF ao cliente e abre a pendência.',
      `${botoesPortal}<label class="campo">Análise de crédito<select name="credito" required autofocus>${NG.opcoes(NG.CREDITO, credPreset || (['aprovado', 'so_cartao', 'pendente', 'negado'].includes(v.credito_resultado) ? v.credito_resultado : ''), 'Escolher o resultado…')}</select>${credPreset ? '<span class="nota-campo">Resultado trazido do operador de crédito — confira e grave.</span>' : ''}</label>
       <label class="check"><input type="checkbox" name="sem_aviso"> Já avisei o cliente do link da biometria (o NIOGEN não manda o aviso)</label>${checkRecompra()}`, 'Gravar o crédito'),
    // 0096 / 0111: etapa 3 → 4 (VENDA). O nº do pedido = a OS (o único ID da Nio); agendar é o passo seguinte.
    os: (v) => formWrap('os', 'Abrir a OS = VENDA',
      'Biometria validada. Abra a OS no portal e grave aqui o nº do pedido (é o mesmo número da OS — o ID da venda na Nio para instalação e comissão). Com isso a venda conta. Depois vem o agendamento. Contrato: até 4 h da biometria validada.',
      `${botoesPortal}<div class="grade2"><label class="campo">Nº do pedido (OS)<input type="text" name="os" value="${esc(v.nio_os || v.nio_pedido || '')}" autocomplete="off" autofocus></label></div>`, 'Gravar o pedido (OS) → vira Venda'),
    // 0089 (mantido): OS + dia + período num formulário só.
    os_agendar: (v) => formWrap('os_agendar', 'Abrir a OS e agendar = VENDA',
      'Biometria validada. No portal, abra a OS já com o dia e o período combinados com o cliente e grave aqui. Com isso, a venda conta. Contrato: até 4 h da biometria validada.',
      `${botoesPortal}<div class="grade2"><label class="campo">Nº do pedido (OS)<input type="text" name="os" value="${esc(v.nio_os || '')}" autocomplete="off" autofocus></label>
       ${campoData('Dia da instalação', 'dia', amanhaISO(), `min="${hojeISO()}" required`)}
       ${campoPeriodo('periodo', '08:00')}</div>`, 'Gravar OS e agendamento → vira Venda'),
    docs: () => formWrap('docs', 'Documentos entregues à Nio', 'Contrato: termos assinados e documentação em até 15 dias após a habilitação.',
      campoData('Entregues em', 'dia', hojeISO(), 'required'), 'Registrar'),
    // 13/11 (4a): a saída única (lead_sair, 0157) — vale para venda e para conversa sem venda. Motivos da config_lead.
    saida: () => {
      const A = NG.ajuda;
      const semVenda = !!d.soConversa;
      const v = semVenda ? null : d.v;
      const pre = saidaPreset ? (SAIDA_DE_ANTIGO[saidaPreset] || [saidaPreset]) : [];
      const motivos = (d.leadCfg || []).filter((x) => x.tipo === 'saida' && !(semVenda && SAIDA_SO_VENDA.includes(x.codigo)) && !(!semVenda && x.codigo === 'nao_contatar'));
      const aberto = v && (String(v.nio_pedido || '').trim() || String(v.nio_os || '').trim());
      const amanha = NG.somaDias(NG.diaSP(), 1);
      return formWrap('saida', 'Saída: encerrar com motivo', `${saidaPreset ? `Motivo sugerido pela pendência: <b>${esc(saidaPreset)}</b>. Confira e registre. ` : ''}O motivo vale para a tela Leads e para as contas do funil. ${NG.dicaTxt(A.saida_form)}`,
        `<label class="campo">Motivo<select name="motivo" data-saida-motivo data-pre-sub="${esc(pre[1] || '')}" required><option value="">Escolher…</option>${motivos.map((x) => `<option value="${esc(x.codigo)}" data-ajuda="${esc(x.ajuda || '')}" data-volta="${esc(x.volta || '')}"${x.codigo === pre[0] ? ' selected' : ''}>${esc(x.nome)}</option>`).join('')}</select></label>
         <span class="nota-campo" data-saida-ajuda hidden></span>
         <div class="campo" data-saida-sub hidden><span>Porquê ${NG.dicaTxt(A.saida_sub)}</span><select name="sub" aria-label="Porquê"></select></div>
         <div class="campo"><span>Volta em (opcional) ${NG.dicaTxt(A.saida_volta)}</span><input type="date" name="volta" min="${amanha}" aria-label="Volta em"></div>
         <label class="campo">Observação (opcional)<input type="text" name="obs" maxlength="200"></label>
         ${aberto ? `<div class="campo f-saida-portal"><span><b>Cancelou o pedido no portal?</b> ${NG.dicaTxt(A.saida_portal)}</span>
           <label class="check"><input type="radio" name="cancelou" value="sim"> Sim, já cancelei no portal PAP</label>
           <label class="check"><input type="radio" name="cancelou" value="nao"> Ainda não — deixar a linha "Cancelar na Nio" na Live</label></div>` : ''}
         ${!semVenda && d.conversaId ? '<span class="nota-campo">O cliente pediu para parar? Use o atalho "Cliente pediu para parar": ele põe a etiqueta nao-contatar e resolve a conversa.</span>' : ''}
         ${motivos.length ? '' : '<span class="nota-campo bad-txt">A lista de motivos não carregou. Feche e abra a ficha de novo.</span>'}`, 'Registrar saída');
    },
    sem_cobertura: (v) => formWrap('sem_cobertura', v.dfv_resultado === 'endereco_ocupado' ? 'Encerrar: já é cliente Nio' : 'Encerrar: sem cobertura',
      v.dfv_resultado === 'endereco_ocupado' ? 'Use só se o cliente confirmou que já tem Nio (vender seria estorno 100 %). A venda vai para Saída "Já é cliente Nio".'
        : 'Use só depois de conferir no portal (com variações de CEP, rua e número) que não há viabilidade. A venda vai para Saída "Sem cobertura" e volta para a fila em 90 dias.', '', 'Encerrar'),
    // Conferência de qualidade (venda de parceiro): motivo da lista fechada (0038) + observação INTERNA.
    conf_reprovar: () => formWrap('conf_reprovar', 'Reprovar a venda do parceiro',
      'A venda vai para Saída com este motivo e o parceiro vê só o motivo da lista. Suspeita de fraude: avise o Ricardo na hora.', formMotivoConf(), 'Reprovar e encerrar'),
    conf_devolver: () => formWrap('conf_devolver', 'Devolver ao parceiro',
      'A venda volta ao parceiro com o motivo da lista para ele corrigir e reenviar. Continua em Qualificado.', formMotivoConf(), 'Devolver ao parceiro'),
    // 0115: venda indevida (só admin) — não paga, cancela o que estava previsto e zera a ajuda de custo do mês do parceiro.
    conf_indevida: () => formWrap('conf_indevida', 'Marcar venda indevida',
      'Venda fora das regras do programa (fraude, cliente que já era Nio, dado falso…). O que esta venda ia pagar é cancelado e o parceiro fica sem a ajuda de custo do mês. O parceiro vê só "Venda fora das regras do programa". Dá para desmarcar.',
      '<label class="campo">Motivo interno (obrigatório)<textarea name="motivo_ind" maxlength="300" required></textarea></label>', 'Marcar indevida'),
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
       <label class="campo">Descrição <span class="nota-campo">(o que falta e com quem; obrigatória em "Outro motivo")</span><textarea name="descricao" maxlength="500">${esc(pendDescPreset || '')}</textarea></label>
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
  function avisarOuvintes(r) {
    if (modo === 'cheia' && d && fc.passo && !formAtivo) { fc.passo = false; render(); }   // 12/11: a ação terminou → o painel de ações fecha
    ouvintes.forEach((f) => { try { f(d && d.v, r || null); } catch (e) { /* tela que ouve */ } }); }
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
  // 0100 (Ricardo, 10/11: "não consigo jogar o cliente para Saída … botão para silenciar … somos revenda, não suporte da Nio"):
  // conversa SEM venda → Saída (perdida / fora de área / já cliente) ou Silenciar (cliente Nio · suporte) · Reativar desfaz.
  const SAIDA_CONV = {
    suporte_nio: 'Silenciar este cliente?\n\nCliente Nio com suporte/reclamação — não é venda. A Mari não responde mais, a conversa sai do Live e NÃO volta quando ele escrever (continua em Conversas › Todas, com o selo 📵). No Chatwoot: etiqueta suporte-nio, time backoffice, nota e adiada.\n\nDesfaz pelo botão "Reativar".',
    perdida: 'Mandar para Saída · Recusou?\n\nPara a cadência, põe a etiqueta saida-recusou e resolve no Chatwoot. Se ele escrever de novo, reabre na mesma etapa.',
    recusou: 'Mandar para Saída · Recusou?\n\nPara a cadência, põe a etiqueta saida-recusou e resolve no Chatwoot. Se ele escrever de novo, reabre na mesma etapa.',
    sem_cobertura: 'Mandar para Saída · Sem cobertura?\n\nUse só depois de conferir no portal. Para a cadência, etiqueta saida-sem-cobertura e resolve no Chatwoot.',
    credito_negado: 'Mandar para Saída · Crédito negado?\n\nUse só depois da 2ª consulta negada (titular e parente). Etiqueta saida-credito e resolve no Chatwoot.',
    sem_resposta: 'Mandar para Saída · Sem resposta?\n\nO cliente não respondeu à cadência. Etiqueta saida-sem-resposta e resolve no Chatwoot. Se ele escrever, reabre.',
    teste_duplicada: 'Marcar como Teste ou duplicada?\n\nSai das contas do funil e do Agente de Tráfego. Resolve no Chatwoot.',
    fora_area: 'Mandar para Saída · Fora de área?\n\nPara a cadência e resolve no Chatwoot. Se ele escrever de novo, volta para o Live.',
    ja_cliente: 'Mandar para Saída · Já é cliente Nio?\n\nPara a cadência e resolve no Chatwoot. Se ele escrever de novo, volta — para não voltar mais, use "Silenciar".',
    reativar: 'Reativar a conversa?\n\nEla volta para o Live com o time (a Mari segue calada; para ela voltar, "Devolver para a Mari").',
  };
  // Sinais de que a conversa é venda (pedido de suporte/reclamação não tem nenhum deles).
  function sinaisVenda(c) {
    if (!c) return [];
    const s = [];
    if ((c.chatwoot_etiquetas || []).includes('handoff-venda')) s.push('a Mari passou como venda (etiqueta handoff-venda)');
    if (c.plano_escolhido) s.push('tem plano escolhido');
    if (c.cep) s.push('tem CEP coletado');
    if (c.nio_viab_resultado) s.push('já teve viabilidade consultada');
    if (c.handoff_motivo && !['pedido_humano', 'ja_cliente_nio', 'ja_cliente', 'recusa_compra', 'fora_de_area', 'fora_area', 'sem_cobertura', 'urgencia_alta'].includes(c.handoff_motivo)) s.push(`a Mari passou por "${c.handoff_motivo.replace(/_/g, ' ')}"`);
    return s;
  }
  async function rodarSaidaConversa(motivo) {
    if (!SAIDA_CONV[motivo] || !window.confirm(SAIDA_CONV[motivo])) return null;
    // 12/11 (Ricardo; caso Joana, lead de venda silenciada por engano): com sinal de venda, o silenciar pede uma 2ª confirmação.
    if (motivo === 'suporte_nio') {
      const sv = sinaisVenda(d.conv);
      if (sv.length && !window.confirm(`Esta conversa parece VENDA, não suporte:\n· ${sv.join('\n· ')}\n\nSilenciar mesmo? Ela some do Live e a Mari não responde mais.`)) return null;
    }
    const { data, error } = await NG.sb.rpc('backoffice_conversa_saida', { p_conversa: d.conversaId, p_motivo: motivo });
    if (error) { NG.toast(NG.msgErro(error), 'bad'); return null; }
    NG.toast(data.resumo || 'Feito', 'ok');
    feitoUltimo = { resumo: data.resumo };
    await recarregar();
    avisarOuvintes(data);
    return data;
  }
  // 0101: espera da conversa (ate = 'AAAA-MM-DD'; nulo = Retomar agora).
  async function rodarEsperaConversa(ate, motivo) {
    const { data, error } = await NG.sb.rpc('backoffice_conversa_espera', { p_conversa: d.conversaId, p_ate: ate, p_motivo: motivo });
    if (error) { NG.toast(NG.msgErro(error), 'bad'); return null; }
    NG.toast(data.resumo || 'Feito', 'ok');
    feitoUltimo = { resumo: data.resumo };
    formAtivo = null;
    await recarregar();
    avisarOuvintes(data);
    return data;
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

  // 0102 (trava B1): recompra / cliente já Nio = multa R$ 500 + estorno 100 %. "Gravar pedido" com selo de possível duplicado
  // (⚠️ ↩️ 🏠 📱) ou nota "VENDA NÃO CRIADA" exige marcar a conferência. Não bloqueia a venda; grava o evento conferencia_recompra.
  const selosRecompra = () => ((d && d.avisos && d.avisos.selos) || []).filter((s) => s.venda_id !== (d.v || {}).id);
  const naoCriada = () => /VENDA N[ÃA]O CRIADA/i.test(String((d && d.convInfo && d.convInfo.handoff_briefing) || ''));
  const precisaConferir = () => selosRecompra().length > 0 || naoCriada();
  const checkRecompra = () => (precisaConferir()
    ? `<label class="check recompra"><input type="checkbox" name="conferi_recompra"> <b>Conferi: não é cliente nem endereço Nio</b>
        <small class="apagado">${esc([...new Set(selosRecompra().map((s) => NG.ICONE_SELO[s.tipo] || '⚠️'))].join(' '))}${naoCriada() ? ' ⚠️ VENDA NÃO CRIADA' : ''} · recompra = multa R$ 500; cliente ou endereço já Nio = estorno 100 %</small></label>`
    : '');
  async function conferiuRecompra(fd, origem) {
    if (!precisaConferir()) return true;
    if (!fd.get('conferi_recompra')) {
      NG.toast('Marque "Conferi: não é cliente nem endereço Nio" — há aviso de possível duplicado nesta venda.', 'bad');
      return false;
    }
    const { error } = await NG.sb.rpc('venda_conferencia_recompra', {
      p_venda: d.v.id, p_selos: [...selosRecompra().map((s) => s.tipo), ...(naoCriada() ? ['venda_nao_criada'] : [])], p_origem: origem,
    });
    if (error) NG.toast(`Conferência não registrada: ${NG.msgErro(error)}`, 'bad');   // não segura a venda
    return true;
  }

  // 0103: última fala do time na conversa (turno 'humano' ou mensagem do time na outbox) — vira o motivo sugerido do ⏸.
  async function ultimaFalaTime(cid) {
    const [rt, ra] = await Promise.all([
      NG.sb.from('mari_turnos').select('texto, created_at').eq('conversa_id', cid).eq('papel', 'humano').order('created_at', { ascending: false }).limit(1),
      NG.sb.from('chatwoot_acoes').select('payload, criada_em').eq('conversa_id', cid).eq('tipo', 'mensagem').in('status', ['pendente', 'executando', 'feita']).order('criada_em', { ascending: false }).limit(1),
    ]);
    const t = ((rt && rt.data) || [])[0];
    const a = ((ra && ra.data) || []).filter((x) => x.payload && x.payload.como === 'humano')[0];
    const doTurno = !a || (t && new Date(t.created_at) >= new Date(a.criada_em));
    const ult = doTurno ? (t && t.texto) : a.payload.content;
    // 13/11: devolve também QUANDO o time falou — a faixa "Lembretes da Mari" não acusa "a Mari não respondeu" se o time respondeu.
    return ult ? { txt: String(ult).replace(/\s+/g, ' ').trim().slice(0, 80), em: doTurno ? t.created_at : a.criada_em } : null;
  }
  // 0103: o cliente só confirmou ("ok", 👍) depois da nossa última fala — v_jornada.confirmou_em (na Sua vez de novo após 4 h úteis).
  const soConfirmou = (j) => !!(j && j.confirmou_em);
  let pendDescPreset = null;   // 0103: descrição sugerida no "Abrir pendência" (a última fala do time)

  const SALVAR = {
    async conv_espera(fd) { return !!(await rodarEsperaConversa(fd.get('ate'), String(fd.get('motivo') || '').trim())); },
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
      const cred = fd.get('credito') || null;
      // 0111: crédito mudou = momento "credito" (aprovado na etapa 2 → etapa 3: etiqueta, nota e aviso do link pelo sistema).
      if (cred && cred !== (v.credito_resultado || null) && ehBO()) {
        if (['aprovado', 'so_cartao'].includes(cred) && v.status === '0_qualificado' && !(await conferiuRecompra(fd, 'ficha'))) return false;
        if (!(await rodarMomento('credito', { resultado: cred }))) return false;
        if (!link || link === (v.biometria_link || '')) return true;
        return gravar({ biometria_link: link }, 'Link da biometria salvo');
      }
      return gravar({ credito_resultado: cred, biometria_link: link || v.biometria_link || null }, 'Crédito atualizado');
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
      if (saida && NG.noTetoContato(d.lim.hoje, d.lim.mes, d.teto) && !fd.get('autorizado')) {
        NG.toast('Teto de contatos configurado atingido. Só registre se o cliente pediu ou autorizou.', 'bad');
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
    async credito(fd) {
      const resultado = fd.get('credito') || '';
      if (!resultado) { NG.toast('Escolha o resultado do crédito.', 'bad'); return false; }
      if (['aprovado', 'so_cartao'].includes(resultado) && !(await conferiuRecompra(fd, 'ficha'))) return false;
      return !!(await rodarMomento('credito', { resultado, sem_aviso: !!fd.get('sem_aviso') }));
    },
    async os(fd) {
      const os = String(fd.get('os') || '').trim();
      if (!os) { NG.toast('Informe o nº do pedido (OS).', 'bad'); return false; }
      return !!(await rodarMomento('os', { os }));
    },
    async os_agendar(fd) {
      const os = String(fd.get('os') || '').trim();
      if (!os) { NG.toast('Informe o nº do pedido (OS).', 'bad'); return false; }
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
      pendPreset = null; pendDescPreset = null;
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
      const sub = String(fd.get('sub') || '').trim();
      if (motivo === 'recusou' && !sub) { NG.toast('Diga o porquê da recusa.', 'bad'); return false; }
      const volta = fd.get('volta') || null;
      if (motivo === 'recusou' && sub === 'momento' && !volta) { NG.toast('Informe a data de volta que o cliente deu.', 'bad'); return false; }
      const aberto = !d.soConversa && (String(d.v.nio_pedido || '').trim() || String(d.v.nio_os || '').trim());
      const canc = fd.get('cancelou');
      if (aberto && !canc) { NG.toast('Diga se o pedido já foi cancelado no portal.', 'bad'); return false; }
      return sairLead(motivo, sub, volta, String(fd.get('obs') || '').trim(), aberto ? canc === 'sim' : null);
    },
    async sem_cobertura() {
      const ocupado = d.v.dfv_resultado === 'endereco_ocupado';
      return sairLead(ocupado ? 'ja_cliente_nio' : 'fachada_nao_atendida', ocupado ? 'cliente ativo' : null, ocupado ? null : NG.somaDias(NG.diaSP(), 90), null, null);
    },
    async conf_reprovar(fd) { return confSalvar(fd, 'reprovada'); },
    async conf_devolver(fd) { return confSalvar(fd, 'devolvida'); },
    async conf_indevida(fd) {
      const motivo = String(fd.get('motivo_ind') || '').trim();
      if (!motivo) { NG.toast('Escreva o motivo da venda indevida.', 'bad'); return false; }
      return confIndevida(true, motivo);
    },
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
      const os = String(fd.get('os') || '').trim() || null;   // 0111: OS = nº do pedido (um ID só)
      return gravar({
        nio_pedido: os,
        nio_os: os,
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
  async function confIndevida(marcar, motivo) {
    const { data, error } = await NG.sb.rpc('parceiro_marcar_indevida', { p_venda: d.v.id, p_indevida: marcar, p_motivo: motivo || null });
    if (error) { NG.toast(NG.msgErro(error), 'bad'); return false; }
    NG.toast(marcar ? `Venda indevida · ${data.pagamentos_mudados} pagamento(s) cancelado(s)${data.ajuda_mudada ? ' · ajuda de custo do mês cancelada' : ''}` : 'Venda desmarcada: o que foi cancelado voltou a previsto', 'ok');
    formAtivo = null;
    await recarregar();
    avisarOuvintes(null);
    return true;
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
      ${linha('Contatos', esc(NG.contatosTxt(d.lim.hoje, d.lim.mes, d.teto)))}
      ${v.conferencia_motivo ? linha('Motivo', esc(NG.MOTIVOS_CONFERENCIA[v.conferencia_motivo] || v.conferencia_motivo)) : ''}
      ${v.conferencia_obs ? linha('Observação interna', `${esc(v.conferencia_obs)} <small class="apagado">· não aparece para o parceiro</small>`) : ''}
      ${st === 'aprovada' && v.conferencia_em ? linha('Aprovada em', esc(`${NG.fmtDataHora(v.conferencia_em)}${quem ? ' · ' + quem : ''}`)) : ''}
      ${st !== 'aprovada' && v.status === '0_qualificado' ? '<div class="faixa amarelo">Enquanto a conferência não for aprovada, o banco não deixa a venda passar de Qualificado.</div>' : ''}
      ${d.avisoBanco ? `<div class="faixa amarelo">${esc(d.avisoBanco)}</div>` : ''}
      ${d.avisoTent ? `<div class="faixa amarelo">${esc(d.avisoTent)} (nada foi gravado)</div>` : ''}
      ${botoes}${form}
      ${v.parceiro_indevida ? `<div class="faixa vermelho">Venda indevida${v.parceiro_indevida_em ? ` desde ${esc(NG.fmtDataHora(v.parceiro_indevida_em))}` : ''}: ${esc(v.parceiro_indevida_motivo || '')}. Não paga e o mês do parceiro fica sem ajuda de custo.
          ${perfil === 'admin' ? '<button type="button" class="btn btn-sm" data-f="conf-desmarcar-indevida">Desmarcar</button>' : ''}</div>`
        : perfil === 'admin' && !form ? '<div class="conf-botoes"><button type="button" class="btn btn-sm" data-f="conf-form-indevida">Marcar venda indevida…</button></div>' : ''}
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
        ${ehBO() ? NG.botaoOperador({ vendaId: v.id }, '⌖ Consultar pelo operador') : ''}
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
      // 0111: o 2º passo é o crédito (o nº do pedido = a OS, no 4º passo).
      { nome: 'Crédito', ...(['aprovado', 'so_cartao'].includes(v.credito_resultado) ? { s: 'ok', d: NG.CREDITO[v.credito_resultado] }
        : v.credito_resultado === 'negado' ? { s: 'wa', d: 'negado · outro CPF' } : v.credito_resultado === 'pendente' ? { s: 'wa', d: 'pendente' }
        : v.nio_pedido && !v.nio_os ? { s: 'ok', d: 'pedido gravado' } : { s: 'no', d: '' }) },
      { nome: 'Biometria', ...pBio },
      { nome: 'Pedido (OS)', s: v.nio_os ? 'ok' : 'no', d: v.nio_os ? `nº ${v.nio_os}` : '' },
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
  // Modo foco do Live: "← Lista" no cabeçalho da ficha (a tela diz o que fazer).
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
  // 12/11 (Ricardo: "na Live a conversa volta para o topo o tempo todo"): o redesenho tira o nó da conversa do DOM e
  // o devolve — e o navegador zera a rolagem de quem sai do DOM. Lê a rolagem ANTES do innerHTML e devolve depois:
  // quem estava no fim continua no fim (inclusive com mensagem nova); quem subiu para ler fica onde estava.
  // 13/11 (Ricardo: "o destino também na ficha da venda"): destino e etapa da conversa que gerou a venda (0147).
  function linhaFunilVenda() {
    const cv = d && d.convInfo;
    if (!cv || !cv.funil_etapa) return '';
    const fn = d.fnome || { etapa: {}, destino: {} };
    const dest = cv.funil_destino && cv.funil_destino !== 'em_andamento'
      ? `${cv.funil_destino === 'instalada' ? '✅' : '⛔'} Destino: <b>${esc(fn.destino[cv.funil_destino] || cv.funil_destino)}</b>${cv.funil_detalhe ? ` (${esc(cv.funil_detalhe)})` : ''} · `
      : 'Destino: <b>em andamento</b> · ';
    return `<div class="f-funil-linha">${dest}Etapa: <b>${esc(fn.etapa[cv.funil_etapa] || cv.funil_etapa)}</b></div>`
      + (cv.funil_alerta ? `<div class="f-funil-linha warn">⚠ ${esc(NG.FUNIL_ALERTA[cv.funil_alerta] || cv.funil_alerta)}</div>` : '');
  }
  function guardarRolagemConv(vivo) {
    const m = vivo && vivo.querySelector('[data-msgs]');
    if (!m) return () => {};
    const noFim = m.scrollHeight - m.scrollTop - m.clientHeight < 60;
    const topo = m.scrollTop;
    return () => { m.scrollTop = noFim ? m.scrollHeight : topo; };
  }
  function reporConversa(vivo, foco, devolverRolagem) {
    const host = raiz.querySelector('.f-conv-host');
    if (vivo && host && cvComp && cvComp.id === d.conversaId) {
      host.appendChild(vivo);
      if (devolverRolagem) devolverRolagem();
      if (foco && vivo.contains(foco)) foco.focus({ preventScroll: true });   // mover o nó tira o cursor da caixa: devolve
      return;
    }
    if (cvComp) { cvComp.destruir(); cvComp = null; }
    montarConversaInterna();
  }
  function abrirConversa() {
    if (modo === 'cheia') { if (cvCheia) cvCheia.focar(); return; }
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
    credito: 'aprovado: etiqueta biometria-pendente · nota · avisa o cliente do link da biometria. Negado: pede outro CPF ao cliente e abre a pendência.',
    biometria: 'Validada: o próximo passo vira abrir a OS (4 h). Negado: pede outro CPF ao cliente e abre a pendência.',
    os: 'nota no Chatwoot. Com a OS a venda conta; o próximo passo é agendar a instalação.',
    agendar: 'etiqueta instalacao-agendada · nota · confirma o dia ao cliente · resolve a conversa (sem dono; a Mari volta se ele escrever).',
    os_agendar: 'etiqueta instalacao-agendada · nota · confirma o dia ao cliente · resolve a conversa (sem dono; a Mari volta se ele escrever).',
    reagendar: 'confirma a nova data ao cliente e resolve a conversa.',
    docs: 'registra a entrega (contrato: 15 dias depois da instalação).',
    pendencia: 'a venda sai da sua vez até a data de revisão e a cadência da Mari pausa.',
    manual: 'sai da sua vez.',
    responder: 'a resposta sai como pessoa (a Mari não responde).',
  };

  // 12/11: as partes do próximo passo (a ficha da gaveta junta em faixas; a tela cheia do Live põe no card Agora e no painel de ações).
  function faixaProximo(v, pr) {
    const p = passoPartes(v, pr);
    return `${p.faixaConv}${quadroPasso('venda', NIVEL_CLS[p.nivel] || 'dim', NIVEL_ROT[p.nivel] || 'PRÓXIMO PASSO', p.texto, p.corpo, p.forcar)}${p.feito}`;
  }
  function passoPartes(v, pr) {
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
      if (pr.resolver && BOTAO[pr.resolver] && !['pedido', 'credito', 'portal', 'bio_status', 'os', 'agendar', 'reagendar', 'os_agendar'].includes(pr.resolver)) bts.push(`<button type="button" class="btn" data-resolver="${pr.resolver}">${esc(BOTAO[pr.resolver])}</button>`);
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
        if (!form) { formAtivoPadrao = 'credito'; }
        sozinho = SOZINHO.credito;
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
    let corpoConv = '';
    if (alertaConv && bo) {
      const bc = jReal.botao === 'manual' && d.bloqueada
        ? [B('data-f="manual-copiar"', 'Copiar o texto', false), d.chatwoot ? `<a class="btn" href="${esc(d.chatwoot)}" target="_blank" rel="noopener">Chatwoot ↗</a>` : '', B('data-f="manual-mandei"', 'Já mandei', true)]
        : [B('data-f="conversa"', 'Abrir a conversa e responder', true)];
      corpoConv = `<div class="f-prox-bts">${bc.filter(Boolean).join('')}</div><span class="f-sozinho">O NIOGEN faz sozinho: ${esc(jReal.botao === 'manual' ? SOZINHO.manual : SOZINHO.responder)}</span>`;
      faixaConv = quadroPasso('conv', 'bad f-alerta-conv', 'CONVERSA · AGORA', jReal.o_que_fazer, corpoConv);
    }
    // 0103: cliente só confirmou → atalho da pendência já à mão, com a última fala do time como descrição.
    const conf = bo && soConfirmou(jReal) && !d.pend && v.status !== 'saida';
    const notaConf = conf ? `<div class="f-conf-cli"><span class="f-nota">💬 O cliente só confirmou${d.ultTime ? ` ("${esc(d.ultTime)}")` : ''}. Está esperando a Nio ou outro terceiro? Abra a <b>⏸ Pendência</b> — senão a venda volta para a sua vez em 4 h úteis para você dar o retorno.</span>
        <div class="f-prox-bts"><button type="button" class="btn btn-sm" data-f="pend-conf">⏸ Pendência com esse motivo</button></div></div>` : '';
    // 10/11: o quadro nasce recolhido (rótulo + uma linha); expandido mostra o botão principal, o "faz sozinho" e as ações do passo.
    const corpo = `${notaConf}${nota ? `<span class="f-nota">${esc(nota)}</span>` : ''}
        ${bts.filter(Boolean).length && !form ? `<div class="f-prox-bts">${bts.filter(Boolean).join('')}</div>` : ''}
        ${corpoForm ? `<div class="f-prox-form">${corpoForm}</div>` : ''}
        ${sozinho && !form ? `<span class="f-sozinho">O NIOGEN faz sozinho: ${esc(sozinho)}</span>` : ''}
        ${atalhos(v)}`;
    const temAcao = bts.filter(Boolean).length > 0 || !!corpoForm;
    return { faixaConv, corpoConv, alertaConv: !!(alertaConv && bo), jReal, nivel, texto, corpo, forcar: !!form || conf, feito, nota, sozinho, temAcao,
      rotuloAcao: (bts.filter(Boolean)[0] || '').replace(/<[^>]+>/g, '').trim() };
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
        <span>Contatos ${esc(NG.contatosTxt(d.lim.hoje, d.lim.mes, d.teto))}</span></div>
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
      ${linhasAndamento()}
      ${d.pend ? `<div class="f-st-g"><span class="f-rot">PENDÊNCIA</span><span class="f-chip espera">⏸ ${esc(d.pend.nome)} · ${esc(d.pend.diaTxt)}</span></div>` : ''}
    </div>`;
  }

  // 0105: o andamento do pedido na Nio, lido sozinho — PORTAL PAP (status do Histórico, extensão 0.4) e BIOMETRIA (GED360, a cada
  // 15 min). Alerta vivo aparece em vermelho/amarelo com "Visto" (tira do Live até o status mudar de novo).
  function linhasAndamento() {
    const a = d.andamento;
    if (!a) return '';
    const NIV = { agora: 'bad', hoje: 'wa' };
    const visto = (origem, chave) => `<button type="button" class="btn btn-sm" data-f="and-visto" data-origem="${origem}" data-chave="${esc(chave)}" title="Tira o alerta do Live até o status mudar de novo">Visto</button>`;
    const portal = a.portal_status ? `<div class="f-st-g"><span class="f-rot">PORTAL PAP</span>
        <span class="f-chip ${a.portal_status === 'GROSS' ? 'ok' : a.portal_alerta ? NIV[a.portal_alerta_nivel] || 'wa' : 'info'}">${esc(a.portal_rotulo || a.portal_status)}</span>
        <span class="apagado">desde ${esc(NG.fmtDataHora(a.portal_desde))} · lido ${esc(NG.fmtDataHora(a.portal_lido_em))} · nº ${esc(a.portal_pedido)}</span>
        ${a.portal_alerta ? `<span class="f-chip ${NIV[a.portal_alerta_nivel] || 'wa'}">${esc(a.portal_alerta)}</span>${visto('portal', a.portal_pedido)}` : ''}</div>` : '';
    const bio = a.bio_resultado ? `<div class="f-st-g"><span class="f-rot">BIOMETRIA</span>
        <span class="f-chip ${a.bio_acao === 'aprovada' ? 'ok' : a.bio_alerta ? NIV[a.bio_alerta_nivel] || 'wa' : a.bio_desconhecido ? 'wa' : 'espera'}">${esc(a.bio_rotulo || a.bio_resultado)}${a.bio_desconhecido ? ' · texto novo' : ''}</span>
        <span class="apagado">GED360 · protocolo ${esc(a.bio_protocolo)} · envio ${esc(NG.fmtDataHora(a.bio_envio))}${a.bio_conferencia ? ` · conferência ${esc(NG.fmtDataHora(a.bio_conferencia))}` : a.bio_acao === 'espera' ? ' · aguardando a Nio conferir' : ''} · lido ${esc(NG.fmtDataHora(a.bio_lido_em))}</span>
        ${a.bio_alerta ? `<span class="f-chip ${NIV[a.bio_alerta_nivel] || 'wa'}">${esc(a.bio_alerta)}</span>${visto('ged360', a.bio_protocolo)}` : ''}</div>` : '';
    return portal + bio;
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

    // M-10: apurado no 10º mês após a ativação (decisão A3, 12/11; texto do contrato em NG.TEXTOS_COMISSAO.m10).
    let m10 = '—';
    if (vendida) {
      if (v.nio_venda_valida === false) m10 = esc(NG.textoComissao('m10Nao', 'a Nio marcou a venda como inválida'));
      else if (!Number(v.bonus_m10_potencial)) m10 = esc(NG.textoComissao('m10Nao', 'o plano não tem bônus M-10 na política vigente'));
      else {
        let quando = 'no 10º mês após a ativação';
        if (v.ativado_em || v.instalado_em) {
          const x = new Date(v.ativado_em || v.instalado_em);
          x.setMonth(x.getMonth() + 10);
          quando = `em ${new Intl.DateTimeFormat('pt-BR', { timeZone: NG.TZ, month: '2-digit', year: 'numeric' }).format(x)} (10º mês)`;
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
        id: 'pedido', titulo: 'Crédito, biometria e pedido (OS)',
        resumo: [v.nio_pedido || v.nio_os ? `Pedido (OS) #${v.nio_os || v.nio_pedido}` : 'pedido (OS) depois da biometria',
          v.biometria_status === 'pendente' && v.biometria_link_enviado_em
            ? `link enviado pela Nio ${NG.fmtDataHora(v.biometria_link_enviado_em)}`
            : `biometria ${NG.BIOMETRIA[v.biometria_status] || NG.BIOMETRIA.nao_enviada}`,
          v.credito_resultado ? `crédito ${NG.CREDITO[v.credito_resultado]}` : null].filter(Boolean).join(' · '),
        corpo: () => `${linha('Nº do pedido (OS)', `<span class="mono">${esc(v.nio_os || v.nio_pedido || '—')}</span>${v.nio_os_em ? ' · ' + esc(NG.fmtDataHora(v.nio_os_em)) : ''}`)}
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
          <div class="grade2"><label class="campo">Nº do pedido (OS)<input type="text" name="os" value="${esc(v.nio_os || v.nio_pedido || '')}" autocomplete="off"></label>
          <label class="campo">Contrato Nio<input type="text" name="contrato" value="${esc(v.nio_contrato || '')}"></label>
          <label class="campo">Interesse no portal<input type="text" name="interesse" value="${esc(v.nio_viab_interesse_id || '')}" autocomplete="off"></label>
          <label class="campo">Análise de crédito<select name="credito">${NG.opcoes(NG.CREDITO, v.credito_resultado)}</select></label>
          <label class="campo">Biometria (link)<select name="biometria">${optBiometria(v.biometria_status)}</select></label>
          <label class="campo">Vendedor<select name="vendedor"><option value="">—</option>${vendedores.map((u) => `<option value="${u.id}" ${u.id === v.vendedor_id ? 'selected' : ''}>${esc(u.nome)}</option>`).join('')}</select></label></div>
          <label class="campo">Link da biometria<input type="url" name="link" value="${esc(v.biometria_link || '')}" placeholder="https://…" autocomplete="off"></label>
          <span class="nota-campo">A etapa só anda pelo botão do próximo passo. Venda = crédito aprovado + biometria validada + pedido (OS) aberto + viabilidade do portal (o banco confere); o agendamento vem depois.</span>
          ${acoesForm('Salvar')}</form>`,
      },
      {
        id: 'instalacao', titulo: 'Instalação',
        resumo: v.instalado_em ? `instalada ${NG.fmtData(v.instalado_em)}${v.docs_dispensados_em ? '' : v.docs_entregues_em ? ' · docs ✓' : v.docs_prazo_em ? ` · docs até ${NG.fmtData(v.docs_prazo_em)}` : ''}`
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
            ${linha('Documentos à Nio', esc(v.docs_dispensados_em ? 'dispensados — venda remota, o aceite é a biometria da Nio' : v.docs_entregues_em ? `entregues ${NG.fmtDataAno(v.docs_entregues_em)}` : v.docs_prazo_em ? `prazo ${NG.fmtData(v.docs_prazo_em)} (15 dias)` : '—'))}`;
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
        resumo: `${NG.contatosTxt(d.lim.hoje, d.lim.mes, d.teto)}${d.contatos[0] ? ` · último ${NG.quando(d.contatos[0].em)}` : ''}`,
        corpo: () => `<div class="faixa ${NG.noTetoContato(d.lim.hoje, d.lim.mes, d.teto) ? 'amarelo' : 'cinza'}">Contatos que nós fizemos: ${esc(NG.contatosTxt(d.lim.hoje, d.lim.mes, d.teto))}. Sem teto por dia ou mês; os toques automáticos da Mari só saem seg–sex 9–21, sáb 10–16, nunca domingo ou feriado.</div>
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
    desenhar();
    const fs = raiz && raiz.querySelector('[data-form="saida"]');
    if (fs) ajustarSaida(fs, true);
  }
  function desenhar() {
    if (!raiz || !d) return;
    if (modo === 'cheia') { renderCheia(); return; }
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
    const devolverRolagem = guardarRolagemConv(vivo);

    raiz.innerHTML = `<div class="ficha f-${modo}${largo ? ' f-largo' : ''}${convAberta && d.conversaId && !hostConversa ? ' conv-on' : ''}">
      ${painelConversa()}
      ${cabecalho(v)}
      <div class="f-corpo"><div class="f-col-a">
        ${linhaFunilVenda()}
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
    reporConversa(vivo, focoAntes, devolverRolagem);
    ligarDfvSeEditando();
    const f = raiz.querySelector('[data-form] [autofocus]');
    if (f && formAtivo) f.focus({ preventScroll: true });
  }

  // ---------- ficha de CONVERSA (etapa 1: conversa sem venda) ----------
  // 11/11: uma rodada só (antes eram 3 em fila) e a linha da jornada vem da carga compartilhada.
  async function carregarConversa(cid, fresco) {
    if (fresco) NG.limparCache();
    const [rc, jo, rq, rk, rn, rt, rb, ultFala, fnome, lead, lcfg] = await Promise.all([
      NG.sb.from('mari_conversas').select('id, venda_id, telefone, cidade, cep, origem, nome_contato, dados, plano_escolhido, chatwoot_conversation_id, chatwoot_status, chatwoot_agente, chatwoot_time, chatwoot_etiquetas, humano_atribuido, nao_contatar, ultima_msg_lead_at, nio_viab_resultado, credito_resultado, credito_em, status, handoff_motivo, handoff_briefing, handoff_em, quadro_encerrada_motivo, espera_ate, espera_motivo, espera_em, funil_etapa, funil_destino, funil_detalhe, funil_alerta, created_at, cadencia_passo, cadencia_retorno_em, agendamento_retorno, chatwoot_resolvida, time_atribuido').eq('id', cid).maybeSingle(),
      NG.jornadaLinha({ conversa: cid }),
      NG.sb.from('v_mari_quadro').select('coluna, itens, itens_total, itens_validados, faltam, contatos_hoje, contatos_mes, plano_nome, trava_cliente_nio, trava_endereco_nio, trava_viabilidade').eq('id', cid).maybeSingle(),
      NG.sb.rpc('mari_cadencia_avaliar', { p_conversa: cid }).maybeSingle(),   // 13/11: só esta conversa (60 ms; a view avalia todas)
      NG.sb.from('mari_turnos').select('id', { count: 'exact', head: true }).eq('conversa_id', cid).in('papel', ['lead', 'mari', 'humano']),
      NG.sb.from('mari_turnos').select('texto, tags, created_at').eq('conversa_id', cid).eq('papel', 'mari').not('tags->>cadencia', 'is', null).order('created_at'),
      NG.sb.from('chatwoot_acoes').select('id, payload, erro, criada_em').eq('conversa_id', cid).eq('status', 'bloqueada').order('criada_em', { ascending: false }).limit(1),
      ultimaFalaTime(cid),   // 0103 (só usada se o cliente apenas confirmou)
      NG.funilNomes(),       // 0147: nomes de etapa e destino (cache da página)
      opcL(NG.sb.from('v_leads').select('*').eq('conversa_id', cid).limit(1)),   // 13/11 (4a): a trilha da escada
      leadCfg(),
    ]);
    if (rc.error || !rc.data) return { erro: rc.error ? NG.msgErro(rc.error) : 'Conversa não encontrada (ou sem permissão).' };
    if (rc.data.venda_id) return { venda: rc.data.venda_id };
    const c = rc.data;
    const ultTime = jo && jo.confirmou_em && ultFala ? ultFala.txt : null;   // 0103
    return {
      soConversa: true, ultTime, ultTimeEm: (ultFala && ultFala.em) || null, fnome, lead, leadCfg: lcfg || [], conv: { ...c, nome: (c.dados && c.dados.nome) || c.nome_contato || 'Contato' },
      jor: jo || null, q: rq.error ? {} : (rq.data || {}),
      cad: { k: rk.error ? null : rk.data, enviados: NG.cadEnviados(rt.data), lista: rt.data || [] },
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
  // 12/11: as partes da ficha de conversa (a gaveta desenha em faixas; a tela cheia do Live, no card Agora e nos cards).
  function conversaPartes() {
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
    const silenciada = c.quadro_encerrada_motivo === 'suporte_nio';
    // 0101 (Ricardo, Valdirene: "agora eu tenho é que aguardar, deixar em standby"): espera ativa = marcada e o cliente não
    // escreveu depois. Some da Sua vez até o dia (09h) e volta como "Retomar · motivo"; se ele escrever antes, a espera cai.
    const emEspera = !!c.espera_ate && (!c.ultima_msg_lead_at || new Date(c.ultima_msg_lead_at) <= new Date(c.espera_em));
    if (silenciada || (emEspera && new Date(c.espera_ate) > new Date())) { bts.length = 0; sozinho = ''; }
    if (bo && !silenciada && emEspera) bts.push('<button type="button" class="btn btn-acc" data-cespera="retomar">▶ Retomar agora</button>');
    else if (bo && !silenciada && !c.nao_contatar && (dono.tipo === 'pessoa' || dono.tipo === 'time')) bts.push('<button type="button" class="btn" data-f="conv-espera">⏸ Aguardar…</button>');
    const amanhaC = NG.somaDias(NG.diaSP(), 1);
    // 0103: o cliente só confirmou ("ok") → o ⏸ Aguardar já vem aberto, com a última fala do time como motivo. Um clique resolve.
    const confC = bo && soConfirmou(j) && !emEspera && !silenciada && !c.nao_contatar && (dono.tipo === 'pessoa' || dono.tipo === 'time');
    if (confC && formAtivo == null && !convEsperaFechado) formAtivo = 'conv_espera';
    const formEspera = formAtivo === 'conv_espera' ? `<form class="f-form" data-form="conv_espera">
        ${confC ? `<span class="f-nota">💬 O cliente só confirmou. Se você ficou de dar um retorno, marque a espera — senão a conversa volta para a sua vez em 4 h úteis.</span>` : ''}
        <label>Aguardando o quê? <input name="motivo" list="f-esp-motivos" maxlength="80" placeholder="ex.: parente decidir" value="${esc(confC && d.ultTime ? d.ultTime : '')}" required autofocus></label>
        <datalist id="f-esp-motivos"><option value="parente/família decidir"><option value="cliente pediu para chamar depois"><option value="cliente mandar os dados"><option value="dia do pagamento do cliente"></datalist>
        <label>Até <input type="date" name="ate" min="${amanhaC}" value="${amanhaC}" required></label>
        <div class="f-prox-bts">${[1, 2, 3, 7].map((n) => `<button type="button" class="btn btn-ghost btn-sm" data-espera-dias="${n}">${n === 1 ? 'amanhã' : `+${n} dias`}</button>`).join('')}</div>
        <span class="f-nota">Sai do Live e da contagem até o dia, às 9h (aparece em "Acompanhando"). Se o cliente escrever antes, volta na hora. No Chatwoot: nota e conversa adiada até o dia. A Mari continua calada.</span>
        <div class="f-prox-bts"><button type="submit" class="btn btn-acc btn-sm">Aguardar</button><button type="button" class="btn btn-ghost btn-sm" data-f="cancelar">Cancelar</button></div></form>` : '';
    const at = [];
    if (bo && !silenciada) at.push(NG.botaoOperador({ conversaId: c.id }, '⌖ Consultar viabilidade e crédito'));   // 13/11: atalho do operador
    if (bo && !silenciada && (dono.tipo === 'pessoa' || dono.tipo === 'time')) at.push('<button type="button" class="btn btn-ghost btn-sm" data-momento="devolver_mari">Devolver para a Mari</button>');
    if (bo && !c.nao_contatar && c.chatwoot_conversation_id) at.push('<button type="button" class="btn btn-ghost btn-sm" data-momento="parar">Cliente pediu para parar</button>');
    // 0100: Saída e Silenciar (conversa sem venda) · Reativar quando silenciada.
    if (bo && silenciada) at.unshift('<button type="button" class="btn btn-sm" data-csaida="reativar">🔔 Reativar</button>');
    else if (bo && !c.nao_contatar) {
      at.unshift('<button type="button" class="btn btn-sm" data-csaida="suporte_nio" title="Cliente Nio pedindo suporte ou reclamando: não é venda. A Mari cala e ele não volta para o Live.">📵 Cliente Nio · suporte — silenciar</button>');
      at.push('<button type="button" class="btn btn-ghost btn-sm" data-f="saida-form">Saída…</button>');   // 13/11 (4a): o mesmo formulário da venda (lead_sair)
    }
    at.push(`<a class="btn btn-ghost btn-sm" href="mari.html?conversa=${esc(c.id)}">Ver na tela Mari</a>`);
    const itens = Array.isArray(q.itens) ? q.itens.filter((x) => x.obrigatorio !== false) : [];
    const ESTADO = { validado: 'ok', coletado: 'meio', vazio: 'no' };
    const feito = feitoUltimo ? `<div class="f-feito${feitoUltimo.aviso ? ' warn' : ''}" role="status">${esc(feitoUltimo.resumo)}${feitoUltimo.aviso ? `<span>${esc(feitoUltimo.aviso)}</span>` : ''}</div>` : '';
    const k = d.cad.k;
    const viabC = c.nio_viab_resultado;
    const passosConv = [
      { nome: 'Viabilidade', s: viabC === 'viavel' ? 'ok' : ['sem_viabilidade', 'nao_encontrado', 'posse'].includes(viabC) ? 'wa' : 'no', d: viabC ? (viabC === 'viavel' ? 'portal · ok' : (NG.VIAB_NIO[viabC] || viabC).toLowerCase()) : '' },
      { nome: 'Crédito', s: 'no', d: '' }, { nome: 'Biometria', s: 'no', d: '' }, { nome: 'Pedido (OS)', s: 'no', d: '' }, { nome: 'Instalação', s: 'no', d: '' },
    ];
    const travasC = [q.trava_cliente_nio === 'bloqueia' && 'já é cliente Nio', q.trava_endereco_nio === 'bloqueia' && 'endereço com Nio', q.trava_viabilidade === 'bloqueia' && 'sem viabilidade'].filter(Boolean);
    // 0147: destino único + etapa; alerta quando alguém agiu direto no Chatwoot.
    const fn = d.fnome || { etapa: {}, destino: {} };
    const linhaFunil = `<span class="f-nota">${c.funil_destino && c.funil_destino !== 'em_andamento' ? `${c.funil_destino === 'instalada' ? '✅' : '⛔'} Destino: <b>${esc(fn.destino[c.funil_destino] || c.funil_destino)}</b>${c.funil_detalhe ? ` (${esc(c.funil_detalhe)})` : ''} · ` : ''}Etapa: <b>${esc(fn.etapa[c.funil_etapa] || c.funil_etapa || '—')}</b></span>`
      + (c.funil_alerta ? `<span class="f-nota warn">⚠ ${esc(NG.FUNIL_ALERTA[c.funil_alerta] || c.funil_alerta)}. ${c.funil_alerta === 'resolvida_fora_niogen' ? 'Use Saída ▾ abaixo.' : 'O atendimento é só pelo NIOGEN.'}</span>` : '');
    const corpoPasso = `${linhaFunil}${silenciada ? '<span class="f-nota">📵 Silenciada (cliente Nio · suporte): a Mari não responde e ela não volta para o Live, mesmo se ele escrever. "Reativar" desfaz.</span>' : ''}
          ${dono.tipo === 'mari' && nivel !== 'agora' && !silenciada ? '<span class="f-nota">Não precisa fazer nada. Se quiser entrar, assuma antes de escrever.</span>' : ''}
          ${emEspera && !silenciada ? `<span class="f-nota">⏸ Em espera até ${esc(NG.fmtData(c.espera_ate))} · ${esc(c.espera_motivo || '')}. Volta para o Live no dia, ou antes se o cliente escrever.</span>` : ''}
          ${bts.length ? `<div class="f-prox-bts">${bts.join('')}</div>` : ''}
          ${formEspera}${formAtivo === 'saida' ? `<div class="f-prox-form">${FORMS.saida()}</div>` : ''}
          ${sozinho ? `<span class="f-sozinho">O NIOGEN faz sozinho: ${esc(sozinho)}</span>` : ''}
          <div class="f-atalhos">${at.join('')}</div>`;
    return { c, j, q, dono, nivel, silenciada, emEspera, corpoPasso, itens, ESTADO, feito, k, passosConv, travasC };
  }
  function renderConversa() {
    const vivo = cvComp && convAberta ? raiz.querySelector('.f-conv-host > .cvp-raiz') : null;
    const focoAntes = document.activeElement;
    const devolverRolagem = guardarRolagemConv(vivo);
    const { c, j, q, dono, nivel, silenciada, corpoPasso, itens, ESTADO, feito, k, passosConv, travasC } = conversaPartes();
    raiz.innerHTML = `<div class="ficha f-${modo}${largo ? ' f-largo' : ''}${convAberta && !hostConversa ? ' conv-on' : ''}">
      ${painelConversa()}
      <header class="f-cab"><div class="f-linha1"><div class="f-nome"><h2>${esc(c.nome)}</h2>${linhaPlano(q.plano_nome || c.plano_escolhido, null, null)}</div><div class="f-ctl">${botaoVoltar()}${modo !== 'pagina' ? '<button type="button" class="g-fechar" data-f="fechar" aria-label="Fechar a ficha">×</button>' : ''}</div></div>
        <div class="f-local">${linkConversa()}${chipsConversa(c)}<span class="f-local-txt">${esc([c.cidade, NG.ORIGENS[c.origem] || c.origem].filter(Boolean).join(' · ') || '—')}</span></div></header>
      <div class="f-corpo"><div class="f-col-a">
        ${regua(passosConv)}
        ${quadroPasso('conversa', silenciada ? 'dim' : (NIVEL_CLS[nivel] || 'dim'), silenciada ? 'SILENCIADA' : (NIVEL_ROT[nivel] || 'PRÓXIMO PASSO'),
          silenciada ? 'Cliente Nio · suporte — fora do Live' : (j.o_que_fazer || 'Mari atendendo'), corpoPasso, formAtivo === 'conv_espera' || formAtivo === 'saida')}${feito}
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
    reporConversa(vivo, focoAntes, devolverRolagem);
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

  // quieto (10/11): recarga automática (eco da conversa, refresh de 60 s do Live) — só redesenha se o dado mudou e nunca
  // por cima de um formulário aberto (não apaga o que a pessoa está digitando).
  let sigDados = '';
  async function recarregar(op) {
    if (!idAtual) return;
    const quieto = !!(op && op.quieto);
    if (quieto && (formAtivo || edicao)) return;
    const id = idAtual;
    const ehConv = String(id).startsWith('c:');
    const fresco = !quieto && !(op && op.abrindo);   // depois de ação: dado fresco; ao abrir ou no eco, o que já está em memória
    const r = ehConv ? await carregarConversa(id.slice(2), fresco) : await carregar(id, fresco);
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
      const ed = ev.target.closest('[data-espera-dias]');
      if (ed) { const i = ed.form && ed.form.querySelector('[name="ate"]'); if (i) i.value = NG.somaDias(NG.diaSP(), Number(ed.dataset.esperaDias)); return; }
      const ce = ev.target.closest('[data-cespera]');
      if (ce && d && d.soConversa) {
        if (!window.confirm('Retomar agora?\n\nA conversa volta para o Live e reabre no Chatwoot.')) return;
        ce.disabled = true;
        const ok = await rodarEsperaConversa(null, null);
        if (!ok && ce.isConnected) ce.disabled = false;
        return;
      }
      const cs = ev.target.closest('[data-csaida]');
      if (cs && d && d.soConversa) {
        fecharMenus();
        cs.disabled = true;
        const res = await rodarSaidaConversa(cs.dataset.csaida);
        if (!res && cs.isConnected) cs.disabled = false;
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
      if (acao === 'fechar') { if (modo === 'cheia') fecharCheia(); else if (modo === 'lado') fecharLado(); else NG.gaveta.fechar(); return; }
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
      if (acao === 'pend-conf') { pendDescPreset = d.ultTime ? `Cliente confirmou: ${d.ultTime}` : null; formAtivo = 'pend_abrir'; render(); return; }
      if (acao === 'conv-espera') { formAtivo = formAtivo === 'conv_espera' ? null : 'conv_espera'; convEsperaFechado = formAtivo == null; passoAberto.add('conversa'); render(); return; }
      if (acao === 'saida-form') { formAtivo = formAtivo === 'saida' ? null : 'saida'; if (d.soConversa) passoAberto.add('conversa'); render(); return; }
      if (acao === 'reabrir') { await reabrirLead(b); return; }
      if (acao === 'auditar') {
        if (!NG.auditoria || !d.conversaId) { NG.toast('Auditoria indisponível nesta tela.', 'bad'); return; }
        b.disabled = true;
        await NG.auditoria.pedir(d.conversaId);
        if (b.isConnected) b.disabled = false;
        return;
      }
      if (acao === 'fc-op-lead') {   // 0159: grava no lead sem venda o que o operador leu
        b.disabled = true;
        const { data, error } = await NG.sb.rpc('lead_registrar_consulta', { p_conversa: d.conversaId, p_tipo: b.dataset.t === 'viab' ? 'viabilidade' : 'credito', p_resultado: b.dataset.r });
        if (error) { NG.toast(NG.msgErro(error), 'bad'); if (b.isConnected) b.disabled = false; return; }
        NG.toast(data.resumo || 'Registrado no lead', 'ok');
        feitoUltimo = { resumo: data.resumo || '✓ registrado no lead' };
        fc.etapa = null;
        fc.op[b.dataset.t] = null;
        await recarregar();
        avisarOuvintes(data);
        return;
      }
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
        if (b.closest('.f-bloco')) edicao = null; else { if (formAtivo === 'conv_espera') convEsperaFechado = true; formAtivo = null; }
        saidaPreset = null;
        render();
        return;
      }
      if (acao === 'conf-tent-ok' || acao === 'conf-tent-nao') { b.disabled = true; await confTentativa(acao === 'conf-tent-ok'); return; }
      if (acao === 'conf-aprovar') { b.disabled = true; const ok = await gravar({ conferencia_status: 'aprovada' }, 'Conferência aprovada'); if (!ok && b.isConnected) b.disabled = false; return; }
      if (acao === 'conf-form-reprovar' || acao === 'conf-form-devolver') { formAtivo = acao === 'conf-form-reprovar' ? 'conf_reprovar' : 'conf_devolver'; render(); return; }
      if (acao === 'conf-gerar') { b.disabled = true; await confGerar(); return; }
      if (acao === 'conf-form-indevida') { formAtivo = 'conf_indevida'; render(); return; }
      if (acao === 'conf-desmarcar-indevida') { b.disabled = true; if (!(await confIndevida(false, null)) && b.isConnected) b.disabled = false; return; }
      if (acao === 'and-visto') {
        b.disabled = true;
        const { error } = await NG.sb.rpc('andamento_alerta_visto', { p_origem: b.dataset.origem, p_chave: b.dataset.chave });
        if (error) { NG.toast(NG.msgErro(error), 'bad'); b.disabled = false; return; }
        NG.toast('Alerta marcado como visto');
        await recarregar();
        return;
      }
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
      const sm = ev.target.closest('[data-saida-motivo]');
      if (sm) ajustarSaida(sm.form, false);
    });
  }

  // "Mover para…": os mesmos destinos e campos de NG.moverStatus, mas o formulário abre na ficha.
  async function mover(destino) {
    const v = d.v;
    if (destino === v.status) return;
    if (v.status === 'saida') { await reabrirLead(null); return; }   // 13/11 (4a): sair da Saída é sempre pela função (lead_reabrir)
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
  // 13/11: o título da aba leva o nome da tela de onde a ficha abriu (antes dizia "Live" em qualquer tela).
  const tituloCom = (nome) => `${nome || 'Contato'} · ${String(tituloOriginal || 'NIOGEN').replace(/^\(\d+\)\s*/, '')}`;

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
    if (modo === 'gaveta' && !fichaAntiga()) usarGlobal();   // 13/11 (4a): a ficha única no lugar da gaveta
    if (modo === 'cheia') {
      if (globalEl && raiz === globalEl) {
        if (!globalEl.classList.contains('open')) tituloOriginal = document.title;
        globalEl.classList.add('open');
        document.body.classList.add('fc-global-on');
      }
      if (idAtual !== id) { idAtual = id; d = null; abertos = null; edicao = null; formAtivo = null; convAberta = false; conv = null; feitoUltimo = null; passoAberto = new Set(); sigDados = ''; convEsperaFechado = false; pendDescPreset = null; credPreset = null; fc = novoFc();
        if (cvCheia) { cvCheia.destruir(); cvCheia = null; }
        raiz.innerHTML = '<div class="fc"><div class="fc-carregando">Carregando…</div></div>'; }
      await recarregar({ abrindo: true });
      return;
    }
    if (modo === 'lado') {
      if (idAtual !== id) { idAtual = id; d = null; abertos = null; edicao = null; formAtivo = null; convAberta = false; conv = null; feitoUltimo = null; detalhes = largo; passoAberto = new Set(); sigDados = ''; convEsperaFechado = false; pendDescPreset = null;
        raiz.innerHTML = '<div class="ficha f-lado"><div class="f-corpo"><div class="carregando">Carregando…</div></div></div>'; }
      ladoEl.hidden = false;
      document.body.classList.add('ficha-ao-lado');
      await recarregar({ abrindo: true });
      return;
    }
    garantirGaveta();
    if (idAtual !== id) {
      idAtual = id;
      d = null; abertos = null; edicao = null; formAtivo = null; convAberta = false; conv = null; feitoUltimo = null; detalhes = largo; passoAberto = new Set(); sigDados = ''; convEsperaFechado = false; pendDescPreset = null;
      raiz.innerHTML = '<div class="ficha f-gaveta"><div class="f-corpo"><div class="carregando">Carregando…</div></div></div>';
    }
    if (!gav.classList.contains('aberta')) {
      tituloOriginal = document.title;
      NG.gaveta.abrir(gav, { foco: false, aoFechar: aoFecharGaveta });
    }
    await recarregar({ abrindo: true });
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
    else if (idAtual) { empurrou = false; if (modo === 'cheia') fecharCheia(); else if (modo === 'lado') fecharLado(); else NG.gaveta.fechar(); }
  }
  window.addEventListener('popstate', sincronizar);
  window.addEventListener('hashchange', sincronizar);

  // Página cheia (venda.html?id=): o mesmo componente, sem gaveta.
  async function pagina(el, id) {
    if (id && !fichaAntiga()) { el.innerHTML = ''; paginaVolta = 'vendas.html'; usarGlobal(); await mostrar(id); return; }   // 13/11 (4a)
    modo = 'pagina';
    raiz = el;
    ligar(raiz);
    idAtual = id;
    if (!id) { raiz.innerHTML = '<div class="placeholder">Venda não informada. <a href="vendas.html">Voltar a Vendas</a></div>'; return; }
    await recarregar();
  }

  // 0090: ficha AO LADO (Live · Lista): a mesma ficha, sem gaveta, dentro de um elemento da tela.
  function lado(el) {
    modo = 'lado';
    ladoEl = el;
    raiz = el;
    ligar(raiz);
  }
  // Troca o modo (Live: Lista = ao lado · Quadro = gaveta) sem recarregar a página.
  function usarGaveta() {
    if (modo !== 'lado' && modo !== 'cheia') return;
    if (modo === 'cheia' && globalEl && raiz === globalEl) return;   // já está na ficha única por cima da tela
    if (idAtual) { if (modo === 'cheia') fecharCheia(); else fecharLado(); }
    if (!fichaAntiga()) { usarGlobal(); return; }
    modo = 'gaveta';
    raiz = gav ? gav.querySelector('.ficha-raiz') : null;
  }
  function usarLado() {
    if (!ladoEl || modo === 'lado') return;
    if (idAtual && gav && gav.classList.contains('aberta')) NG.gaveta.fechar();
    modo = 'lado';
    raiz = ladoEl;
  }

  // =====================================================================================================================
  // 12/11 — TELA CHEIA DO CLIENTE (Live redesenhada · docs/Prompt_live_redesenho_111126_2120.md · protótipo UXtiACpUJj9Fq7wdEUuqug)
  // A tela não rola: cabeçalho fixo · trilha das 5 etapas (o detalhe abre por baixo, na largura da etapa, com os operadores de
  // viabilidade e crédito) · duas metades: Conversa (NGConversa, com a faixa da Mari acima da caixa) | Ficha (card Agora com a
  // pendência na última linha · cards Cliente e Venda · "Ver tudo" por cima dos dois · conferências dentro do card Venda ·
  // Histórico por cima da metade). Tudo que abre ocupa o card mais próximo; nada empurra nada. Os dados são os mesmos da ficha
  // (carregar/carregarConversa), as ações são as mesmas (data-f / data-momento / data-resolver / SALVAR): só mudou o lugar.
  // Operadores = CONSULTA-SÓ: o resultado aparece na etapa e entra no Histórico como leitura; gravar só por "Registrar na venda".
  // =====================================================================================================================
  let cheiaOpts = {};      // { posicao: () => ({ i, n, prev, next }), aoNavegar(dir), aoConcluir() }
  let cvCheia = null;      // NGConversa montado na metade esquerda
  let credPreset = null;   // resultado do operador de crédito levado ao formulário "Gravar o crédito"
  const novoFc = () => ({ etapa: null, pend: false, ver: null, conf: false, hist: false, histF: 'tudo', menu: false, reg: false, cad: false, cadp: null, passo: false, op: {}, leituras: [], tr: null, aba: 'ficha', erros: null });
  let fc = novoFc();
  const pausa = (ms) => new Promise((r) => setTimeout(r, ms));
  const SVG = (p, cls = '') => `<svg class="fc-ic ${cls}" viewBox="0 0 24 24" aria-hidden="true">${p}</svg>`;
  const IC = {
    voltar: SVG('<path d="M19 12H5"/><path d="m11 18-6-6 6-6"/>'), cima: SVG('<path d="m18 15-6-6-6 6"/>'), baixo: SVG('<path d="m6 9 6 6 6-6"/>'),
    ok: SVG('<path d="M20 6 9 17l-5-5"/>'), mais: SVG('<path d="M5 12h.01"/><path d="M12 12h.01"/><path d="M19 12h.01"/>'),
    copiar: SVG('<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a1 1 0 0 1 1-1h10"/>'), x: SVG('<path d="M18 6 6 18"/><path d="m6 6 12 12"/>'),
    expandir: SVG('<path d="M15 3h6v6"/><path d="M9 21H3v-6"/><path d="m21 3-7 7"/><path d="m3 21 7-7"/>'), pausa: SVG('<path d="M9 5v14"/><path d="M15 5v14"/>'),
    hist: SVG('<path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/><path d="M12 7v5l3 2"/>'), play: SVG('<path d="m6 4 14 8-14 8Z"/>'),
    gira: SVG('<path d="M21 12a9 9 0 1 1-6.2-8.6"/>', 'fc-gira'), seta: SVG('<path d="M5 12h14"/><path d="m13 6 6 6-6 6"/>'),
  };
  const btCopiar = (val, rot) => (val ? `<button type="button" class="fc-cp" data-copiar="${esc(String(val))}" aria-label="Copiar ${esc(rot)}" title="Copiar ${esc(rot)}">${IC.copiar}</button>` : '<span></span>');
  const TOM = { agora: 'now', hoje: 'today', espera: 'wait', ok: 'ok', fora: 'mute' };
  const NIVEL_K = { agora: 'Agora', hoje: 'Hoje', espera: 'Aguardando', ok: 'Nada a fazer agora', fora: 'Fora da jornada' };

  // ---------- trilha das etapas ----------
  const ETAPAS_K = ['viab', 'cred', 'bio', 'os', 'inst'];
  function trilhaPassos(passos) {
    const iAtual = passos.findIndex((p) => p.s !== 'ok');
    return passos.map((p, i) => {
      const st = p.s === 'ok' ? 'done' : p.s === 'wa' ? 'wait' : i === iAtual ? (d.pend ? 'wait' : 'now') : 'todo';
      return { ...p, k: ETAPAS_K[i], st, segDone: p.s === 'ok' && passos[i + 1] && passos[i + 1].s === 'ok' };
    });
  }
  const linhaDet = (k, v) => `<div class="fc-dr"><span>${esc(k)}</span><b>${v}</b></div>`;
  const VIAB_ROT = { viavel: 'Viável', sem_viabilidade: 'Sem viabilidade', complemento_fora_lista: 'Unidade fora da lista do portal' };
  const CRED_ROT = { aprovado_todas: 'Aprovado — todas as formas', aprovado_cartao: 'Aprovado — só cartão', aprovado_parcial: 'Aprovado', negado: 'Negado',
    pedido_em_andamento: 'Já tem pedido em andamento', pendente: 'Pendente', nao_classificado: 'Não classificado', sem_viabilidade: 'Endereço sem viabilidade',
    complemento_fora_lista: 'Unidade fora da lista do portal', contato_repetido: 'Celular recusado pelo portal', email_invalido: 'E-mail recusado pelo portal — confira o e-mail do cliente (ex.: @uol.com.br)', erro_receita: 'Erro da Receita', erro: 'Erro na consulta' };
  const FORMA_OP = { BOLETO: 'boleto', CREDITO: 'cartão', DACC: 'débito automático' };
  // O que o operador precisa (venda: da ficha; conversa: o que a Mari coletou). Falta = selo no lugar do botão.
  function entradaOp(tipo) {
    const v = d.soConversa ? null : d.v;
    const x = d.soConversa ? ((d.conv && d.conv.dados) || {}) : {};
    const cep = NG.soDigitos(v ? v.cep : (x.cep_origem || (d.conv || {}).cep || ''));
    const numero = String(v ? v.numero || '' : x.numero || '').trim();
    const complemento = String(v ? v.complemento || '' : '').trim();
    const end = { cep, numero, complemento, opcao: '' };
    if (cep.length !== 8) return { falta: 'falta CEP' };
    if (!numero) return { falta: 'falta o número' };
    if (tipo === 'viab') return { end };
    const cpf = NG.soDigitos(v ? v.cliente_cpf_cnpj : x.cpf);
    if (cpf.length !== 11) return { falta: cpf.length === 14 ? 'CNPJ: consulte no portal' : 'falta CPF' };
    const cel = NG.soDigitos(v ? v.cliente_whatsapp : (d.conv || {}).telefone).replace(/^55(?=\d{10,11}$)/, '');
    if (![10, 11].includes(cel.length)) return { falta: 'falta o celular' };
    const email = String(v ? v.cliente_email || '' : x.email || '').trim();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return { falta: 'falta o e-mail' };
    return { end, cpf, contato: { celular: cel, email } };
  }
  function opResultado(tipo, s) {
    if (tipo === 'viab') {
      const rot = VIAB_ROT[s.resultado] || 'Não decidiu';
      const det = s.resultado === 'viavel' && s.velocidade ? `até ${s.velocidade}` : s.resultado in VIAB_ROT ? 'viabilidade oficial do portal' : (s.motivo || s.resultado || '—');
      return { rot, det, cls: s.resultado === 'viavel' ? 'ok' : s.resultado === 'sem_viabilidade' ? 'bad' : 'warn',
        registrar: ['viavel', 'sem_viabilidade'].includes(s.resultado) ? s.resultado : null };
    }
    const formas = s.formas_liberadas || [];
    let rot = CRED_ROT[s.resultado] || s.resultado || '—';
    if (s.resultado === 'aprovado_parcial' && formas.length) rot = `Aprovado — ${formas.map((f) => FORMA_OP[f] || f).join(', ')}`;
    const so = s.resultado === 'aprovado_cartao' || (s.resultado === 'aprovado_parcial' && formas.length === 1 && formas[0] === 'CREDITO');
    const reg = so ? 'so_cartao' : /^aprovado/.test(s.resultado || '') ? 'aprovado' : s.resultado === 'negado' ? 'negado' : s.resultado === 'pendente' ? 'pendente' : null;
    const disse = s.popup && s.popup.texto ? `o portal respondeu: "${String(s.popup.texto).trim()}"` : '';
    return { rot, det: disse || (s.motivo && !reg ? s.motivo : (s.endereco && s.endereco.origem === 'padrao' ? 'medido com o endereço padrão' : 'crédito do CPF no portal PAP')),
      cls: /^aprovado/.test(s.resultado || '') ? 'ok' : s.resultado === 'negado' || s.resultado === 'pedido_em_andamento' ? 'bad' : 'warn', registrar: reg };
  }
  function opPainel(tipo) {
    const bo = ehBO();
    if (!bo) return '';
    const e = entradaOp(tipo);
    const o = fc.op[tipo];
    const nome = tipo === 'viab' ? 'Operador de viabilidade' : 'Operador de crédito';
    let corpo = '';
    if (o && o.estado === 'rodando') {
      const s = o.s || {};
      const seg = Math.round((Date.now() - o.t0) / 1000);
      const txt = s.estado === 'fila' ? `na fila (posição ${s.posicao_fila || 1})` : s.etapa ? `etapa ${s.etapa} no portal` : 'abrindo o portal';
      corpo = `<div class="fc-op-run">${IC.gira}<span>${esc(txt)} · ${seg} s <small>(${tipo === 'viab' ? '~20–40 s' : '~30–40 s'})</small></span></div>`;
    } else if (o && o.estado === 'pronto') {
      const r = opResultado(tipo, o.s);
      const podeReg = r.registrar && !d.soConversa && d.v.status !== 'saida';
      const rLead = !d.soConversa || !bo || silenciadaConv() ? null : tipo === 'viab' ? (r.registrar === 'viavel' ? 'viavel' : null)
        : (['aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'pedido_em_andamento'].includes(o.s.resultado) ? o.s.resultado : null);
      corpo = `<div class="fc-op-res"><span class="fc-pill ${r.cls}">${esc(r.rot)}</span><small>${esc(r.det)} · lido ${esc(NG.fmtHora(o.em))} · não gravado</small></div>
        <div class="fc-op-bts">${podeReg ? `<button type="button" class="btn btn-sm btn-acc" data-f="fc-op-reg" data-t="${tipo}" data-r="${esc(r.registrar)}">Registrar na venda</button>` : ''}${rLead ? `<button type="button" class="btn btn-sm btn-acc" data-f="fc-op-lead" data-t="${tipo}" data-r="${esc(rLead)}">Registrar no lead</button>${NG.dicaTxt(NG.ajuda.lead_registrar)}` : ''}
        <button type="button" class="btn btn-sm" data-f="fc-op" data-t="${tipo}">Reconsultar</button></div>`;
    } else if (o && o.estado === 'erro') {
      corpo = `<div class="fc-op-res"><span class="fc-pill warn">${esc(o.erro)}</span></div><div class="fc-op-bts"><button type="button" class="btn btn-sm" data-f="fc-op" data-t="${tipo}">Tentar de novo</button>${tipo === 'viab' ? '' : ''}</div>`;
    } else if (e.falta) {
      corpo = `<div class="fc-op-res"><span class="fc-pill warn">${esc(e.falta)}</span><small>complete a ficha para rodar o operador</small></div>`;
    } else {
      corpo = `${tipo === 'cred' ? '<label class="fc-chk"><input type="checkbox" data-fc-autoriza> O titular autorizou a consulta do CPF</label>' : ''}
        <div class="fc-op-bts"><button type="button" class="btn btn-sm" data-f="fc-op" data-t="${tipo}">${IC.play}Rodar operador</button></div>`;
    }
    return `<div class="fc-op" data-fc-op="${tipo}"><span class="fc-src op">${esc(nome)}</span>${corpo}</div>`;
  }
  function atualizarOp(tipo) {
    const el = raiz && raiz.querySelector(`[data-fc-op="${tipo}"]`);
    if (el) el.outerHTML = opPainel(tipo);
  }
  // 13/11 (etapa 3): o degrau "OS aberta" (código instalacao) da Escada consulta a OS na Nio (Operador de OS) e responde num modal.
  // Mudou alguma coisa → recarrega a ficha (status, data, Live).
  const temOsNio = () => !!(d && !d.soConversa && d.v && ehBO() && /\d{8}/.test(String(d.v.nio_os || d.v.nio_pedido || '')));
  async function abrirOsModal() {
    if (!temOsNio()) return;
    const alvo = idAtual;
    const r = await NG.osModal(d.v.id, d.v.cliente_nome);
    if (r && r.mudou && idAtual === alvo) { NG.limparCache(); await recarregar(); }
  }
  async function rodarOp(tipo) {
    const e = entradaOp(tipo);
    if (e.falta) { NG.toast(e.falta, 'bad'); return; }
    if (tipo === 'cred') {
      const ck = raiz.querySelector('[data-fc-autoriza]');
      if (ck && !ck.checked) { NG.toast('Marque que o titular autorizou a consulta.', 'bad'); return; }
    }
    const alvo = idAtual;
    const t0 = Date.now();
    fc.op[tipo] = { estado: 'rodando', s: { estado: 'fila', posicao_fila: 0 }, t0 };
    atualizarOp(tipo);
    const tick = setInterval(() => { if (idAtual === alvo && fc.op[tipo] && fc.op[tipo].estado === 'rodando') atualizarOp(tipo); else clearInterval(tick); }, 1000);
    try {
      let s = tipo === 'viab' ? await NG.viabIniciar(e.end) : await NG.creditoIniciar({ cpf: e.cpf, autorizado: true, contato: e.contato, endereco: e.end });
      const fim = Date.now() + 4 * 60 * 1000;
      while (s && !['pronto', 'erro'].includes(s.estado)) {
        if (idAtual !== alvo) return;
        if (Date.now() > fim) throw new Error('o portal demorou demais — tente de novo em alguns minutos');
        fc.op[tipo] = { estado: 'rodando', s, t0 };
        await pausa(tipo === 'viab' ? 2000 : 3000);
        s = await NG.creditoStatus(s.job_id);
      }
      if (idAtual !== alvo) return;
      const em = new Date().toISOString();
      fc.op[tipo] = { estado: 'pronto', s: s || {}, em };
      const r = opResultado(tipo, s || {});
      fc.leituras.unshift({ em, tipo, rot: r.rot, det: r.det });
    } catch (err) {
      if (idAtual !== alvo) return;
      fc.op[tipo] = { estado: 'erro', erro: err.naoInstalado ? 'operador fora do ar — consulte direto no portal' : NG.msgErro(err) };
    } finally { clearInterval(tick); }
    atualizarOp(tipo);
  }

  // Detalhe de cada etapa (abre por baixo dela, na mesma largura).
  function etapaDetalhe(p) {
    const conv = !!d.soConversa;
    const v = conv ? {} : d.v;
    const a = d.andamento || {};
    const fonte = (t, op) => `<span class="fc-src${op ? ' op' : ''}">fonte: ${esc(t)}</span>`;
    const visto = (origem, chave) => `<button type="button" class="btn btn-sm" data-f="and-visto" data-origem="${origem}" data-chave="${esc(chave)}">Visto</button>`;
    let corpo = '';
    if (p.k === 'viab') {
      const r = conv ? d.conv.nio_viab_resultado : v.nio_viab_resultado;
      corpo = `${linhaDet('Resultado', r ? esc(NG.VIAB_NIO[r] || r) : 'não consultado')}
        ${!conv && r ? linhaDet('Quando', `${esc(v.nio_viab_em ? NG.fmtDataHora(v.nio_viab_em) : '—')} · ${NG.portalViavel(v) ? '<span class="ok-txt">válida (7 dias)</span>' : r === 'viavel' ? '<span class="warn-txt">vencida: consulte de novo</span>' : 'portal ≠ viável não nega a venda'}`) : ''}
        ${!conv && v.nio_viab_velocidade ? linhaDet('Velocidade', esc(v.nio_viab_velocidade)) : ''}
        ${!conv ? linhaDet('Pista do DFV', esc(pistaDfv(v).txt)) : ''}
        ${fonte(conv ? 'Mari / portal' : v.nio_viab_origem === 'manual' ? 'registrada à mão (portal PAP)' : v.nio_viab_origem ? `portal PAP · ${v.nio_viab_origem}` : 'portal PAP')}
        ${opPainel('viab')}
        ${!conv && v.status !== 'saida' && ehBO() ? `<div class="fc-op-bts"><a class="btn btn-sm" href="${NG.PORTAL_PAP_NOVO_PEDIDO}" target="_blank" rel="noopener" data-f="consultar-portal">Abrir o portal ↗</a><button type="button" class="btn btn-sm" data-f="viab-form">Registrar resultado à mão</button></div>` : ''}`;
    } else if (p.k === 'cred') {
      corpo = conv ? `${linhaDet('Resultado', 'ainda sem venda')}${opPainel('cred')}`
        : `${linhaDet('Resultado', esc(v.credito_resultado ? `${NG.CREDITO[v.credito_resultado]}${v.credito_em ? ` · ${NG.fmtDataHora(v.credito_em)}` : ''}` : 'não gravado'))}
        ${fonte('portal PAP (análise de crédito do Novo Pedido)')}${opPainel('cred')}`;
    } else if (p.k === 'bio') {
      corpo = conv ? linhaDet('Biometria', 'depois do crédito aprovado')
        : `${linhaDet('Biometria', esc(NG.BIOMETRIA[v.biometria_status] || NG.BIOMETRIA.nao_enviada))}
        ${v.biometria_link_enviado_em ? linhaDet('Link da Nio', esc(NG.fmtDataHora(v.biometria_link_enviado_em))) : ''}
        ${v.biometria_validada_em ? linhaDet('Validada', esc(NG.fmtDataHora(v.biometria_validada_em))) : ''}
        ${a.bio_resultado ? linhaDet('GED360', `${esc(a.bio_rotulo || a.bio_resultado)} · protocolo ${esc(a.bio_protocolo)} · lido ${esc(NG.fmtDataHora(a.bio_lido_em))}`) : ''}
        ${a.bio_alerta ? `<div class="fc-op-bts"><span class="fc-pill warn">${esc(a.bio_alerta)}</span>${visto('ged360', a.bio_protocolo)}</div>` : ''}
        ${fonte(a.bio_resultado ? 'GED360' : 'portal PAP (Consulta OS)')}`;
    } else if (p.k === 'os') {
      corpo = conv ? linhaDet('Pedido (OS)', 'depois da biometria') : `${linhaDet('Nº do pedido (OS)', `<span class="mono">${esc(v.nio_os || v.nio_pedido || '—')}</span>${v.nio_os_em ? ` · ${esc(NG.fmtDataHora(v.nio_os_em))}` : ''}`)}
        ${a.portal_status ? linhaDet('Portal', `${esc(a.portal_rotulo || a.portal_status)} · desde ${esc(NG.fmtDataHora(a.portal_desde))} · lido ${esc(NG.fmtDataHora(a.portal_lido_em))}`) : ''}
        ${a.portal_alerta ? `<div class="fc-op-bts"><span class="fc-pill warn">${esc(a.portal_alerta)}</span>${visto('portal', a.portal_pedido)}</div>` : ''}
        ${fonte('portal PAP')}`;
    } else {
      corpo = conv ? linhaDet('Instalação', 'depois do pedido') : `${linhaDet('Agendada', esc(v.instalacao_agendada_para ? `${diaSemanaData(v.instalacao_agendada_para)} · ${NG.janela(v.instalacao_agendada_para)}` : '—'))}
        ${linhaDet('Instalada', esc(v.instalado_em ? NG.fmtDataHora(v.instalado_em) : '—'))}
        ${linhaDet('OSAB', esc(v.nio_situacao || '—'))}
        ${v.nio_pendencia_cod || v.nio_pendencia_desc ? linhaDet('Pendência Nio', `<span class="warn-txt">${esc([v.nio_pendencia_cod, v.nio_pendencia_desc].filter(Boolean).join(' · '))}</span>`) : ''}
        ${linhaDet('Documentos', esc(v.docs_dispensados_em ? 'dispensados (venda remota)' : v.docs_entregues_em ? `entregues ${NG.fmtData(v.docs_entregues_em)}` : v.docs_prazo_em ? `até ${NG.fmtData(v.docs_prazo_em)} (15 dias)` : '—'))}
        ${fonte('portal PAP · OSAB da Nio')}`;
    }
    return `<div class="fc-pop" role="dialog" aria-label="${esc(p.nome)}"><div class="fc-pop-h"><b>${esc(p.nome)}</b><small>${esc(p.d || '')}</small>
      <button type="button" class="fc-x" data-f="fc-etapa" data-k="${p.k}" aria-label="Fechar">${IC.x}</button></div>${corpo}</div>`;
  }
  function trilhaHtml(passos) {
    const L = trilhaPassos(passos);
    return `<nav class="fc-rail" aria-label="Etapas da venda">${L.map((p) => {
      const o = fc.op[p.k] && fc.op[p.k].estado === 'rodando';
      const st = o ? 'run' : p.st;
      const ic = st === 'done' ? IC.ok : st === 'now' ? '<span class="fc-rdot"></span>' : st === 'wait' ? IC.pausa : st === 'run' ? IC.gira : '';
      return `<div class="fc-rs r-${st}${p.segDone ? ' seg-ok' : ''}">
        <button type="button" class="fc-rb${fc.etapa === p.k ? ' on' : ''}" data-f="fc-etapa" data-k="${p.k}" aria-expanded="${fc.etapa === p.k}">
          <span class="fc-ri">${ic}</span><span class="fc-rt"><b>${esc(p.nome)}</b><small title="${esc(p.d || '')}">${esc(o ? 'rodando operador…' : p.d || (st === 'now' ? 'agora' : '—'))}</small></span></button>
        ${fc.etapa === p.k ? etapaDetalhe(p) : ''}</div>`;
    }).join('')}</nav>`;
  }

  // ---------- 13/11 (etapa 4a): as três trilhas no topo — escada (v_leads) · OS (o que a venda já tem) · dinheiro (v_dinheiro) ----------
  const VEZ_ROT = { mari: 'Mari', time: 'nosso time', cliente: 'cliente', nio: 'Nio' };
  const DIN_PASSOS = [['prevista', 'Prevista'], ['em_risco', 'Em risco'], ['firme', 'Firme'], ['no_extrato', 'No extrato'], ['paga', 'Paga']];
  const DIN_ROT = { em_risco: 'Em risco', firme: 'Firme', no_extrato: 'No extrato', paga: 'Paga', estornada: 'Estornada', contestada: 'Contestada' };
  const DIN_CLS = { em_risco: 'warn', firme: 'ok', no_extrato: 'ok', paga: 'ok', estornada: 'bad', contestada: 'warn' };
  // No celular o rótulo abre e fecha a trilha (fechada = uma linha com o estado atual); no computador ela fica sempre aberta.
  const trK = (k, rot, ajuda) => `<span class="fc-tr-k"><button type="button" class="fc-tr-tg" data-f="fc-tr" data-k="${k}" aria-expanded="${fc.tr === k}">${esc(rot)}</button>${NG.dicaTxt(ajuda)}</span>`;
  const silenciadaConv = () => !!(d.soConversa && d.conv && d.conv.quadro_encerrada_motivo === 'suporte_nio');
  // 13/11 (Ricardo: "o olho cansa", "foco no que a tela está pedindo"): no topo fica SÓ a escada, em uma linha. O status, a vez
  // e o prazo vão para o cartão Agora (o único lugar que diz o que fazer); a OS vira a lista vertical do cartão Venda e o
  // dinheiro, uma linha discreta no pé dele. Nada se repete.
  // 13/11 (Ricardo): no fim da Escada, o PAGAMENTO da comissão pela Nio. Não é um 7º degrau do funil (não entra na conta do
  // Funil nem do Painel): só mostra o estado da trilha do dinheiro. Cinza = antes de instalar · amarelo = aguardando ·
  // verde = paga · vermelho = estornada. O clique abre o detalhe do Dinheiro (valores e datas), que já existia.
  const PG_TXT = { em_risco: 'aguardando — ainda dentro do prazo em que a Nio pode estornar', firme: 'aguardando — firme, esperando o extrato da Nio',
    no_extrato: 'aguardando — já está no extrato da Nio, falta o pagamento', contestada: 'aguardando — contestada com a Nio', paga: 'paga pela Nio', estornada: 'estornada pela Nio' };
  function pagamentoItem() {
    const x = d && !d.soConversa ? d.din : null;
    const e = x ? x.estado : null;
    const cor = e === 'paga' ? 'ok' : e === 'estornada' ? 'bad' : e ? 'warn' : 'off';
    const dica = `Pagamento da comissão pela Nio: ${e ? (PG_TXT[e] || e) : 'a comissão nasce quando a Nio instala'}.${e ? ' Clique para ver os valores e as datas.' : ''}`;
    const ic = cor === 'ok' ? IC.ok : cor === 'bad' ? IC.x : '';
    return e
      ? `<button type="button" class="fc-es fc-es-pg pg-${cor}" data-f="fc-etapa" data-k="din" title="${esc(dica)}"><i>${ic}</i>Pagamento</button>`
      : `<span class="fc-es fc-es-pg pg-off" title="${esc(dica)}"><i></i>Pagamento</span>`;
  }
  function escadaPartes(semNome) {
    const l = d.lead;
    const A = NG.ajuda;
    const etapas = (d.leadCfg || []).filter((x) => x.tipo === 'etapa');
    if (!l || !etapas.length) return null;
    const fora = l.destino === 'saida' || l.destino === 'teste_duplicada';
    const iAt = etapas.findIndex((e) => e.codigo === (fora ? l.etapa_parou || l.etapa : l.etapa));
    const steps = etapas.map((e, i) => {
      const st = l.destino === 'instalada' || i < iAt ? 'done' : i === iAt ? (fora ? 'stop' : 'now') : 'todo';
      if (e.codigo === 'instalacao' && temOsNio()) {
        return `<button type="button" class="fc-es fc-es-os s-${st}" data-f="fc-os-ler" title="${esc(`${e.ajuda || ''} Clique para consultar esta OS agora na Nio (uns 15 segundos).`.trim())}"><i>${st === 'done' ? IC.ok : st === 'stop' ? IC.x : ''}</i>${esc(e.nome)}<span class="fc-es-g" aria-hidden="true">⟳</span></button>`;
      }
      return `<span class="fc-es s-${st}" title="${esc(e.ajuda || '')}"><i>${st === 'done' ? IC.ok : st === 'stop' ? IC.x : ''}</i>${esc(e.nome)}</span>`;
    }).join('') + pagamentoItem();
    const cv = d.soConversa ? d.conv : d.convInfo;
    const alerta = cv && cv.funil_alerta ? `<span class="fc-pill warn">⚠ ${esc(NG.FUNIL_ALERTA[cv.funil_alerta] || cv.funil_alerta)}</span>${NG.dicaTxt(A.ficha_fora)}` : '';
    let info;
    let curto;
    let reabrir = '';
    if (fora) {
      const parou = (etapas.find((e) => e.codigo === l.etapa_parou) || {}).nome;
      const nome = l.saida_nome || (l.destino === 'teste_duplicada' ? 'Teste ou duplicada' : 'sem motivo');
      const sub = l.saida_sub && !String(l.saida_sub).toLowerCase().startsWith(nome.toLowerCase()) ? l.saida_sub : '';
      curto = `Saída · ${nome}`;
      info = `${semNome ? '' : `<span>Saída: <b>${esc(nome)}</b>${sub ? ` · ${esc(sub)}` : ''}</span>`}${l.saida_ajuda ? NG.dicaTxt(l.saida_ajuda) : ''}${parou ? `<span>${semNome ? '' : '· '}parou em ${esc(parou)}</span>` : ''}${l.volta_em ? `<span>· volta ${esc(NG.fmtDiaISO(l.volta_em))}</span>` : ''}`;
      if (ehBO() && !silenciadaConv()) reabrir = `<span class="fc-reab"><button type="button" class="btn btn-sm" data-f="reabrir">Reabrir</button>${NG.dicaTxt(A.saida_reabrir)}</span>`;
    } else if (l.destino === 'instalada') {
      const canc = d.din && d.din.cancelada_apos_instalar_em;
      curto = canc ? 'Instalada · cancelada depois' : 'Instalada';
      info = canc ? `<span class="fc-pill bad">cancelada depois de instalar em ${esc(NG.fmtData(canc))}</span>` : '';
    } else {
      const prazo = l.prazo_em ? `<span class="${l.atrasado ? 'bad-txt' : ''}">· prazo ${esc(NG.fmtDiaSemana(l.prazo_em))} ${esc(NG.fmtHora(l.prazo_em))}${l.atrasado ? ' · atrasado' : ''}</span>` : '';
      curto = `${l.etapa_nome || ''} · vez: ${VEZ_ROT[l.vez] || '—'}${l.atrasado ? ' · atrasado' : ''}`;
      info = `<span>${esc(l.status_nome || l.status || '—')}</span>${l.status_ajuda ? NG.dicaTxt(l.status_ajuda) : ''}<span>· vez: <b class="fc-vez v-${esc(l.vez || '')}">${esc(VEZ_ROT[l.vez] || '—')}</b></span>${l.vez && A.vez[l.vez] ? NG.dicaTxt(A.vez[l.vez]) : ''}${prazo}
        ${l.em_espera && !d.pend ? `<span class="fc-pill pend">${IC.pausa}em espera${l.espera_revisar_em ? ` até ${esc(NG.fmtData(l.espera_revisar_em))}` : ''}</span>` : ''}`;
    }
    return { steps, curto, info: `${info}${alerta}`, reabrir, etapaNome: l.etapa_nome || '' };
  }
  function escadaHtml() {
    const E = escadaPartes();
    const A = NG.ajuda;
    if (!E) return `<div class="fc-tr fc-tr-esc">${trK('esc', 'Escada', A.tr_escada)}<span class="fc-tr-curto">sem leitura</span><div class="fc-es-l"><span class="apagado">sem leitura da escada para este lead</span></div></div>`;
    return `<div class="fc-tr fc-tr-esc${fc.tr === 'esc' ? ' on' : ''}">${trK('esc', 'Escada', A.tr_escada)}<span class="fc-tr-curto">${esc(E.curto)}</span><div class="fc-es-l">${E.steps}</div></div>`;
  }
  // OS na vertical, dentro do cartão Venda: os 5 passos de sempre; o clique abre o detalhe (e o operador) por cima dos cartões.
  function osLista(passos) {
    return `<div class="fc-os-v"><div class="fc-os-h"><span>Pedido na Nio</span>${NG.dicaTxt(NG.ajuda.tr_os)}</div>${trilhaPassos(passos).map((x) => {
      const o = fc.op[x.k] && fc.op[x.k].estado === 'rodando';
      const st = o ? 'run' : x.st;
      const ic = st === 'done' ? IC.ok : st === 'now' ? '<span class="fc-rdot"></span>' : st === 'wait' ? IC.pausa : st === 'run' ? IC.gira : '';
      return `<button type="button" class="fc-ov r-${st}${fc.etapa === x.k ? ' on' : ''}" data-f="fc-etapa" data-k="${x.k}" aria-expanded="${fc.etapa === x.k}">
        <span class="fc-ri">${ic}</span><b>${esc(x.nome)}</b><small title="${esc(x.d || '')}">${esc(o ? 'rodando operador…' : x.d || (st === 'now' ? 'agora' : '—'))}</small></button>`;
    }).join('')}</div>`;
  }
  // Dinheiro: uma linha discreta no pé do cartão Venda. Depois de instalada ela ganha cor e o clique abre os estados e as datas.
  function dinLinha() {
    const A = NG.ajuda;
    const bo = ehBO();
    const m = NG.fmtMoeda;
    const v = d.soConversa ? null : d.v;
    const x = d.soConversa ? null : d.din;
    if (!x) {
      const fora = v && v.status === 'saida';
      return `<div class="fc-din-w"><div class="fc-din-l"><span>Dinheiro</span><span class="fc-din-t">${fora ? 'fora da jornada — sem comissão'
        : `${bo && v && v.comissao_prevista != null ? `<b>${esc(m(v.comissao_prevista))}</b> na instalação` : 'nasce na instalação'}`}</span></div>${fora ? '' : NG.dicaTxt(`${A.tr_dinheiro} ${A.din_antes}`)}</div>`;
    }
    const estado = x.estado;
    const prox = estado === 'em_risco' ? (x.cancelada_apos_instalar_em ? 'cancelada depois de instalar' : `estorno até ${NG.fmtData(x.risco_ate)}`)
      : estado === 'firme' ? 'aguardando o extrato' : estado === 'no_extrato' ? `contestar até ${NG.fmtData(x.contestar_ate)}` : '';
    return `<div class="fc-din-w"><button type="button" class="fc-din-l${fc.etapa === 'din' ? ' on' : ''}" data-f="fc-etapa" data-k="din" aria-expanded="${fc.etapa === 'din'}" title="Ver os estados e as datas">
      <span>Dinheiro</span><span class="fc-pill ${DIN_CLS[estado] || 'mute'}">${esc(DIN_ROT[estado] || estado)}</span><span class="fc-din-t">${bo ? `<b>${esc(m(x.previsto_total))}</b>` : ''}${prox ? `${bo ? ' · ' : ''}${esc(prox)}` : ''}</span></button>${NG.dicaTxt(`${A.tr_dinheiro} ${A.din_estados[estado] || ''}`)}</div>`;
  }
  function dinDet() {
    const x = d.din;
    const bo = ehBO();
    const m = NG.fmtMoeda;
    const estado = x.estado;
    const fim = ['estornada', 'contestada'].includes(estado);
    const iAt = fim ? 3 : DIN_PASSOS.findIndex(([k]) => k === estado);
    const steps = DIN_PASSOS.map(([, rot], i) => {
      const st = i < iAt || estado === 'paga' ? 'done' : i === iAt ? (estado === 'estornada' ? 'stop' : 'now') : 'todo';
      return `<span class="fc-es s-${st}"><i>${st === 'done' ? IC.ok : st === 'stop' ? IC.x : ''}</i>${esc(rot)}</span>`;
    }).join('');
    return `<div class="fc-pop" role="dialog" aria-label="Dinheiro desta venda"><div class="fc-pop-h"><b>Dinheiro desta venda</b><small>${esc(DIN_ROT[estado] || '')}</small>
        <button type="button" class="fc-x" data-f="fc-etapa" data-k="din" aria-label="Fechar">${IC.x}</button></div>
      <div class="fc-es-l fc-es-din">${steps}</div>
      ${linhaDet('Ativada em', esc(NG.fmtData(x.ativada_em)))}
      ${bo ? linhaDet('Previsto', `${esc(m(x.prevista))} de comissão${Number(x.bonus_previsto || 0) ? ` + ${esc(m(x.bonus_previsto))} de bônus` : ''}`) : ''}
      ${bo ? linhaDet('No extrato', Number(x.no_extrato || 0) ? `${esc(m(x.no_extrato))}${Number(x.diferenca || 0) ? ` <span class="${Number(x.diferenca) < 0 ? 'bad-txt' : 'ok-txt'}">(${Number(x.diferenca) > 0 ? '+' : ''}${esc(m(x.diferenca))} contra o previsto)</span>` : ''}` : 'ainda não lançado') : ''}
      ${bo && Number(x.estornado || 0) ? linhaDet('Estornado', `<span class="bad-txt">${esc(m(x.estornado))}</span>`) : ''}
      ${bo && Number(x.multas || 0) ? linhaDet('Multas', `<span class="bad-txt">${esc(m(x.multas))}</span>`) : ''}
      ${bo && Number(x.pago || 0) ? linhaDet('Pago', esc(m(x.pago))) : ''}
      ${linhaDet('Estorno de 100 %', `até ${esc(NG.fmtData(x.risco_ate))} (cancelar e reativar)`)}
      ${linhaDet('Estorno parcial', `até ${esc(NG.fmtData(x.downgrade_ate))} (plano menor)`)}
      ${linhaDet('Contestar', `até ${esc(NG.fmtData(x.contestar_ate))}`)}
      ${linhaDet('M-10', `apura em ${esc(NG.fmtData(x.m10_em))}${bo && Number(x.bonus_m10_potencial || 0) ? ` · até ${esc(m(x.bonus_m10_potencial))}` : ''}`)}
      ${linhaDet('Documentos', esc(d.v && d.v.docs_dispensados_em ? 'dispensados (venda remota)' : x.docs_entregues_em ? `entregues ${NG.fmtData(x.docs_entregues_em)}` : `até ${NG.fmtData(x.docs_ate)}`))}
      <span class="fc-src">fonte: tabela de comissão (previsto) · extrato da Nio (real)</span></div>`;
  }
  // Detalhe de um passo da OS ou do dinheiro: abre por cima dos dois cartões (nada empurra nada).
  function etapaOver(passos) {
    if (fc.etapa === 'din') return d.din ? `<div class="fc-cards-over fc-etapa-over">${dinDet()}</div>` : '';
    const x = fc.etapa ? trilhaPassos(passos).find((y) => y.k === fc.etapa) : null;
    return x ? `<div class="fc-cards-over fc-etapa-over">${etapaDetalhe(x)}</div>` : '';
  }
  const trilhasHtml = () => `<div class="fc-trilhas">${escadaHtml()}</div>`;
  // Selo da conversa dentro da ficha (vinha no cabeçalho da gaveta): status no Chatwoot, janela de 24 h e etiquetas.
  const seloConv = (cv) => (!cv || !cv.chatwoot_conversation_id || !ehBO() ? ''
    : `<span class="fc-selo"><span class="fc-pill mute">${cv.chatwoot_status === 'resolved' ? 'Resolvida' : 'Aberta'}</span><span class="fc-pill mute">Janela ${esc(janelaTxt(cv))}</span>${(cv.chatwoot_etiquetas || []).slice(0, 3).map((e) => `<span class="fc-pill mute">${esc(e)}</span>`).join('')}${NG.dicaTxt(NG.ajuda.ficha_selo_conv)}</span>`);
  const auditarItem = () => (ehBO() && d.conversaId ? `<span class="fc-mlin"><button type="button" class="fc-mitem" data-f="auditar">🔎 Auditar esta conversa</button>${NG.dicaTxt(NG.ajuda.ficha_auditar)}</span>` : '');
  const pendHistHtml = () => {
    const hist = d.pendHist || [];
    if (!hist.length) return '';
    const nomeMot = (c) => ((d.motivos || []).find((x) => x.codigo === c) || {}).nome || c;
    return `<div class="fc-pend-hist"><span class="f-rot">Histórico de pendências ${NG.dicaTxt(NG.ajuda.pend_hist)}</span>${hist.slice(0, 6).map((h) => `<span><b>${esc(nomeMot(h.motivo))}</b> · ${esc(NG.fmtData(h.aberta_em))} → ${esc(NG.fmtData(h.encerrada_em))} · ${esc(NG.RESULTADO_PENDENCIA[h.resultado] || h.resultado)}${h.revisoes ? ` · adiada ${esc(h.revisoes)}×` : ''}${h.autor ? ` · ${esc(h.autor)}` : ''}</span>`).join('')}</div>`;
  };

  // ---------- cabeçalho ----------
  // 12/11 (Ricardo): o "Concluir" virou "✓ Nada a responder" — dispensa o aviso "Cliente escreveu · responder" quando foi só
  // despedida (0143: volta sozinho se o cliente escrever de novo) e abre o próximo. Ao lado, "📵 Silenciar" (conversa sem venda).
  function cabCheia(nome, chips, meta, menu, extra = '') {
    const pos = cheiaOpts.posicao ? cheiaOpts.posicao() : null;
    const naFila = !!cheiaOpts.posicao;   // fora da Live não há fila: só Voltar
    return `<header class="fc-top">
      <button type="button" class="btn" data-f="fc-voltar" title="${naFila ? 'Volta para a fila (Esc)' : 'Fecha a ficha (Esc)'}">${IC.voltar}${naFila ? 'Fila' : 'Voltar'}</button>
      <div class="fc-tit"><div class="fc-l1"><h1>${esc(nome)}</h1>${chips}</div><div class="fc-meta">${meta}</div></div>
      <div class="fc-nav">
        ${pos && pos.n ? `<span class="fc-pos">${pos.i ? `${pos.i} de ${pos.n} na sua vez` : `${pos.n} na sua vez`}</span>` : ''}
        <button type="button" class="btn fc-bi" data-f="fc-nav" data-dir="-1"${naFila ? '' : ' hidden'} aria-label="Cliente anterior da fila"${pos && pos.prev ? '' : ' disabled'}>${IC.cima}</button>
        <button type="button" class="btn fc-bi" data-f="fc-nav" data-dir="1"${naFila ? '' : ' hidden'} aria-label="Próximo cliente da fila"${pos && pos.next ? '' : ' disabled'}>${IC.baixo}</button>
        ${extra}<button type="button" class="btn btn-acc" data-f="fc-concluir"${naFila || (d.conversaId && ehBO()) ? '' : ' hidden'} title="Não há o que responder (ex.: o cliente só se despediu)? Tira o aviso &quot;Cliente escreveu · responder&quot; do Live e abre o próximo. Se ele escrever de novo, volta.">${IC.ok}Nada a responder</button>
        <div class="fc-menuw"><button type="button" class="btn fc-bi" data-f="fc-menu" aria-expanded="${fc.menu}" aria-label="Mais ações">${IC.mais}</button>
          ${fc.menu ? `<div class="fc-menu" role="menu">${menu}</div>` : ''}</div>
      </div></header>`;
  }
  const chipCopia = (rot, val, cls = '') => (val ? `<span class="fc-chip ${cls}"><span>${esc(rot)} ${esc(val)}</span>${btCopiar(NG.soDigitos(val) || val, rot)}</span>` : '');

  // ---------- Agora + pendência ----------
  function agoraHtml(tom, k, t, s, botao, pendHtml, info) {
    return `<div class="fc-agora ag-${tom}">
      <div class="fc-ag-main"><div class="fc-ag-txt"><div class="fc-ag-k">${esc(k)}</div>${info ? `<div class="fc-ag-i">${info}</div>` : ''}<div class="fc-ag-t" title="${esc(t)}">${esc(t || '—')}</div><div class="fc-ag-s" title="${esc(s || '')}">${esc(s || '')}</div></div>${botao}</div>
      ${pendHtml}</div>`;
  }
  function pendLinha(v) {
    const pe = d.pend;
    if (!pe) {
      const pode = ehBO() && v && ['0_qualificado', '1_vendido', '2_aguardando_instalacao', '3_instalado'].includes(v.status);
      const nH = (d.pendHist || []).length;
      return `<div class="fc-ag-pend none"><span>Sem pendência</span><span class="fc-sp"></span>${nH ? `<button type="button" class="fc-link" data-f="fc-pend" aria-expanded="${fc.pend}">Histórico (${nH})</button>` : ''}${pode ? '<button type="button" class="fc-link" data-f="pend-abrir">⏸ Abrir pendência</button>' : ''}</div>`;
    }
    return `<div class="fc-ag-pend"><button type="button" class="fc-pendbt" data-f="fc-pend" aria-expanded="${fc.pend}"><span class="fc-pill pend">${IC.pausa}pendência</span>
      <span class="fc-pt">${esc([pe.nome, pe.descricao, `revisar ${pe.diaTxt}`].filter(Boolean).join(' · '))}</span><span class="fc-pmore">Detalhes</span></button></div>`;
  }
  function pendOver() {
    const pe = d.pend;
    if (!fc.pend) return '';
    if (!pe) {
      if (!(d.pendHist || []).length) return '';
      return `<div class="fc-pend-over alto" role="dialog" aria-label="Histórico de pendências"><div class="fc-po-h"><b>Pendência</b><span class="fc-pill mute">nenhuma aberta</span><span class="fc-sp"></span>
        <button type="button" class="fc-x" data-f="fc-pend" aria-label="Fechar">${IC.x}</button></div>${pendHistHtml()}</div>`;
    }
    const pode = ehBO();
    const dias = pe.desde ? Math.max(0, Math.round((new Date(`${NG.diaSP()}T12:00:00-03:00`) - new Date(`${NG.diaSP(pe.desde)}T12:00:00-03:00`)) / 86400000)) : null;
    const nomeMot = (c) => ((d.motivos || []).find((m) => m.codigo === c) || {}).nome || c;
    const h = (d.pendHist || [])[0];
    const antes = h ? ` · antes: ${nomeMot(h.motivo)}, ${NG.fmtData(h.aberta_em)} → ${NG.fmtData(h.encerrada_em)}, ${(NG.RESULTADO_PENDENCIA[h.resultado] || h.resultado).toLowerCase()}${h.autor ? ` (${h.autor})` : ''}` : '';
    return `<div class="fc-pend-over${(d.pendHist || []).length ? ' alto' : ''}" role="dialog" aria-label="Pendência">
      <div class="fc-po-h"><b>Pendência</b><span class="fc-pill pend">${pe.vencida ? 'revisar hoje' : 'em espera'}</span><span class="fc-pill mute">Mari pausada</span>${pe.revisoes >= 2 ? `<span class="fc-pill warn">adiada ${pe.revisoes}×</span>` : ''}<span class="fc-sp"></span>
        ${pode ? `<button type="button" class="btn btn-sm${pe.vencida ? ' btn-acc' : ''}" data-f="pend-encerrar">Encerrar</button><button type="button" class="btn btn-sm" data-f="pend-adiar">Adiar</button>${pe.saida_sugerida ? `<button type="button" class="btn btn-sm" data-f="pend-saida" title="Confirmado? Encerrar como ${esc(pe.saida_sugerida)}">Saída: ${esc(pe.saida_sugerida)}</button>` : ''}` : ''}
        <button type="button" class="fc-x" data-f="fc-pend" aria-label="Fechar">${IC.x}</button></div>
      <div class="fc-pend-grid">
        <div><span>Motivo</span><b title="${esc(pe.nome)}">${esc(pe.nome)}</b></div>
        <div><span>Descrição</span><b title="${esc(pe.descricao || '')}">${esc(pe.descricao || '—')}</b></div>
        <div><span>Quem destrava</span><b>${esc(pe.quemTxt || '—')}</b></div>
        <div><span>Desde</span><b>${esc(`${NG.fmtDataHora(pe.desde)}${dias != null ? ` · ${dias} d parada` : ''}`)}</b></div>
        <div><span>Revisar</span><b class="${pe.vencida ? 'bad-txt' : ''}">${esc(pe.diaTxt)}</b></div></div>
      <div class="fc-po-f"><span title="${esc(`Avise o cliente uma vez, à mão (texto pronto no guia)${antes}`)}">Avise o cliente uma vez, à mão (texto pronto no guia)${esc(antes)}</span><a href="guia.html#pendencias" target="_blank" rel="noopener">Como funciona ↗</a></div>
      ${pendHistHtml()}
    </div>`;
  }

  // ---------- cards Cliente e Venda ----------
  const di = (k, v, cp, cls = '') => `<div class="fc-di"><span class="fc-dk">${esc(k)}</span><span class="fc-dv ${v ? cls : 'ph'}" title="${esc(v || '')}">${esc(v || '—')}</span>${cp && v ? btCopiar(v, k) : '<span></span>'}</div>`;
  function conferencias(v) {
    return [
      ['sem_produto', 'Não era cliente Nio', v.trava_sem_produto_ativo, 'viab'],
      ['cancel30', 'Sem cancelamento nos últimos 30 dias', v.trava_sem_cancelamento_30d, 'viab'],
      ['area', 'Dentro da área de atuação', v.trava_area, 'cli'],
      ['cobertura', 'Cobertura Nio no endereço', v.trava_cobertura, 'viab'],
      ['cpf', 'CPF/CNPJ válido', v.trava_cpf_valido, 'cli'],
      ['contato', 'Endereço e telefone confirmados', v.trava_contato_confirmado, 'cli'],
    ];
  }
  function textoWa(v) {
    const L = (rot, val) => (val ? `${rot}: ${val}` : null);
    const end = [v.logradouro, v.numero, v.complemento].filter(Boolean).join(', ');
    const cli = [L('Nome', v.cliente_nome), L('CPF/CNPJ', v.cliente_cpf_cnpj ? fmtDoc(v.cliente_cpf_cnpj) : ''), L('WhatsApp', v.cliente_whatsapp ? fmtTel(v.cliente_whatsapp) : ''),
      L('E-mail', v.cliente_email), L('Endereço', end), L('Bairro', v.bairro), L('Cidade', [v.cidade, v.uf].filter(Boolean).join('/')), L('CEP', v.cep ? NG.fmtCep(v.cep) : ''), L('Referência', v.ponto_referencia)].filter(Boolean);
    const valorAd = d.adics.reduce((s, a) => s + Number((a.config_adicionais || {}).preco || 0) * a.qtd, 0);
    const ven = [L('Plano', d.nomeCurto || v.plano_nome), L('Mensalidade', v.valor_mensal != null ? NG.fmtMoeda(Number(v.valor_mensal) + valorAd) : ''), L('Pagamento', FORMAS[v.forma_pagamento]),
      L('Pedido PAP', v.nio_os || v.nio_pedido), L('Biometria', v.biometria_status ? (NG.BIOMETRIA[v.biometria_status] || '').split(' (')[0] : ''),
      L('Instalação', v.instalado_em ? `instalada ${NG.fmtData(v.instalado_em)}` : v.instalacao_agendada_para ? `${diaSemanaData(v.instalacao_agendada_para)} · ${NG.janela(v.instalacao_agendada_para)}` : '')].filter(Boolean);
    return `*Cliente*\n${cli.join('\n')}${ven.length ? `\n\n*Venda*\n${ven.join('\n')}` : ''}`;
  }
  function cardsVenda(v) {
    const m = NG.fmtMoeda;
    const valorAd = d.adics.reduce((s, a) => s + Number((a.config_adicionais || {}).preco || 0) * a.qtd, 0);
    const end = [v.logradouro, v.numero, v.complemento].filter(Boolean).join(', ');
    const cf = conferencias(v);
    const nOk = cf.filter((x) => x[2] === true).length;
    const confBt = `<button type="button" class="fc-confb ${nOk === 6 ? 'ok' : 'warn'}${fc.conf ? ' on' : ''}" data-f="fc-conf" title="Conferências do contrato">${nOk}/6 conferências</button>`;
    const selos = [v.trava_contato_confirmado === true ? ['ok', 'contato confirmado ✓'] : ['warn', 'contato a confirmar'], v.trava_area === true ? ['ok', 'área ✓'] : v.trava_area === false ? ['bad', 'fora da área'] : null,
      v.segmento ? ['mute', SEGMENTOS[v.segmento] || v.segmento] : null].filter(Boolean);
    const cli = `<div class="fc-card"><div class="fc-card-h"><h3>Cliente</h3><span class="fc-sp"></span>
        <button type="button" class="fc-wa" data-f="fc-wa" title="Copia Cliente e Venda prontos para colar no WhatsApp (sem comissão)">${IC.copiar}WhatsApp</button>
        <button type="button" class="fc-icb" data-f="fc-ver" data-q="cli" aria-label="Ver todos os dados do cliente" title="Ver tudo">${IC.expandir}</button></div>
      <div class="fc-dl">${di('Nome', v.cliente_nome, true)}${di('CPF/CNPJ', v.cliente_cpf_cnpj ? fmtDoc(v.cliente_cpf_cnpj) : '', true, 'mono')}${di('WhatsApp', v.cliente_whatsapp ? fmtTel(v.cliente_whatsapp) : '', true, 'mono')}
        ${di('E-mail', v.cliente_email, true)}${di('Endereço', end, true)}${di('Bairro · cidade', [v.bairro, v.cidade].filter(Boolean).join(' · '), true)}${di('CEP', v.cep ? NG.fmtCep(v.cep) : '', true, 'mono')}${di('Referência', v.ponto_referencia, true)}
        <div class="fc-cstat">${selos.map(([c, t]) => `<span class="fc-pill ${c}">${esc(t)}</span>`).join('')}</div></div></div>`;
    const travas = [v.trava_sem_produto_ativo === false && 'já é cliente Nio', v.trava_sem_cancelamento_30d === false && 'cancelou < 30 d', v.trava_area === false && 'fora da área', v.trava_cobertura === false && 'sem cobertura'].filter(Boolean);
    const comissao = !ehBO() || v.status === 'saida' ? '' : v.comissao_paga != null ? `paga ${m(v.comissao_paga)}${v.ciclo_pago ? ` · ciclo ${v.ciclo_pago}` : ''}`
      : v.comissao_prevista != null ? `${m(v.comissao_prevista)} prevista${cicloPrevisto(v.instalado_em || v.instalacao_agendada_para) ? ` · ciclo ${cicloPrevisto(v.instalado_em || v.instalacao_agendada_para)}` : ''}` : '';
    const estorno = Number(v.estorno_previsto || 0) ? `${m(v.estorno_previsto)} previsto` : travas.length ? `risco: ${travas.join(', ')}` : 'sem risco';
    const inst = v.instalado_em ? `instalada ${NG.fmtData(v.instalado_em)}` : v.instalacao_agendada_para ? `${dataCurta(v.instalacao_agendada_para)} · ${periodoTxt(v)}` : '';
    const resumo = `<div class="fc-dl fc-venda-v">${osLista(passosVenda(v))}${dinLinha()}
        ${ehBO() && (travas.length || Number(v.estorno_previsto || 0)) ? `<div class="fc-di"><span class="fc-dk">Estorno</span><span class="fc-dv"><span class="fc-pill bad">${esc(estorno)}</span></span><span></span></div>` : ''}</div>`;
    const confHtml = `<div class="fc-full"><div class="fc-conf-intro">Conferências do contrato — é o que evita estorno e multa.</div>${cf.map(([k, rot, val, onde]) => `<div class="fc-cf">
        <span class="fc-cf-ic ${val === true ? 'ok' : val === false ? 'bad' : ''}">${val === true ? IC.ok : val === false ? IC.x : ''}</span>
        <span>${esc(rot)}<small>${val === true ? 'conferido' : val === false ? 'não passou — ver antes de seguir' : 'não verificado'}</small></span>
        ${val === true ? '<span></span>' : `<button type="button" class="btn btn-sm" data-f="fc-conferir" data-onde="${onde}" data-c="${k}">Conferir</button>`}</div>`).join('')}</div>`;
    const ven = `<div class="fc-card"><div class="fc-card-h"><h3>Venda</h3>${fc.conf ? '<button type="button" class="fc-link" data-f="fc-conf">← Resumo</button>' : ''}<span class="fc-sp"></span>${confBt}
        <button type="button" class="fc-icb" data-f="fc-ver" data-q="venda" aria-label="Ver todos os dados da venda" title="Ver tudo">${IC.expandir}</button></div>
      ${fc.conf ? confHtml : resumo}</div>`;
    return cli + ven;
  }
  // "Ver tudo": as seções do antigo acordeão, em duas colunas, por cima dos dois cards. Editar abre no mesmo espaço.
  function verTudo(v) {
    if (!fc.ver) return '';
    const ids = fc.ver === 'cli' ? ['cliente', 'endereco'] : ['plano', 'pedido', 'instalacao', 'comissao'];
    const bl = blocos(v).filter((b) => ids.includes(b.id));
    const sec = bl.map((b) => {
      const editando = edicao === b.id && b.editar;
      let corpo = editando ? b.editar() : b.corpo();
      if (!editando && b.id === 'pedido') corpo = corpo.split('<div class="f-sub">Conferências do contrato</div>')[0];
      if (!editando && b.id === 'comissao') corpo += linhaFaturas(v);
      return `<section class="fc-sec f-bloco${editando ? ' editando' : ''}" data-bloco="${b.id}"><div class="fc-sec-h"><h4>${esc(b.titulo)}</h4>
        ${!editando && b.editar ? `<button type="button" class="fc-link" data-f="editar">${esc(b.rotuloEditar || 'Editar')}</button>` : ''}</div>${corpo}</section>`;
    }).join('');
    const cf = conferencias(v);
    const nOk = cf.filter((x) => x[2] === true).length;
    return `<div class="fc-cards-over" role="dialog" aria-label="Dados completos">
      <div class="fc-card-h"><h3>${fc.ver === 'cli' ? 'Cliente · dados completos' : 'Venda · dados completos'}</h3><span class="fc-sp"></span>
        ${fc.ver === 'cli' ? `<button type="button" class="fc-wa" data-f="fc-wa">${IC.copiar}WhatsApp</button>` : `<button type="button" class="fc-confb ${nOk === 6 ? 'ok' : 'warn'}" data-f="fc-conf">${nOk}/6 conferências</button>`}
        <button type="button" class="fc-x" data-f="fc-ver-x" aria-label="Voltar ao resumo">${IC.x}</button></div>
      <div class="fc-full2">${sec}</div></div>`;
  }
  // Painel de ações do próximo passo (por cima dos cards): o corpo de sempre — botões, formulário, "faz sozinho", atalhos.
  function passoOver(v, p) {
    const formCartao = formAtivo && FORMS_NO_CARTAO.includes(formAtivo);
    const aberto = fc.passo || p.forcar || (!!formAtivo && formAtivo !== 'contato');
    if (!aberto) return '';
    const pend = formAtivo && formAtivo.startsWith('pend_');
    const extra = pend ? cartaoPendencia(v) : formCartao ? `<div class="f-form-solto">${FORMS[formAtivo](v)}</div>` : '';
    return `<div class="fc-cards-over fc-passo" role="dialog" aria-label="Próximo passo">
      <div class="fc-card-h"><h3>${esc(formAtivo === 'saida' ? TIT_SAIDA : p.alertaConv ? 'Conversa · agora' : NIVEL_ROT[p.nivel] || 'Próximo passo')}</h3><span class="fc-sp"></span><button type="button" class="fc-x" data-f="fc-passo-x" aria-label="Fechar">${IC.x}</button></div>
      <div class="fc-passo-corpo">
        ${v.status === 'saida' ? '' : NG.selosFicha(d.avisos, { ignorar: v.id })}
        ${extra || `${p.alertaConv ? `<div class="fc-passo-b"><b>${esc(p.jReal.o_que_fazer)}</b>${p.corpoConv}</div>` : ''}
        <div class="fc-passo-b">${formAtivo === 'saida' ? '' : `<b>${esc(p.texto || '—')}</b>`}${p.corpo}</div>${p.feito}
        ${cartaoConferencia(v)}${mostraCartoesPortal(v) ? cartaoPortal(v) : ''}`}
      </div></div>`;
  }

  // ---------- histórico ----------
  const KIND = { venda: 'Venda', conversa: 'Conversa', operador: 'Operadores', mari: 'Mari' };
  const KIND_EV = (t) => (t === 'contato' ? 'conversa' : ['dfv_consulta', 'portal_status', 'biometria_ged360', 'pedido_aberto_portal', 'portal_pedido_casado', 'biometria_validada', 'instalada_portal', 'osab', 'osab_venda_invalida', 'portal_dados_copiados'].includes(t) ? 'operador' : 'venda');
  function histItens() {
    const v = d.soConversa ? {} : d.v;
    const its = [];
    (d.eventos || []).forEach((e) => its.push({ em: e.criado_em, k: KIND_EV(e.tipo), html: eventoHtml(e, v) }));
    ((d.cad && d.cad.lista) || []).filter((t) => t.tags && t.tags.cadencia).forEach((t) => {
      const cod = t.tags.cadencia;
      its.push({ em: t.created_at, k: 'mari', html: `<div class="tl-item"><span class="tl-dot"></span><div class="tl-txt"><strong>Mari · lembrete ${esc(CAD_ROT[cod] && CAD_ROT[cod] !== cod ? `${CAD_ROT[cod]} (${cod})` : cod)}${t.tags.simulado ? ' (simulado)' : ''}</strong><span>${esc(NG.fmtDataHora(t.created_at))}${t.texto ? ` · ${esc(String(t.texto).slice(0, 160))}` : ''}</span></div></div>` });
    });
    const cvh = d.soConversa ? d.conv : d.convInfo;
    if (cvh && cvh.handoff_briefing && ehBO()) its.push({ em: cvh.handoff_em || new Date(0).toISOString(), k: 'mari', html: `<div class="tl-item"><span class="tl-dot"></span><div class="tl-txt"><strong>Mari · briefing do handoff${cvh.handoff_motivo ? ` (${esc(String(cvh.handoff_motivo).replace(/_/g, ' '))})` : ''} ${NG.dicaTxt(NG.ajuda.hist_briefing)}</strong><span>${cvh.handoff_em ? esc(NG.fmtDataHora(cvh.handoff_em)) : ''}</span><span class="fc-brief">${esc(cvh.handoff_briefing)}</span></div></div>` });
    (fc.erros || []).forEach((e) => its.push({ em: e.created_at, k: 'mari', html: `<div class="tl-item"><span class="tl-dot"></span><div class="tl-txt"><strong class="bad-txt">Erro da Mari${e.no_n8n ? ` · ${esc(e.no_n8n)}` : ''} ${NG.dicaTxt(NG.ajuda.hist_erros)}</strong><span>${esc(NG.fmtDataHora(e.created_at))} · ${esc(String(e.mensagem || '').slice(0, 240))}</span></div></div>` }));
    fc.leituras.forEach((l) => its.push({ em: l.em, k: 'operador', novo: true, html: `<div class="tl-item"><span class="tl-dot"></span><div class="tl-txt"><strong>Leitura · ${l.tipo === 'viab' ? 'viabilidade' : 'crédito'}: ${esc(l.rot)}</strong><span>${esc(NG.fmtDataHora(l.em))} · ${esc(l.det)} · operador · não gravado na venda</span></div></div>` }));
    return its.sort((a, b) => new Date(b.em) - new Date(a.em));
  }
  function histOver() {
    const its = histItens().filter((x) => fc.histF === 'tudo' || x.k === fc.histF);
    return `<div class="fc-hist${fc.hist ? ' open' : ''}" aria-hidden="${!fc.hist}">
      <div class="fc-colh"><h2>Histórico</h2><div class="fc-jchips">${[['tudo', 'Tudo'], ...Object.entries(KIND)].map(([k, t]) => `<button type="button" class="fc-jchip${fc.histF === k ? ' on' : ''}" data-f="fc-hf" data-h="${k}" aria-pressed="${fc.histF === k}">${esc(t)}</button>`).join('')}</div>
        <span class="fc-sp"></span><button type="button" class="fc-x" data-f="fc-hist" aria-label="Fechar o histórico">${IC.x}</button></div>
      <div class="fc-jlist">${fc.hist ? (its.map((x) => `<div class="fc-ji k-${x.k}${x.novo ? ' novo' : ''}"><span class="fc-jl">${esc(KIND[x.k])}</span>${x.html}</div>`).join('') || '<div class="apagado">Nada neste filtro.</div>') : ''}
        ${fc.hist && !d.soConversa ? proximosMarcos(d.v) : ''}</div></div>`;
  }

  // ---------- Lembretes da Mari (13/11, etapa 4a) ----------
  // Ricardo (13/11): "mostrar de forma visível os lembretes já enviados, o próximo (qual e quando) e por que está parada". SÓ
  // LEITURA: espelha a mari_cadencia_avaliar (0141 · 0114) com o que a ficha já carregou — a linha da v_mari_cadencia (o próximo e
  // o bloqueio) e os turnos da Mari com tags.cadencia (o que saiu). Nenhuma chamada nova; não grava nada nem muda a régua.
  const CAD_ROT = { P1: '1º contato', L15: '15 min', F1: '15 min', F2: '1 h', F3: '3 h', F4: '6 h', F5: '20 h', D3: 'D3', LIG: 'Ligar', D7: 'D7', D15: 'D15', FIM: 'Saída',
    BIO1: 'Biometria D+1', BIO3: 'Ligar D+3', INSTALACAO: 'Aviso da instalação', VESPERA: 'Véspera', RETORNO: 'Retorno combinado' };
  const CAD_O_QUE = { P1: 'template de 1º contato', F1: 'cutucada 15 min depois da última fala da Mari', F2: 'cutucada 1 h depois da última fala da Mari',
    F3: 'cutucada 3 h depois da última fala da Mari', F4: 'cutucada 6 h depois da última fala da Mari', F5: 'última chamada ~20 h depois da mensagem do cliente',
    D3: 'template de retomada no 3º dia', LIG: 'o vendedor liga entre o D3 e o D6 (a Mari não liga)', D7: 'template de retomada no 7º dia', D15: 'último template, no 15º dia',
    FIM: '48 h depois do D15 sem resposta, a conversa sem venda vai para Saída · Sem resposta', BIO1: 'lembrete da biometria no D+1 do pedido',
    BIO3: 'no D+3 sem biometria o time liga (nunca automático)', INSTALACAO: 'aviso assim que a instalação é agendada', VESPERA: 'lembrete na véspera da instalação',
    RETORNO: 'retorno no dia e hora que o cliente pediu' };
  const CAD_ACAO = { texto: 'mensagem livre (janela aberta)', template: 'template', ligar: 'ligação do time', encerrar: 'vai para Saída · Sem resposta' };
  const HMS = 3600000;
  // Horário do contrato para toque automático: seg–sex 9–21, sáb 10–16, nunca domingo. Brasília = UTC−3 fixo. Feriado o banco
  // resolve na hora; aqui é só a estimativa do "quando".
  function cadHorario(ms) {
    let t = ms;
    for (let i = 0; i < 10; i++) {
      const l = new Date(t - 3 * HMS);
      const dow = l.getUTCDay();
      const min = l.getUTCHours() * 60 + l.getUTCMinutes();
      const dia0 = Date.UTC(l.getUTCFullYear(), l.getUTCMonth(), l.getUTCDate()) + 3 * HMS;
      const [ab, fe] = dow === 0 ? [null, null] : dow === 6 ? [600, 960] : [540, 1260];
      if (ab != null && min < ab) return dia0 + ab * 60000;
      if (ab != null && min < fe) return t;
      t = dia0 + 24 * HMS;
    }
    return ms;
  }
  const cadDia = (ms) => {
    const hoje = NG.diaSP();
    const dia = NG.diaSP(new Date(ms).toISOString());
    const amanha = NG.diaSP(new Date(Date.now() + 24 * HMS).toISOString());
    return dia === hoje ? 'hoje' : dia === amanha ? 'amanhã' : `${NG.fmtDiaSemana(new Date(ms).toISOString())} ${NG.fmtData(new Date(ms).toISOString())}`;
  };
  const cadQuando = (ms, soDia) => (ms == null ? '' : soDia ? cadDia(ms) : `${cadDia(ms)} ${NG.fmtHora(new Date(ms).toISOString())}`);
  const cadCurto = (ms) => {   // embaixo do passo: "13:20" hoje · "qua 13:20" na semana · "10/11 13:20" antes
    const iso = new Date(ms).toISOString();
    if (NG.diaSP(iso) === NG.diaSP()) return NG.fmtHora(iso);
    return Math.abs(Date.now() - ms) < 6 * 24 * HMS ? `${NG.fmtDiaSemana(iso)} ${NG.fmtHora(iso)}` : NG.fmtDataHora(iso);
  };

  function cadPlano() {
    if (!d || !ehBO()) return null;
    const conv = !!d.soConversa;
    const v = conv ? null : d.v;
    const c = conv ? d.conv : d.convInfo;
    if (!c || !c.id) return null;   // sem conversa no WhatsApp (rua, parceiro): a Mari não manda lembrete
    const A = NG.ajuda;
    const k = (d.cad && d.cad.k) || null;
    const lista = ((d.cad && d.cad.lista) || []).filter((t) => t.tags && t.tags.cadencia);
    const agora = Date.now();
    const ms = (x) => (x ? new Date(x).getTime() : null);
    const lead = d.lead || {};
    const dn = donoConversa(c);
    const proxCod = k && k.proximo_passo ? (k.proximo_passo === 'ENCERRAR' ? 'FIM' : k.proximo_passo === 'L15' ? 'F1' : k.proximo_passo) : null;
    const vInst = !!v && v.status === '2_aguardando_instalacao' && ms(v.instalacao_agendada_para) > agora;
    const fluxoVenda = !!(v || c.venda_id) && (c.status === 'handoff_realizado' || vInst);
    const L = ms(c.ultima_msg_lead_at);
    const P = { grupos: [], passos: [], anteriores: 0, titulo: '', sub: '', tom: 'ok', pill: 'andando', pillCls: 'ok', linha: '', acao: '', resumo: '' };
    let corte = 0;
    const mk = (cod, extra = {}) => ({ cod, rot: CAD_ROT[cod] || cod, st: 'fut', sub: '', em: null, texto: null, ...extra });

    if (fluxoVenda) {
      // Venda (0114 · 0032): biometria (BIO1 · BIO3) e instalação (aviso · véspera). Saem mesmo com a conversa com o time.
      P.titulo = 'venda';
      const bio = v && v.biometria_link_enviado_em && v.biometria_status !== 'validada' && v.status === '0_qualificado';
      const inst = v && v.instalacao_agendada_para && !v.instalado_em;
      if (bio) {
        const base = ms(v.biometria_link_enviado_em);
        corte = base - 60000;
        P.grupos.push({ rot: 'Biometria', dica: A.cad_venda, passos: [mk('BIO1', { prev: cadHorario(base + 24 * HMS) }), mk('BIO3', { prev: base + 72 * HMS })] });
      }
      if (inst) {
        corte = Math.max(corte, ms(v.instalacao_agendada_para) - 30 * 24 * HMS);
        P.grupos.push({ rot: 'Instalação', dica: A.cad_venda, passos: [mk('INSTALACAO'), mk('VESPERA')] });
      }
    } else if (c.status === 'ativo') {
      if (!L) {
        // Sem mensagem do cliente: só lead de formulário (Meta Ads, site, indicação) tem escada — P1 · D7 · D15.
        if (['meta_ads', 'site', 'indicacao'].includes(c.origem)) {
          const p1 = lista.find((t) => t.tags.cadencia === 'P1');
          const B = ms(p1 && p1.created_at) || ms(c.created_at);
          P.grupos.push({ rot: 'Retomada', dica: A.cad_retomada, passos: v ? [mk('P1')] : [mk('P1'), mk('D7', { prev: B + 7 * 24 * HMS }), mk('D15', { prev: B + 15 * 24 * HMS }), mk('FIM')] });
        }
      } else {
        const B = Math.max(L, ms(c.cadencia_retorno_em) || 0);
        corte = L;
        P.sub = `desde a mensagem do cliente, ${cadQuando(L)}`;
        P.grupos.push({ rot: 'Janela de 24 h', dica: A.cad_janela, janela: true, passos: ['F1', 'F2', 'F3', 'F4', 'F5'].map((x) => mk(x)) });
        // Venda criada não recebe D3/D7/D15 (0050): segue pelo time.
        if (!v && !c.venda_id) {
          P.grupos.push({ rot: 'Retomada', dica: A.cad_retomada, passos: [mk('D3', { prev: B + 3 * 24 * HMS }), mk('LIG', { prev: B + 4 * 24 * HMS }), mk('D7', { prev: B + 7 * 24 * HMS }),
            mk('D15', { prev: B + 15 * 24 * HMS }), mk('FIM', { prev: B + 17 * 24 * HMS })] });
        }
        if (c.agendamento_retorno && ms(c.agendamento_retorno) > L) P.grupos.unshift({ rot: 'Combinado', dica: A.cad_retomada, passos: [mk('RETORNO', { prev: ms(c.agendamento_retorno) })] });
      }
    }

    // O que saiu nesta rodada (depois da última mensagem do cliente; L15 = a cutucada de 15 min da abertura) e o que ficou para trás.
    const daRodada = lista.filter((t) => ms(t.created_at) > corte);
    P.anteriores = lista.length - daRodada.length;
    const saiu = (cod) => [...daRodada].reverse().find((t) => t.tags.cadencia === cod || (cod === 'F1' && t.tags.cadencia === 'L15'));
    const seq = P.grupos.flatMap((g) => g.passos);
    const iProx = seq.findIndex((p) => p.cod === proxCod);
    let iUlt = -1;
    seq.forEach((p, i) => {
      const t = saiu(p.cod);
      if (t) { p.st = 'ok'; p.em = ms(t.created_at); p.texto = t.texto; p.simulado = !!t.tags.simulado; iUlt = i; }
    });
    // Instalação e biometria: o banco marca o aviso na própria conversa (instalacao_avisada_para · bio_lembrete_em) — o turno pode ter vindo antes.
    seq.forEach((p) => {
      if (p.st === 'ok') return;
      if (p.cod === 'INSTALACAO' && v && c.instalacao_avisada_para && ms(c.instalacao_avisada_para) === ms(v.instalacao_agendada_para)) { p.st = 'ok'; p.em = ms(c.instalacao_avisada_em) || null; }
      if (p.cod === 'BIO1' && v && c.bio_lembrete_em && ms(c.bio_lembrete_em) >= ms(v.biometria_link_enviado_em)) { p.st = 'ok'; p.em = ms(c.bio_lembrete_em); }
    });
    seq.forEach((p, i) => {
      if (p.st === 'ok' || p.cod === 'LIG') return;
      if (i === iProx) {
        p.st = p.cod === 'BIO3' && k.ligar_sugerido ? 'agora' : 'prox';
        const quando = k.bloqueio === 'fora do horário' ? ms(k.proximo_em) : cadHorario(ms(k.proximo_em));
        p.em = p.cod === 'BIO3' || p.cod === 'FIM' ? ms(k.proximo_em) : quando;
        p.texto = k.texto || null;
        if (/véspera passou|próxima demais/.test(k.bloqueio || '')) p.st = 'pul';
      } else if (i < Math.max(iProx, iUlt) || (['F1', 'F2', 'F3', 'F4', 'F5'].includes(p.cod) && L && agora >= L + 23 * HMS)) p.st = 'pul';
    });
    const lig = seq.find((p) => p.cod === 'LIG');
    if (lig) {
      const ligou = (d.contatos || []).find((x) => x.canal === 'ligacao' && ms(x.em) > lig.prev - 24 * HMS);
      if (ligou) { lig.st = 'ok'; lig.em = ms(ligou.em); } else if (k && k.ligar_sugerido) lig.st = 'agora';
      else if (agora > lig.prev + 2 * 24 * HMS) lig.st = 'pul';
    }
    seq.forEach((p) => {
      p.sub = p.st === 'ok' ? (p.em ? cadCurto(p.em) : 'saiu') : p.st === 'pul' ? 'não saiu' : p.st === 'agora' ? 'ligar agora' : p.st === 'prox' ? cadQuando(p.em) : p.prev ? `~${cadDia(cadHorario(p.prev))}` : '';
      p.tit = `${p.rot} · ${CAD_O_QUE[p.cod] || ''}${p.st === 'ok' ? (p.em ? ` · saiu ${NG.fmtDataHora(new Date(p.em).toISOString())}` : ' · saiu') : p.st === 'pul' ? ' · não saiu (passou a hora ou a janela fechou)' : p.st === 'prox' ? ` · próximo, ${cadQuando(p.em)}` : ''}`;
    });
    P.passos = seq;

    // Por que está parada (o mesmo texto do banco, na língua de quem atende) — a ordem é a da mari_cadencia_avaliar.
    const comPessoa = dn.tipo === 'pessoa' || dn.tipo === 'time' || c.humano_atribuido || c.time_atribuido;
    const quem = dn.tipo === 'pessoa' ? (c.chatwoot_agente || 'alguém do time') : 'o time';
    const devolver = '<button type="button" class="btn btn-sm" data-momento="devolver_mari">Devolver para a Mari</button>';
    const b = k && k.bloqueio && k.bloqueio !== 'aguardando' ? k.bloqueio : '';
    const set = (tom, pill, linha, acao = '') => Object.assign(P, { tom, pill, pillCls: { ok: 'ok', warn: 'warn', bad: 'bad', fim: 'mute', pausa: 'pend', mute: 'mute' }[tom], linha, acao });
    const prox = seq[iProx];
    const proxTxt = prox ? `Próximo: <b>${esc(prox.rot)} · ${esc(cadQuando(prox.em))}</b>${k.acao && CAD_ACAO[k.acao] ? ` · ${esc(CAD_ACAO[k.acao])}` : ''}` : '';
    const verTexto = prox && prox.texto ? `<button type="button" class="fc-link" data-f="fc-cadp" data-c="${prox.cod}">Ver o texto</button>` : '';
    const emSaida = (v && v.status === 'saida') || lead.destino === 'saida' || lead.destino === 'teste_duplicada';
    if (emSaida) {
      const sr = lead.saida_motivo === 'sem_resposta';
      set('fim', 'encerrada', sr ? 'Terminou: o cliente não respondeu à cadência e o lead foi para Saída · Sem resposta. Se ele escrever, a conversa reabre.'
        : `Encerrada: o lead está em Saída${lead.saida_nome ? ` · ${esc(lead.saida_nome)}` : ''}. A Mari não manda lembrete.`);
    } else if (c.nao_contatar) set('fim', 'encerrada', 'Encerrada: o cliente pediu para não ser contatado. A Mari não volta a escrever.');
    else if (!['ativo', 'handoff_realizado'].includes(c.status)) set('fim', 'encerrada', 'Encerrada: a conversa foi encerrada pelo time. Se o cliente escrever, ela reabre.');
    else if (/humano atribu|time atribu/.test(b) || (!k && comPessoa && !fluxoVenda)) set('warn', 'parada', `Parada: a conversa está com ${esc(quem)}. A Mari não manda lembrete enquanto alguém do time estiver nela.`, devolver);
    else if (/resolvida/.test(b) || (!k && !fluxoVenda && (c.chatwoot_resolvida || c.chatwoot_status === 'resolved'))) set('warn', 'parada', 'Parada: a conversa foi resolvida no Chatwoot. Volta sozinha se o cliente escrever.');
    else if (/pendência/.test(b) || (!k && d.pend && !vInst)) set('pausa', 'pausada', `Pausada pela pendência${d.pend ? ` até ${esc(d.pend.diaTxt)}` : ''}. Os lembretes voltam quando ela for encerrada.`, d.pend ? '<button type="button" class="btn btn-sm" data-f="fc-pend">Ver a pendência</button>' : '');
    else if (/telefone de teste/.test(b)) set('mute', 'teste', 'Número de teste: os lembretes não saem.');
    else if (/template não aprovado|texto reprovado|limite do/.test(b)) set('bad', 'travada', `Travada: ${esc(b)}. ${prox ? `O ${esc(prox.rot)} não sai até resolver. ` : ''}Avise o Ricardo.`);
    else if (/D\+3 sem biometria/.test(b)) set('warn', 'ligar', 'D+3 sem biometria: ligue para o cliente — a Mari não liga.', v && d.conversaId ? '<button type="button" class="btn btn-sm" data-f="fc-reg">Registrar a ligação</button>' : '');
    else if (/venda criada/.test(b)) set('mute', 'com o time', 'A venda segue pelo time: D3, D7 e D15 não saem depois que a venda nasce.');
    else if (/time falou com o cliente hoje/.test(b)) set('ok', 'adiada', `Adiada: o time falou com o cliente hoje (🔥). ${proxTxt || 'O próximo sai no dia útil seguinte.'}`, verTexto);
    else if (/Mari respondendo/.test(b)) set('ok', 'respondendo', 'A Mari está respondendo agora.');
    else if (/aguardando a Mari/.test(b)) {
      const min = L ? Math.round((agora - L) / 60000) : 0;
      const timeFalou = d.ultTimeEm && L && ms(d.ultTimeEm) > L;   // o time respondeu depois do cliente: ninguém está sem resposta
      if (timeFalou) set('mute', 'com o time', `O time respondeu o cliente (${esc(cadQuando(ms(d.ultTimeEm)))}). Os lembretes voltam quando o cliente falar de novo.`);
      else if (min > 10) set('bad', 'sem resposta', `A Mari não respondeu a última mensagem do cliente (há ${esc(NG.haQuanto(c.ultima_msg_lead_at))}). Os lembretes só voltam depois da resposta. Responda você pela conversa.`, '<button type="button" class="btn btn-sm btn-acc" data-f="conversa">Responder</button>');
      else set('ok', 'respondendo', 'O cliente acabou de escrever: a Mari está respondendo.');
    }
    else if (/janela de 24 h fechada/.test(b)) set('mute', 'esperando', `A janela de 24 h fechou: as cutucadas não saem mais.${seq.some((p) => p.cod === 'D3') ? ' Segue no D3.' : ''}`);
    else if (/véspera passou|próxima demais/.test(b)) set('mute', 'sem lembrete', b.includes('véspera') ? 'A véspera passou: o lembrete diz "amanhã", então não sai mais.' : 'A instalação está perto demais para o lembrete da véspera.');
    else if (/C2\) saiu há menos/.test(b)) set('ok', 'andando', `O aviso do agendamento saiu há pouco: a véspera espera 12 h. ${proxTxt}`, verTexto);
    else if (/retorno agendado/.test(b)) set('ok', 'combinado', `Retorno combinado com o cliente: <b>${esc(cadQuando(ms(c.agendamento_retorno)))}</b>.`, verTexto);
    else if (prox && (prox.st === 'prox' || prox.st === 'agora')) set(prox.st === 'agora' ? 'warn' : 'ok', prox.st === 'agora' ? 'ligar' : b === 'fora do horário' ? 'esperando a hora' : 'andando', `${proxTxt}${b === 'fora do horário' ? ' · espera o horário do contrato' : ''}`, verTexto);
    else if (lig && lig.st === 'agora') set('warn', 'ligar', 'Hora de ligar: o D3 saiu e o cliente não respondeu. A Mari não liga.', v ? '<button type="button" class="btn btn-sm" data-f="fc-reg">Registrar a ligação</button>' : '');
    else if (fluxoVenda && !seq.length) {
      const e = (lead.etapa || '');
      set('mute', 'com o time', e === 'instalada' ? 'Instalada: sem lembrete da Mari. A régua de pagamento (D−2 · D0 · D+5) começa com a 1ª fatura — ainda falta o extrato da Nio.'
        : 'Nenhum lembrete agora: a venda está com o time. Os da biometria começam quando o pedido sai no portal; os da instalação, quando ela é agendada.');
    } else if (!seq.length) set('mute', 'sem cadência', 'Sem cadência: o cliente ainda não escreveu e o lead não veio de formulário.');
    else if (seq.every((p) => p.st === 'ok' || p.st === 'pul')) set('mute', 'terminou', 'Todos os lembretes desta rodada já saíram ou passaram.');
    else set('ok', 'andando', 'Nada marcado agora: o próximo lembrete aparece aqui quando o banco agendar.');
    if (P.tom !== 'ok') seq.forEach((p) => { if (p.st === 'fut') p.sub = ''; });
    // Resumo de uma linha (faixa acima da caixa da conversa).
    const nOk = seq.filter((p) => p.st === 'ok').length;
    P.resumo = P.tom === 'ok' && prox ? `Lembretes${nOk ? ` · ${nOk} enviado${nOk > 1 ? 's' : ''}` : ''} · próximo ${prox.rot} ${cadQuando(prox.em)}`
      : `Lembretes · ${P.pill}${P.tom === 'warn' && /com /.test(P.linha) && comPessoa ? `: com ${quem}` : ''}`;
    return P;
  }
  // Nunca derruba a ficha: se a leitura falhar, a faixa some e a ficha abre igual.
  function cadPlanoSeguro() { try { return cadPlano(); } catch (e) { console.warn('[ficha] lembretes da Mari', e); return null; } }
  function cadFaixa(P, solta) {
    if (!P) return '';
    const A = NG.ajuda;
    const ic = { ok: '✓', pul: '–', prox: '●', agora: '●', fut: '○' };
    const passo = (p) => `<button type="button" class="fc-cb-p s-${p.st}${fc.cadp === p.cod ? ' on' : ''}" data-f="fc-cadp" data-c="${p.cod}" title="${esc(p.tit)}" aria-pressed="${fc.cadp === p.cod}">
        <i aria-hidden="true">${ic[p.st]}</i><b>${esc(p.rot)}</b><small>${esc(p.sub || ' ')}</small></button>`;
    const grupos = P.grupos.filter((g) => g.passos.length).map((g) => `<div class="fc-cb-g"><div class="fc-cb-gk">${esc(g.rot)}${NG.dicaTxt(g.dica)}</div><div class="fc-cb-ps">${g.passos.map(passo).join('')}</div></div>`).join('');
    const sel = fc.cadp && P.passos.find((p) => p.cod === fc.cadp);
    let pe;
    if (sel) {
      const quando = sel.st === 'ok' ? `saiu ${NG.fmtDataHora(new Date(sel.em).toISOString())}${sel.simulado ? ' (simulado)' : ''}` : sel.st === 'prox' ? `próximo, ${cadQuando(sel.em)}` : sel.st === 'pul' ? 'não saiu' : sel.prev ? `previsto ~${cadDia(sel.prev)}` : 'futuro';
      const txt = sel.texto ? `<q>${esc(String(sel.texto).slice(0, 600))}</q>` : `<span class="apagado">${esc(CAD_O_QUE[sel.cod] || '')}${sel.st === 'fut' ? ' · o texto depende da conversa na hora do envio' : ''}</span>`;
      pe = `<div class="fc-cb-f sel"><span><b>${esc(sel.rot)}</b> · ${esc(quando)}<br>${txt}</span><span class="fc-sp"></span><button type="button" class="fc-x" data-f="fc-cadp" data-c="${sel.cod}" aria-label="Fechar o texto">${IC.x}</button></div>`;
    } else {
      pe = `<div class="fc-cb-f t-${P.tom}"><span>${P.linha}</span><span class="fc-sp"></span>${P.acao}${P.anteriores ? `<button type="button" class="fc-link" data-f="fc-cadhist" title="${esc(A.cad_anteriores)}">${P.anteriores} antes</button>` : ''}</div>`;
    }
    return `<section class="fc-cb${solta ? ' solta' : ''} t-${P.tom}" aria-label="Lembretes da Mari"><div class="fc-cb-h"><h3>Lembretes da Mari</h3>${NG.dicaTxt(A.cad_faixa)}${P.sub ? `<span class="fc-cb-sub">${esc(P.sub)}</span>` : ''}<span class="fc-sp"></span><span class="fc-pill ${P.pillCls}">${esc(P.pill)}</span></div>
      ${grupos ? `<div class="fc-cb-st">${grupos}</div>` : ''}${pe}</section>`;
  }

  // ---------- faixa da Mari (acima da caixa da conversa) ----------
  const PASSO_ROT_C ={ P1: '1º contato', F1: '+1 h', F2: '+4 h', D3: 'D3', D7: 'D7', D15: 'D15', L15: '15 min', BIO1: 'BIO1', BIO3: 'BIO3', INSTALACAO: 'INSTALACAO', VESPERA: 'VESPERA' };
  function mariFaixa() {
    const conv = !!d.soConversa;
    const v = conv ? null : d.v;
    const k = d.cad && d.cad.k;
    const env = Object.keys((d.cad && d.cad.enviados) || {});
    const dn = donoConversa(d.convInfo || d.conv);
    let txt;
    const cadP = cadPlanoSeguro();   // 13/11 (4a): o mesmo cálculo da faixa "Lembretes da Mari" da ficha
    if (cadP) txt = cadP.resumo;
    else if (v && v.status === 'saida') txt = 'Lembretes: nenhum (fora da jornada)';
    else if (d.pend) txt = `Lembretes pausados pela pendência até ${d.pend.diaTxt}`;
    else if (dn.tipo === 'pessoa' || dn.tipo === 'time') txt = `${env.length ? `Lembretes ${env.map((c) => `${PASSO_ROT_C[c] || c} ✓`).join(' · ')} · ` : ''}cadência parada: a conversa está com uma pessoa`;
    else if (k && k.proximo_passo && k.proximo_em) txt = `${env.length ? `${env.map((c) => `${PASSO_ROT_C[c] || c} ✓`).join(' · ')} · ` : ''}próximo ${PASSO_ROT_C[k.proximo_passo] || k.proximo_passo} ${NG.fmtDiaSemana(k.proximo_em)} ${NG.fmtHora(k.proximo_em)}`;
    else txt = env.length ? `Lembretes ${env.map((c) => `${PASSO_ROT_C[c] || c} ✓`).join(' · ')}` : 'Nenhum lembrete automático marcado';
    if (!conv) txt += ` · contatos ${NG.contatosTxt(d.lim.hoje, d.lim.mes, d.teto)}`;
    if (fc.reg && !conv) {
      return `<div class="fc-reg"><div class="fc-reg-h">Registrar contato com ${esc(NG.primeiroNome(v.cliente_nome))}
          <select data-fc-dir aria-label="Quem chamou"><option value="saida">nós chamamos</option><option value="entrada">o cliente chamou</option></select></div>
        <input type="text" data-fc-resumo maxlength="500" placeholder="Resumo (opcional)" aria-label="Resumo do contato">
        <span class="fc-chk"><label><input type="checkbox" data-fc-aut> O cliente pediu ou autorizou este contato</label>${NG.dicaTxt(NG.ajuda.contato_autorizou)}</span>
        <div class="fc-reg-bts"><button type="button" class="btn btn-sm" data-f="fc-contato" data-canal="ligacao">Ligação</button><button type="button" class="btn btn-sm" data-f="fc-contato" data-canal="whatsapp">WhatsApp</button>
          <button type="button" class="btn btn-sm" data-f="fc-contato" data-canal="presencial">Presencial</button><span class="fc-sp"></span><button type="button" class="fc-link" data-f="fc-reg">Cancelar</button></div>
        <small class="apagado">Fica no histórico e conta nos contatos do mês.</small></div>`;
    }
    if (fc.cad) {
      return `<div class="fc-reg fc-cad">${cadP ? cadFaixa(cadP, true) : conv ? `<div class="f-lembretes"><div class="f-lb-cab"><span class="f-rot">CADÊNCIA DO LEAD</span></div><span>${esc(txt)}</span></div>` : lembretes(v)}
        <div class="fc-reg-bts">${conv ? '' : '<button type="button" class="fc-link" data-f="fc-reg">Registrar contato</button>'}<span class="fc-sp"></span><button type="button" class="fc-link" data-f="fc-cad">Fechar</button></div></div>`;
    }
    return `<div class="fc-mstrip"><span class="fc-mdot" aria-hidden="true"></span><button type="button" class="fc-mtbtn" data-f="fc-cad" title="Ver cadência e lembretes">${esc(txt)}</button>
      ${conv || (v && v.status === 'saida') ? '' : '<button type="button" class="fc-link" data-f="fc-reg">Registrar contato</button>'}</div>`;
  }

  // ---------- desenho ----------
  function renderCheia() {
    const vivo = raiz.querySelector('.fc-conv-host > .cvp-raiz');
    const focoAntes = document.activeElement;
    const devolverRolagem = guardarRolagemConv(vivo);
    const conv = !!d.soConversa;
    const cv = conv ? d.conv : d.convInfo;
    const dn = donoConversa(cv);
    const ehAdmin = (NG.usuario || {}).perfil === 'admin';
    let cab, trilha, agora, cards, over = '';
    if (!conv) {
      const v = d.v;
      const pr = NG.proximoPasso(v, (d.contatos[0] || {}).em);
      if (!abertos) abertos = new Set();
      const p = passoPartes(v, pr);
      const etapa = d.jor ? d.jor.etapa : (NG.etapaDe(v).n || 0);
      document.title = tituloCom(v.cliente_nome);
      const atual = NG.etapaDe(v).id;
      const menu = `${ehAdmin ? `<div class="fc-mlab">Mover para</div><div class="fc-mrow">${DESTINOS.filter(([st]) => NG.etapaDe(st).id !== atual).map(([st, n]) => `<button type="button" class="fc-mchip" data-f="mover" data-st="${st}">${esc(n)}</button>`).join('')}</div><div class="fc-msep"></div>` : ''}
        ${v.cliente_whatsapp ? '<button type="button" class="fc-mitem" data-f="copiar-tel">Copiar telefone</button>' : ''}
        ${d.conversaId ? `<a class="fc-mitem" href="mari.html?conversa=${esc(d.conversaId)}">Ver na tela Mari</a>` : ''}${auditarItem()}
        <a class="fc-mitem" href="vendas.html?vista=quadro&amp;etapa=${esc(atual)}">Ver no Funil (Quadro)</a>
        <a class="fc-mitem" href="venda.html?id=${esc(v.id)}" target="_blank" rel="noopener">Abrir em página cheia ↗</a>
        ${d.chatwoot ? `<a class="fc-mitem" href="${esc(d.chatwoot)}" target="_blank" rel="noopener">Conversa no Chatwoot ↗</a>` : ''}`;
      const ref = v.origem_ref && !/^mari:/i.test(v.origem_ref) ? ` · ${v.origem_ref}` : '';
      const meta = [[d.nomeCurto || v.plano_nome, v.valor_mensal != null && Number(v.valor_mensal) ? NG.fmtMoeda(v.valor_mensal) : null, v.forma_pagamento ? FORMA_TXT[v.forma_pagamento] || v.forma_pagamento : null].filter(Boolean).join(' · '),
        v.bairro, v.cidade, NG.origemTxt(v) + ref].filter(Boolean).map(esc).join(' · ');
      cab = cabCheia(v.cliente_nome, `${chipCopia('CPF', v.cliente_cpf_cnpj ? fmtDoc(v.cliente_cpf_cnpj) : '')}${chipCopia('OS', v.nio_os, 'os')}`,
        `${meta}${cv && cv.chatwoot_conversation_id ? ` · <span class="fc-dono">${dn.html}</span>` : ''}`, menu);
      trilha = trilhasHtml();
      const E = escadaPartes(true);
      const tom = p.alertaConv ? 'now' : TOM[p.nivel] || 'mute';
      const k = p.alertaConv ? 'Agora · conversa' : `${NIVEL_K[p.nivel] || 'Próximo passo'}${E ? '' : etapa ? ` · ${d.jor ? d.jor.etapa_nome : NG.etapaDe(v).nome}` : ''}`;
      const t = etapa === 0 ? `Saída · ${v.motivo_saida || 'sem motivo'}` : p.alertaConv ? p.jReal.o_que_fazer : p.texto;
      const s = etapa === 0 ? (v.interesse_futuro_em ? `Volta em ${NG.fmtDiaISO(v.interesse_futuro_em)}` : '') : p.alertaConv ? `Depois: ${p.texto || '—'}`
        : feitoUltimo ? feitoUltimo.resumo : p.nota || (p.sozinho ? `O NIOGEN faz sozinho: ${p.sozinho}` : '');
      const responder = p.alertaConv && p.jReal.botao === 'responder' && d.conversaId;
      const rot = responder ? 'Responder' : p.temAcao && p.rotuloAcao ? p.rotuloAcao : p.temAcao ? 'Fazer' : 'Ações';
      const botao = `<div class="fc-ag-bts"><button type="button" class="btn${responder || (p.temAcao && ['now', 'today'].includes(tom)) ? ' btn-acc' : ''} fc-ag-bt" data-f="${responder ? 'conversa' : 'fc-passo'}">${esc(rot.length > 26 ? 'Fazer' : rot)}${IC.seta}</button>
        ${responder ? '<button type="button" class="fc-link" data-f="fc-passo" title="Próximo passo da venda e atalhos (pendência, devolver para a Mari, saída…)">Ações da venda</button>' : ''}${E ? E.reabrir : ''}</div>`;
      agora = `<div class="fc-agora-w">${agoraHtml(tom, k, t, s, botao, pendLinha(v), E ? E.info : '')}${pendOver()}</div>`;
      cards = `<div class="fc-cards">${cardsVenda(v)}${verTudo(v)}${passoOver(v, p)}${etapaOver(passosVenda(v))}</div>`;
    } else {
      const P = conversaPartes();
      const c = P.c;
      const x = (c.dados && typeof c.dados === 'object') ? c.dados : {};
      document.title = tituloCom(c.nome);
      const menu = `${c.telefone ? `<button type="button" class="fc-mitem" data-copiar="${esc(fmtTel(c.telefone))}">Copiar telefone</button>` : ''}<a class="fc-mitem" href="mari.html?conversa=${esc(c.id)}">Ver na tela Mari</a>${auditarItem()}
        ${d.chatwoot ? `<a class="fc-mitem" href="${esc(d.chatwoot)}" target="_blank" rel="noopener">Conversa no Chatwoot ↗</a>` : ''}`;
      cab = cabCheia(c.nome, chipCopia('CPF', x.cpf ? fmtDoc(x.cpf) : ''), `${[P.q.plano_nome || c.plano_escolhido, c.cidade, NG.ORIGENS[c.origem] || c.origem].filter(Boolean).map(esc).join(' · ') || '—'} · <span class="fc-dono">${dn.html}</span>`, menu,
        ehBO() && !P.silenciada && !c.nao_contatar ? '<button type="button" class="btn" data-csaida="suporte_nio" title="Cliente só perturbando ou pedindo suporte da Nio: não é venda. A Mari cala e ele não volta para o Live (desfaz por Reativar).">📵 Silenciar</button>' : '');
      trilha = trilhasHtml();
      const E = escadaPartes(false);
      const tom = P.silenciada ? 'mute' : TOM[P.nivel] || 'wait';
      const botao = `<div class="fc-ag-bts"><button type="button" class="btn${tom === 'now' ? ' btn-acc' : ''} fc-ag-bt" data-f="fc-passo">${dn.tipo === 'mari' && !c.nao_contatar && ehBO() && !P.silenciada ? 'Assumir' : 'Ações'}${IC.seta}</button>${E ? E.reabrir : ''}</div>`;
      const pendH = P.emEspera ? `<div class="fc-ag-pend"><span class="fc-pill pend">${IC.pausa}em espera</span><span class="fc-pt">até ${esc(NG.fmtData(c.espera_ate))} · ${esc(c.espera_motivo || '')}</span></div>` : '<div class="fc-ag-pend none"><span>Sem pendência</span></div>';
      agora = `<div class="fc-agora-w">${agoraHtml(tom, `${P.silenciada ? 'Silenciada' : NIVEL_K[P.nivel] || 'Conversa'} · conversa sem venda`, P.silenciada ? 'Cliente Nio · suporte — fora do Live' : (P.j.o_que_fazer || 'Mari atendendo'),
        feitoUltimo ? feitoUltimo.resumo : `Dados coletados pela Mari ${P.q.itens_validados ?? 0}/${P.q.itens_total ?? 0}`, botao, pendH, E ? E.info : '')}</div>`;
      const L = dadosConversaLista(c);
      const travas = P.travasC;
      const abertoP = fc.passo || formAtivo === 'conv_espera' || formAtivo === 'saida';
      cards = `<div class="fc-cards"><div class="fc-card"><div class="fc-card-h"><h3>Cliente</h3><span class="fc-sp"></span><span class="apagado">coletado pela Mari</span></div>
          <div class="fc-dl">${L.length ? L.map(([kk, val]) => di(kk, String(val), true)).join('') : '<div class="apagado fc-pad">A Mari ainda não coletou dados deste cliente.</div>'}</div></div>
        <div class="fc-card"><div class="fc-card-h"><h3>Venda</h3><span class="fc-sp"></span><span class="fc-pill mute">ainda sem venda</span></div>
          <div class="fc-dl fc-venda-v">${osLista(P.passosConv)}${dinLinha()}
            ${P.itens.length ? `<div class="f-itens fc-itens-v">${P.itens.map((it) => `<span class="f-item ${P.ESTADO[it.estado] || 'no'}">${it.estado === 'validado' ? '✓' : it.estado === 'vazio' ? '○' : '◐'} ${esc(it.nome)}</span>`).join('')}</div>` : ''}
            ${travas.length ? `<div class="fc-di"><span class="fc-dk">Estorno</span><span class="fc-dv"><span class="fc-pill bad">${esc(`risco: ${travas.join(', ')}`)}</span></span><span></span></div>` : ''}</div></div>
        ${abertoP ? `<div class="fc-cards-over fc-passo" role="dialog" aria-label="Ações"><div class="fc-card-h"><h3>${esc(formAtivo === 'saida' ? TIT_SAIDA : NIVEL_ROT[P.nivel] || 'Próximo passo')}</h3><span class="fc-sp"></span><button type="button" class="fc-x" data-f="fc-passo-x" aria-label="Fechar">${IC.x}</button></div>
          <div class="fc-passo-corpo"><div class="fc-passo-b">${formAtivo === 'saida' ? '' : `<b>${esc(P.j.o_que_fazer || 'Mari atendendo')}</b>`}${P.corpoPasso}</div>${P.feito}</div></div>` : ''}${etapaOver(P.passosConv)}</div>`;
    }
    const etapaNome = (d.lead && d.lead.etapa_nome) || (d.jor ? d.jor.etapa_nome : '');
    const temConv = !!d.conversaId;
    const cadB = cadFaixa(cadPlanoSeguro());   // 13/11 (4a): Lembretes da Mari, sempre à vista
    raiz.innerHTML = `<div class="fc">
      ${cab}${trilha}
      <div class="fc-abas" role="tablist" aria-label="O que mostrar"><button type="button" role="tab" class="${fc.aba === 'ficha' ? 'on' : ''}" data-f="fc-aba" data-a="ficha" aria-selected="${fc.aba === 'ficha'}">Ficha</button><button type="button" role="tab" class="${fc.aba === 'conv' ? 'on' : ''}" data-f="fc-aba" data-a="conv" aria-selected="${fc.aba === 'conv'}">Conversa</button></div>
      <div class="fc-grid aba-${fc.aba}">
        <section class="fc-col fc-col-conv" aria-label="Conversa">${temConv ? '<div class="fc-conv-host"></div>'
          : `<div class="fc-colh"><h2>Conversa</h2></div><div class="fc-semconv"><p>Sem conversa no WhatsApp (venda de rua ou parceiro).</p>
              <p class="apagado">Contatos ${esc(NG.contatosTxt(d.lim.hoje, d.lim.mes, d.teto))}${d.contatos[0] ? ` · último ${esc(NG.quando(d.contatos[0].em))}` : ''}</p>
              ${!conv && d.v.status !== 'saida' ? (formAtivo === 'contato' ? FORMS.contato(d.v) : '<button type="button" class="btn" data-resolver="contato">Registrar contato</button>') : ''}</div>`}</section>
        <section class="fc-col fc-col-ficha" aria-label="Ficha do cliente">
          <div class="fc-colh"><h2>Ficha</h2><span class="apagado">${esc(etapaNome)}</span><span class="fc-sp"></span><button type="button" class="btn btn-sm" data-f="fc-hist" aria-expanded="${fc.hist}">${IC.hist}Histórico</button></div>
          <div class="fc-ficha${cadB ? ' com-cad' : ''}">${agora}${cadB}${cards}</div>
          ${histOver()}
        </section>
      </div>${over}</div>`;
    // A conversa não perde o rascunho nem o cursor: o mesmo nó volta para o lugar.
    const host = raiz.querySelector('.fc-conv-host');
    if (host) {
      if (vivo && cvCheia && cvCheia.id === d.conversaId) {
        host.appendChild(vivo);
        devolverRolagem();
        if (focoAntes && vivo.contains(focoAntes)) focoAntes.focus({ preventScroll: true });
      } else {
        if (cvCheia) cvCheia.destruir();
        cvCheia = NGConversa.montar(host, { conversaId: d.conversaId, nome: conv ? d.conv.nome : d.v.cliente_nome, cheia: true,
          oportunidade: cheiaOpts.oportunidade || null, aoMudar: (r) => recarregar({ quieto: !!(r && r.eco) }) });
        cheiaOpts.oportunidade = null;
      }
      cvCheia.mari(mariFaixa(), fc.reg || fc.cad);
    } else if (cvCheia) { cvCheia.destruir(); cvCheia = null; }
    ligarDfvSeEditando();
    const f = raiz.querySelector('[data-form] [autofocus]');
    if (f && (formAtivo || edicao)) f.focus({ preventScroll: true });
  }
  function dadosConversaLista(c) {
    const x = (c.dados && typeof c.dados === 'object') ? c.dados : {};
    return [
      ['Nome', x.nome || c.nome_contato], ['WhatsApp', c.telefone ? fmtTel(c.telefone) : x.telefone], ['CPF', x.cpf ? fmtDoc(x.cpf) : null], ['E-mail', x.email],
      ['CEP', x.cep_origem], ['Endereço', x.rua_confirmada || x.rua_informada], ['Complemento', x.complemento_ok === true ? 'sem complemento' : typeof x.complemento_ok === 'string' ? x.complemento_ok : null],
      ['Referência', x.referencia], ['Cidade', c.cidade], ['Operadora atual', x.operadora_atual], ['Plano escolhido', c.plano_escolhido],
    ].filter(([, val]) => val != null && String(val).trim() !== '');
  }

  // 0143: "Nada a responder" grava a dispensa (conta como resposta nossa: o aviso sai do Live) e abre o próximo da fila.
  async function dispensarAviso(bt) {
    if (d && d.conversaId) {
      if (bt) bt.disabled = true;
      const { data, error } = await NG.sb.rpc('backoffice_conversa_dispensar', { p_conversa: d.conversaId });
      if (error) { NG.toast(NG.msgErro(error), 'bad'); if (bt && bt.isConnected) bt.disabled = false; return; }
      avisarOuvintes(data);
    }
    if (cheiaOpts.aoConcluir) cheiaOpts.aoConcluir();
    else { NG.toast('Aviso dispensado', 'ok'); await recarregar(); }
  }
  // ---------- cliques da tela cheia (as ações de sempre seguem no ligar(); aqui só o que é da tela) ----------
  function cliqueCheia(ev) {
    if (modo !== 'cheia' || !d) return;
    let mudou = false;
    if ((fc.etapa || fc.menu) && !ev.target.closest('.fc-ov, .fc-din-w, .fc-etapa-over, .fc-menuw, .dica-pop')) { fc.etapa = null; fc.menu = false; mudou = true; }
    const rp = ev.target.closest('[data-resolver]');
    if (rp) {
      const q = rp.dataset.resolver;
      if (q === 'pendencia') { fc.pend = true; fc.passo = false; formAtivo = null; render(); return; }
      if (q === 'dfv') { fc.ver = 'cli'; fc.passo = false; render(); return; }
      if (q === 'contato' && d.conversaId) { formAtivo = null; fc.reg = true; fc.passo = false; render(); return; }
    }
    const b = ev.target.closest('[data-f]');
    const a = b ? b.dataset.f : '';
    if (!a.startsWith('fc-')) {
      if (['pend-abrir', 'pend-adiar', 'pend-encerrar', 'pend-saida', 'viab-form', 'ref-form', 'saida-form', 'ir-conferencia', 'pend-viab', 'pend-conf'].includes(a)) { fc.pend = false; fc.etapa = null; fc.passo = true; fc.aba = 'ficha'; render(); return; }   // celular: o formulário abre na aba Ficha
      if (a === 'trocar-plano') { fc.ver = 'venda'; fc.passo = false; render(); return; }
      if (a === 'cancelar' && !(b && b.closest('.f-bloco'))) { fc.passo = false; render(); return; }
      if (a === 'mover') { fc.menu = false; fc.passo = true; fc.aba = 'ficha'; mudou = true; }   // celular: o formulário (Saída, OS, data) abre na aba Ficha
      if (a === 'auditar') { fc.menu = false; mudou = true; }
      if (a === 'conversa' && fc.aba !== 'conv') { fc.aba = 'conv'; mudou = true; }   // celular: Responder leva para a aba Conversa
      if (mudou) render();
      return;
    }
    ev.stopPropagation();
    if (a === 'fc-voltar') { fecharCheia(); return; }
    if (a === 'fc-concluir') { dispensarAviso(b); return; }
    if (a === 'fc-nav') { if (cheiaOpts.aoNavegar) cheiaOpts.aoNavegar(Number(b.dataset.dir)); return; }
    if (a === 'fc-menu') { fc.menu = !fc.menu; render(); return; }
    if (a === 'fc-etapa') { const k = b.dataset.k; fc.etapa = fc.etapa === k || b.closest('.fc-pop') ? null : k; if (fc.etapa) { fc.passo = false; fc.ver = null; fc.conf = false; fc.pend = false; } render(); return; }
    if (a === 'fc-op') { rodarOp(b.dataset.t); return; }
    if (a === 'fc-os-ler') { abrirOsModal(); return; }
    if (a === 'fc-op-reg') {
      const r = b.dataset.r;
      if (b.dataset.t === 'viab') {
        if (r !== 'viavel' && !window.confirm('Registrar na venda: o portal respondeu sem viabilidade?\n\nAntes de encerrar, tente variações de CEP, rua e número.')) return;
        b.disabled = true;
        rodarMomento('viabilidade', { resultado: r }).then((x) => { if (!x && b.isConnected) b.disabled = false; });
        return;
      }
      credPreset = r; formAtivo = 'credito'; fc.etapa = null; fc.passo = true; render(); return;
    }
    if (a === 'fc-pend') { fc.pend = !fc.pend; render(); return; }
    if (a === 'fc-passo') { fc.passo = true; fc.ver = null; fc.pend = false; fc.etapa = null; render(); return; }
    if (a === 'fc-passo-x') { fc.passo = false; formAtivo = null; passoAberto = new Set(); render(); return; }
    if (a === 'fc-ver') { fc.ver = b.dataset.q; fc.passo = false; fc.conf = false; fc.etapa = null; render(); return; }
    if (a === 'fc-ver-x') { fc.ver = null; edicao = null; render(); return; }
    if (a === 'fc-conf') { fc.conf = !fc.conf; if (fc.ver) fc.ver = null; render(); return; }
    if (a === 'fc-conferir') {
      const onde = b.dataset.onde;
      fc.conf = false;
      if (onde === 'cli') { fc.ver = 'cli'; edicao = b.dataset.c === 'contato' ? 'cliente' : null; } else fc.etapa = 'viab';
      render(); return;
    }
    if (a === 'fc-wa') { copiar(textoWa(d.v), 'Cliente e venda copiados — cole no WhatsApp'); return; }
    if (a === 'fc-hist') {
      fc.hist = !fc.hist;
      // Erros da Mari: só quando o Histórico abre (não pesa a abertura da ficha).
      if (fc.hist && fc.erros == null && ehBO() && d.conversaId) {
        fc.erros = [];
        const alvo = idAtual;
        NG.sb.from('mari_erros').select('id, no_n8n, mensagem, created_at').eq('conversa_id', d.conversaId).order('created_at', { ascending: false }).limit(20)
          .then((r) => { if (!r.error && (r.data || []).length && idAtual === alvo && d) { fc.erros = r.data; render(); } }, () => {});
      }
      render(); return;
    }
    if (a === 'fc-tr') { fc.tr = fc.tr === b.dataset.k ? null : b.dataset.k; render(); return; }
    if (a === 'fc-aba') { fc.aba = b.dataset.a; render(); return; }
    if (a === 'fc-hf') { fc.histF = b.dataset.h; render(); return; }
    if (a === 'fc-reg') { fc.reg = !fc.reg; fc.cad = false; if (fc.reg) fc.aba = 'conv'; render(); if (fc.reg) { const i = raiz.querySelector('[data-fc-resumo]'); if (i) i.focus(); } return; }
    if (a === 'fc-cad') { fc.cad = !fc.cad; fc.reg = false; render(); return; }
    if (a === 'fc-cadp') { fc.cadp = fc.cadp === b.dataset.c ? null : b.dataset.c; render(); return; }
    if (a === 'fc-cadhist') { fc.hist = true; fc.histF = 'mari'; render(); return; }
    if (a === 'fc-contato') {
      const fd = new FormData();
      fd.set('canal', b.dataset.canal);
      fd.set('direcao', (raiz.querySelector('[data-fc-dir]') || {}).value || 'saida');
      fd.set('resumo', (raiz.querySelector('[data-fc-resumo]') || {}).value || '');
      if ((raiz.querySelector('[data-fc-aut]') || {}).checked) fd.set('autorizado', 'on');
      b.disabled = true;
      SALVAR.contato(fd).then((ok) => { if (ok) { fc.reg = false; render(); } else if (b.isConnected) b.disabled = false; });
    }
  }
  // Esc: fecha a camada de cima (detalhe, menu, pendência, ver tudo, ações, histórico, registro); sem camada, volta para a fila.
  window.addEventListener('keydown', (ev) => {
    if (ev.key !== 'Escape' || modo !== 'cheia' || !d || ev.defaultPrevented || document.querySelector('dialog[open], .dica-pop')) return;
    const camadas = ['etapa', 'menu', 'pend', 'passo', 'ver', 'conf', 'hist', 'reg', 'cad'];
    const c = camadas.find((k) => fc[k]);
    if (c) { fc[c] = c === 'etapa' || c === 'ver' ? null : false; if (c === 'passo') formAtivo = null; if (c === 'ver') edicao = null; render(); ev.preventDefault(); return; }
    if (ev.target && ev.target.matches && ev.target.matches('textarea, input, select')) return;
    fecharCheia();
  });
  function fecharCheia() {
    const eraGlobal = !!globalEl && raiz === globalEl;
    idAtual = null; d = null;
    if (cvCheia) { cvCheia.destruir(); cvCheia = null; }
    fc = novoFc();
    if (raiz) raiz.innerHTML = '';
    if (eraGlobal) {
      globalEl.classList.remove('open');
      document.body.classList.remove('fc-global-on');
      document.title = tituloOriginal;
      if (paginaVolta) { location.href = paginaVolta; return; }
    }
    if (idDoHash()) { if (empurrou) { empurrou = false; history.back(); } else history.replaceState(history.state, '', semHash()); }
    ouvintesFechar.forEach((f) => { try { f(); } catch (e) { /* */ } });
  }
  let cheiaEl = null;
  function usarCheia() {
    if (!cheiaEl || (modo === 'cheia' && raiz === cheiaEl)) return;
    if (idAtual) { if (modo === 'cheia') fecharCheia(); else if (gav && gav.classList.contains('aberta')) NG.gaveta.fechar(); }
    modo = 'cheia';
    raiz = cheiaEl;
    cheiaOpts = liveOpts || {};
  }
  // 13/11 (etapa 4a): FICHA ÚNICA — a mesma tela cheia, por cima de qualquer tela (Leads, Vendas, Painel, Mari, Quadro da Live,
  // celular…). Um elemento só no body; fora da Live não há fila, então o cabeçalho mostra "Voltar" no lugar de "Fila" e ↑ ↓.
  function usarGlobal() {
    if (!globalEl) {
      globalEl = document.createElement('div');
      globalEl.className = 'fc-global';
      globalEl.id = 'ficha-unica';
      globalEl.setAttribute('aria-label', 'Ficha do cliente');
      document.body.appendChild(globalEl);
      ligar(globalEl);
      globalEl.addEventListener('click', cliqueCheia);
    }
    modo = 'cheia';
    raiz = globalEl;
    cheiaOpts = {};
  }
  // Menu ⋯ e detalhe da etapa fecham com clique fora (inclusive fora da tela do cliente).
  document.addEventListener('click', (ev) => {
    if (modo === 'cheia' && raiz && d && (fc.menu || fc.etapa) && !raiz.contains(ev.target) && !ev.target.closest('.dica-pop')) { fc.menu = false; fc.etapa = null; render(); }
  });
  function cheia(el, opts) {
    modo = 'cheia';
    cheiaEl = el;
    raiz = el;
    ligar(raiz);
    raiz.addEventListener('click', cliqueCheia);
    cheiaOpts = opts || {};
    liveOpts = cheiaOpts;
  }

  window.NGFicha = {
    abrir,
    abrirConversa: abrirConversaFicha,
    lado, usarGaveta, usarLado,
    // 12/11: tela cheia do Live (fila.html). opts = { posicao(), aoNavegar(dir), aoConcluir() }; NGFicha.fecharCheia() fecha.
    cheia, usarCheia, get modo() { return modo === 'cheia' && globalEl && raiz === globalEl ? 'gaveta' : modo; },
    get unica() { return !fichaAntiga(); }, fecharCheia: () => { if (modo === 'cheia' && idAtual) fecharCheia(); },
    set oportunidadeCheia(op) { cheiaOpts.oportunidade = op; },
    redesenhar() { if (d) render(); },
    // A tela abre a conversa no lugar dela (Live: no espaço da lista). fn({conversaId, nome, aoMudar}); null desliga.
    aoConversa(fn) { hostConversa = fn; },
    aoFechar(fn) { ouvintesFechar.push(fn); },
    recarregar: (op) => recarregar(op),
    // 10/11 (modo foco do Live): fn = "← Lista" no cabeçalho (null tira) · largo(true) = ficha em 2 colunas, dados à direita.
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
