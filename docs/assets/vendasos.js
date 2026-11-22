/* NIOGEN | docs/assets/vendasos.js | 22/11/2026 — Claude Code (Fable 5.2)
 * A regra comum das telas Vendas e Instalações (Ricardo, 22/11: "A Nio considera venda tudo que teve OS gerada").
 * As duas telas mostram AS MESMAS vendas (com nº de OS), NA MESMA ordem (data da OS, mais recente primeiro) e com o MESMO
 * status — o que muda é o foco das colunas. Só leitura: nada aqui grava.
 * Fontes: v_vendas (a venda) · v_os_andamento (o que a Nio diz da OS, lido pelo Operador de OS e pelo OSAB) ·
 * os_leituras (cada leitura da OS — de onde sai o reagendamento e o motivo).
 * Uso: const d = await NGVendasOS.carregar({ leituras: true }); d.vendas, d.os[vendaId], d.leituras[vendaId]. */
(function () {
  const INST = ['3_instalado', '4_ativo_provisorio', '5_comissao_firme'];
  const COLS = 'id, status, criado_em, criado_por, cliente_nome, cliente_cpf_cnpj, cliente_whatsapp, bairro, cidade, plano_id, plano_nome, plano_variante, valor_mensal, '
    + 'forma_pagamento, comissao_prevista, comissao_paga, ciclo_pago, nio_pedido, nio_os, nio_os_em, nio_osab_em, nio_venda_valida, nio_pendencia_cod, nio_pendencia_desc, '
    + 'biometria_status, vendido_em, instalacao_agendada_para, instalado_em, vendedor_id, vendedor_nome, origem, parceiro_id, parceiro_nome, motivo_saida, '
    + 'cancelada_apos_instalar_em, cancelada_apos_instalar_motivo, pend_id, pend_motivo, pend_motivo_nome, pend_descricao, pend_quem, pend_desde, pend_revisar_em, pend_revisoes, pend_saida_sugerida';
  const COLS_OS = 'venda_id, pedido, estado, estado_nome, status_ordem, status_agendamento, agendamento_data, janela, pendencia, motivo_cancelamento, acao, excecao, agendamentos, referencia_em, mudou_em, origem_ultima';

  // Os status da lista (a ordem é a das pílulas). "Em campo" só aparece quando a Nio informa (técnico em deslocamento ou em execução).
  const STATUS = [
    { id: 'pagamento', nome: 'Aguardando pagamento', cls: 'warn' },
    { id: 'semdata', nome: 'Sem data', cls: 'warn' },
    { id: 'agendada', nome: 'Agendada', cls: 'info' },
    { id: 'campo', nome: 'Em campo', cls: 'info' },
    { id: 'pendencia', nome: 'Pendência', cls: 'bad' },
    { id: 'instalada', nome: 'Instalada', cls: 'ok' },
    { id: 'cancelada', nome: 'Cancelada', cls: 'dim' },
  ];
  const STATUS_POR = Object.fromEntries(STATUS.map((s) => [s.id, s]));

  const instalada = (v) => !!v.instalado_em || INST.includes(v.status);
  // A data da OS: quando a OS foi gravada; venda antiga sem esse carimbo cai na data da venda.
  const dataOS = (v) => v.nio_os_em || v.vendido_em || v.criado_em;
  // Dia da instalação (AAAA-MM-DD): o que a Nio mostra na OS vale; sem leitura, o que está gravado na venda.
  const diaInstalacao = (v, o) => (o && o.agendamento_data ? String(o.agendamento_data).slice(0, 10) : v.instalacao_agendada_para ? NG.diaSP(v.instalacao_agendada_para) : null);
  const turno = (v, o) => (o && o.janela ? String(o.janela).replace(/:00/g, 'h').replace(/\s*-\s*/, '–') : v.instalacao_agendada_para ? NG.janela(v.instalacao_agendada_para) : '');

  function statusDe(v, o) {
    o = o || {};
    if (v.status === 'saida' || v.cancelada_apos_instalar_em || ['cancelando', 'cancelada', 'reprovada'].includes(o.estado)) return 'cancelada';
    if (instalada(v)) return 'instalada';
    const dia = diaInstalacao(v, o);
    if (String(o.estado || '').startsWith('pendencia') || v.nio_pendencia_cod || v.nio_pendencia_desc || NG.pendencia(v) || (dia && dia < NG.diaSP())) return 'pendencia';
    if (o.estado === 'em_campo' || /deslocamento|execu/i.test(o.status_agendamento || '')) return 'campo';
    if (o.estado === 'aguardando_pagamento' || /aguardando pagamento/i.test(o.status_ordem || '')) return 'pagamento';
    return dia ? 'agendada' : 'semdata';
  }
  // Por que está em Pendência, numa frase curta.
  function pendenciaTxt(v, o) {
    o = o || {};
    if (o.pendencia) return o.pendencia;
    if (v.nio_pendencia_cod || v.nio_pendencia_desc) return [v.nio_pendencia_cod, v.nio_pendencia_desc].filter(Boolean).join(' · ');
    const p = NG.pendencia(v);
    if (p) return `em espera: ${p.nome || 'pendência'} (${p.quemTxt})`;
    const dia = diaInstalacao(v, o);
    if (dia && dia < NG.diaSP()) return `a data (${NG.fmtDiaISO(dia).slice(0, 5)}) passou sem baixa da Nio`;
    return '';
  }
  // O texto exato da Nio sobre a OS (status da ordem · situação do agendamento). Vazio = OS ainda não lida.
  const textoNio = (o) => (o ? [o.status_ordem, o.status_agendamento].filter(Boolean).join(' · ') : '');

  // Comissão da Nio: { valor, id, txt, cls, dica }. Prevista → Confirmada no OSAB → Paga; cancelada ou sem regra = Sem comissão.
  function comissaoDe(v, st) {
    if (v.comissao_paga != null) return { valor: Number(v.comissao_paga), id: 'paga', txt: `Paga${v.ciclo_pago ? ` · ${v.ciclo_pago}` : ''}`, cls: 'ok', dica: 'Veio no extrato da Nio.' };
    if (st === 'cancelada') return { valor: null, id: 'sem', txt: 'Sem comissão', cls: 'dim', dica: 'Venda cancelada: não gera comissão.' };
    if (v.nio_venda_valida === false) return { valor: null, id: 'sem', txt: 'Sem comissão', cls: 'dim', dica: 'A Nio marcou esta venda como inválida no OSAB.' };
    if (v.comissao_prevista == null) return { valor: null, id: 'sem', txt: 'Sem comissão', cls: 'dim', dica: 'Não há comissão cadastrada para este plano.' };
    if (v.nio_osab_em) return { valor: Number(v.comissao_prevista), id: 'osab', txt: 'Confirmada no OSAB', cls: 'info', dica: `O OSAB confirmou a venda em ${NG.fmtData(v.nio_osab_em)}. Ainda falta vir no extrato.` };
    return { valor: Number(v.comissao_prevista), id: 'prevista', txt: 'Prevista', cls: '', dica: 'Valor da tabela de comissões. Só conta quando o OSAB confirmar a instalação.' };
  }
  const COMISSOES = [['prevista', 'Prevista'], ['osab', 'Confirmada no OSAB'], ['paga', 'Paga'], ['sem', 'Sem comissão']];

  // Reagendamentos de uma OS: cada vez que a data do agendamento mudou entre duas leituras. O motivo é a pendência que a Nio
  // mostrou na leitura da mudança ou entre a data antiga e a nova; sem pendência = a Nio não informou (a tela diz isso, não inventa).
  function reagendamentos(leituras) {
    const vale = (p) => { const t = String(p || '').trim(); return t && t !== '-' && !['OK', 'N/A'].includes(t.toUpperCase()) ? t : null; };
    const ls = (leituras || []).slice().sort((a, b) => new Date(a.referencia_em || a.lido_em) - new Date(b.referencia_em || b.lido_em));
    const lista = [];
    let ult = null, pend = null;
    ls.forEach((l) => {
      const p = vale(l.pendencia);
      const d = l.agendamento_data ? String(l.agendamento_data).slice(0, 10) : null;
      if (p) pend = p;
      if (!d) return;
      if (ult && d !== ult) { lista.push({ de: ult, para: d, motivo: pend, em: l.referencia_em || l.lido_em }); pend = null; }
      else if (ult && !p) pend = null;   // a pendência sumiu sem trocar a data: não é motivo de um reagendamento futuro
      ult = d;
    });
    return lista;
  }

  async function carregar({ leituras = false } = {}) {
    const [rv, ro, rl, rp] = await Promise.all([
      NG.sb.from('v_vendas').select(COLS).not('nio_os', 'is', null).limit(2000),
      NG.sb.from('v_os_andamento').select(COLS_OS).not('venda_id', 'is', null).limit(2000),
      leituras ? NG.sb.from('os_leituras').select('venda_id, pedido, lido_em, referencia_em, agendamento_data, pendencia').not('venda_id', 'is', null).order('lido_em', { ascending: true }).limit(5000) : Promise.resolve({ data: [] }),
      NG.sb.from('config_planos').select('id, nome_curto'),
    ]);
    if (rv.error) return { erro: rv.error, vendas: [], os: {}, leituras: {}, nomeCurto: {} };
    const vendas = (rv.data || []).slice().sort((a, b) => new Date(dataOS(b)) - new Date(dataOS(a)));
    // Uma venda pode ter mais de um pedido lido na Nio (o cliente refez o pedido): vale o pedido que é a OS da venda;
    // sem casar o número, o que mudou por último. As leituras seguem a mesma regra.
    const numOS = Object.fromEntries(vendas.map((v) => [v.id, NG.soDigitos(v.nio_os)]));
    const ehDaOS = (x) => !!numOS[x.venda_id] && NG.soDigitos(x.pedido) === numOS[x.venda_id];
    const os = {};
    ((ro && !ro.error && ro.data) || []).forEach((x) => {
      const a = os[x.venda_id];
      if (!a || (ehDaOS(x) && !ehDaOS(a)) || (ehDaOS(x) === ehDaOS(a) && new Date(x.mudou_em) > new Date(a.mudou_em))) os[x.venda_id] = x;
    });
    const porVenda = {};
    ((rl && !rl.error && rl.data) || []).forEach((l) => { if (os[l.venda_id] && NG.soDigitos(l.pedido) !== NG.soDigitos(os[l.venda_id].pedido)) return; (porVenda[l.venda_id] = porVenda[l.venda_id] || []).push(l); });
    const nomeCurto = Object.fromEntries(((rp && rp.data) || []).map((p) => [p.id, p.nome_curto || null]));
    return { vendas, os, leituras: porVenda, nomeCurto };
  }

  const FORMA = { cartao: 'cartão', boleto: 'boleto', dacc: 'débito em conta' };
  const formaTxt = (v) => [FORMA[v.forma_pagamento], ['nfid', 'oferta50_nfid'].includes(v.plano_variante) ? 'sem fidelidade' : null].filter(Boolean).join(' · ');
  const chip = (id, dica) => { const s = STATUS_POR[id]; return `<span class="chip ${s.cls}"${dica ? ` title="${NG.esc(dica)}"` : ''}>${NG.esc(s.nome)}</span>`; };
  // Busca comum: nome, bairro, cidade, nº da OS; com 3+ dígitos também CPF/CNPJ e telefone.
  function casaBusca(v, q) {
    q = String(q || '').trim().toLowerCase();
    if (!q) return true;
    const qd = NG.soDigitos(q);
    return [v.cliente_nome, v.bairro, v.cidade, v.nio_os, v.nio_pedido].some((x) => String(x || '').toLowerCase().includes(q))
      || (qd.length >= 3 && [v.cliente_cpf_cnpj, v.cliente_whatsapp, v.nio_os, v.nio_pedido].some((x) => NG.soDigitos(x).includes(qd)));
  }
  function baixarCsv(nome, cab, linhas) {
    const q = (x) => `"${String(x ?? '').replace(/"/g, '""')}"`;
    const csv = [cab.map(q).join(';')].concat(linhas.map((l) => l.map(q).join(';'))).join('\r\n');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8' }));
    a.download = `${nome}_${NG.diaSP().replace(/-/g, '')}.csv`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 2000);
  }

  window.NGVendasOS = { INST, STATUS, STATUS_POR, COMISSOES, COLS_OS, instalada, dataOS, diaInstalacao, turno, statusDe, pendenciaTxt, textoNio, comissaoDe, reagendamentos, carregar, formaTxt, chip, casaBusca, baixarCsv };
})();
