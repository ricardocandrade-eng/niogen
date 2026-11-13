/* NIOGEN | docs/assets/osab.js | 03/11/2026
 * Leitura do relatório OSAB da Nio no navegador (SheetJS) e a mesma classificação que public.aplicar_osab()
 * faz no banco — a prévia mostra exatamente o que o "Aplicar" vai mudar. Mudou a regra lá, muda aqui.
 * 13/11/2026 (etapa 3 / 5b): lê DOIS formatos. 'email' = o OSAB que o Rogério manda (PEDIDO, SITUACAO, fg_venda_valida…).
 * 'painel' = a tabela "Exportação - OSAB" do painel Performance em Foco do portal (NR ORDEM, STATUS, DATA ATIVACAO…),
 * que NÃO traz fg_venda_valida nem código de pendência e traz o andamento do atendimento de campo (BA).
 * Levantamento: docs/LEVANTAMENTO_consulta_os_131126_0955.md (Drive). Teste: node tests/osab_formatos.js
 */
(function () {
  'use strict';

  // O arquivo é reconhecido pelas colunas, não pelo nome.
  const OBRIGATORIAS = ['PEDIDO', 'SITUACAO', 'fg_venda_valida', 'DATA_ABERTURA', 'DT_REF'];
  const OBRIGATORIAS_PAINEL = ['NR ORDEM', 'STATUS', 'DATA VENDA', 'DATA HORA - Atualização', 'DATA ATIVACAO'];

  const pad = (n, w = 2) => String(n).padStart(w, '0');

  // Datas do OSAB são hora local (Brasília). Serial do Excel → partes, sem passar pelo fuso do navegador.
  function partes(v) {
    if (v == null || v === '') return null;
    if (typeof v === 'number' && isFinite(v)) {
      const d = new Date(Math.round((v - 25569) * 86400000));
      return { y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: d.getUTCDate(), h: d.getUTCHours(), mi: d.getUTCMinutes(), s: d.getUTCSeconds() };
    }
    const s = String(v).trim();
    let m = s.match(/^(\d{2})\/(\d{2})\/(\d{4})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?/);
    if (m) return { y: +m[3], m: +m[2], d: +m[1], h: +(m[4] || 0), mi: +(m[5] || 0), s: +(m[6] || 0) };
    m = s.match(/^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?/);
    if (m) return { y: +m[1], m: +m[2], d: +m[3], h: +(m[4] || 0), mi: +(m[5] || 0), s: +(m[6] || 0) };
    return null;
  }
  const dataISO = (v) => { const p = partes(v); return p ? `${p.y}-${pad(p.m)}-${pad(p.d)}` : null; };
  const dataHoraSP = (v) => { const p = partes(v); return p ? `${p.y}-${pad(p.m)}-${pad(p.d)}T${pad(p.h)}:${pad(p.mi)}:${pad(p.s)}-03:00` : null; };

  const texto = (v) => {
    if (v == null) return null;
    const s = (typeof v === 'number' ? String(v) : String(v)).trim();
    return s === '' ? null : s;
  };
  const pedidoTexto = (v) => (typeof v === 'number' ? String(Math.round(v)) : texto(v));
  const valida = (v) => (v === 1 || v === '1' || v === true ? true : v === 0 || v === '0' || v === false ? false : null);

  // Lê o workbook (ArrayBuffer) e devolve as linhas já no formato de public.nio_osab.
  function ler(buffer) {
    const wb = XLSX.read(buffer, { type: 'array', cellDates: false });
    const ordem = wb.SheetNames.includes('Export') ? ['Export'].concat(wb.SheetNames.filter((n) => n !== 'Export')) : wb.SheetNames;
    let melhor = null;
    for (const nome of ordem) {
      const linhas = XLSX.utils.sheet_to_json(wb.Sheets[nome], { header: 1, raw: true, defval: null, blankrows: false });
      for (let i = 0; i < Math.min(linhas.length, 20); i++) {
        const cab = (linhas[i] || []).map((c) => (c == null ? '' : String(c).trim()));
        for (const [fonte, obrig] of [['email', OBRIGATORIAS], ['painel', OBRIGATORIAS_PAINEL]]) {
          const faltam = obrig.filter((c) => !cab.includes(c));
          if (!melhor || faltam.length < melhor.faltam.length) melhor = { nome, i, cab, faltam, linhas, fonte };
        }
        if (!melhor.faltam.length) break;
      }
      if (melhor && !melhor.faltam.length) break;
    }
    if (!melhor || melhor.faltam.length) {
      return { erro: `Não parece um OSAB: faltam as colunas ${(melhor ? melhor.faltam : OBRIGATORIAS).join(', ')}.` };
    }
    if (melhor.fonte === 'painel') return lerPainel(melhor);

    const idx = Object.fromEntries(melhor.cab.map((c, i) => [c, i]));
    const col = (row, nome) => (idx[nome] == null ? null : row[idx[nome]]);
    const porPedido = new Map();
    let lidas = 0;
    let semPedido = 0;
    const situacoes = {};
    const dtRefs = {};

    for (const row of melhor.linhas.slice(melhor.i + 1)) {
      if (!row || row.every((c) => c == null || c === '')) continue;
      lidas++;
      const pedido = pedidoTexto(col(row, 'PEDIDO'));
      if (!pedido) { semPedido++; continue; }
      const o = {
        pedido,
        dt_ref: dataISO(col(row, 'DT_REF')),
        produto: texto(col(row, 'PRODUTO')),
        uf: texto(col(row, 'UF')),
        localidade: texto(col(row, 'LOCALIDADE')),
        celula: texto(col(row, 'CELULA')),
        segmento: texto(col(row, 'SEGMENTO')),
        velocidade: texto(col(row, 'VELOCIDADE')),
        matricula_vendedor: texto(col(row, 'MATRICULA_VENDEDOR')),
        situacao: texto(col(row, 'SITUACAO')),
        data_agendamento: dataHoraSP(col(row, 'DATA_AGENDAMENTO')),
        data_abertura: dataHoraSP(col(row, 'DATA_ABERTURA')),
        data_fechamento: dataHoraSP(col(row, 'DATA_FECHAMENTO')),
        cod_pendencia: texto(col(row, 'COD_PENDENCIA')),
        desc_pendencia: texto(col(row, 'DESC_PENDENCIA')),
        numero_ba: texto(col(row, 'numero_ba')),
        venda_valida: valida(col(row, 'fg_venda_valida')),
        meio_pagamento: texto(col(row, 'meio_pagamento')),
        campanha: texto(col(row, 'CAMPANHA')),
        flg_mei: texto(col(row, 'flg_mei')),
        motivo_cancelamento: texto(col(row, 'motivo_cancelamento')),
        submotivo_cancelamento: texto(col(row, 'submotivo_cancelamento')),
        classificacao: texto(col(row, 'CLASSIFICACAO')),
      };
      situacoes[o.situacao || '(vazia)'] = (situacoes[o.situacao || '(vazia)'] || 0) + 1;
      if (o.dt_ref) dtRefs[o.dt_ref] = (dtRefs[o.dt_ref] || 0) + 1;
      // Pedido repetido: fica a ordem mais recente (DATA_ABERTURA maior).
      const atual = porPedido.get(pedido);
      if (!atual || String(o.data_abertura || '') > String(atual.data_abertura || '')) porPedido.set(pedido, o);
    }

    const linhas = [...porPedido.values()];
    const dtRef = Object.entries(dtRefs).sort((a, b) => b[1] - a[1])[0];
    return {
      fonte: 'email',
      aba: melhor.nome,
      lidas,
      semPedido,
      duplicadas: lidas - semPedido - linhas.length,
      linhas,
      situacoes,
      dt_ref: dtRef ? dtRef[0] : null,
    };
  }

  // Formato do painel (Exportação - OSAB do Performance em Foco). Cabeçalho na 1ª linha, dados, linha em branco e um
  // rodapé "Filtros aplicados: …" na coluna A — o rodapé não é linha de pedido e não conta como "sem pedido".
  function lerPainel(melhor) {
    const idx = Object.fromEntries(melhor.cab.map((c, i) => [c, i]));
    const col = (row, nome) => (idx[nome] == null ? null : row[idx[nome]]);
    const porPedido = new Map();
    let lidas = 0;
    let semPedido = 0;
    let filtros = null;
    const situacoes = {};
    const dtRefs = {};
    const juntar = (...p) => { const s = p.map(texto).filter(Boolean).join(' · '); return s || null; };

    for (const row of melhor.linhas.slice(melhor.i + 1)) {
      if (!row || row.every((c) => c == null || c === '')) continue;
      const primeira = texto(row[0]);
      if (primeira && /^filtros aplicados/i.test(primeira)) { filtros = primeira.replace(/\s*\n\s*/g, ' · ').slice(0, 400); continue; }
      lidas++;
      const pedido = pedidoTexto(col(row, 'NR ORDEM'));
      if (!pedido) { semPedido++; continue; }
      const atualizacao = col(row, 'DATA HORA - Atualização');
      const o = {
        pedido,
        dt_ref: dataISO(atualizacao),
        produto: texto(col(row, 'PLANO')),
        uf: texto(col(row, 'UF')),
        localidade: texto(col(row, 'MUNICIPIO')),
        celula: texto(col(row, 'CELULA')),
        segmento: texto(col(row, 'SEGMENTO')),
        velocidade: texto(col(row, 'VELOCIDADE')),
        matricula_vendedor: texto(col(row, 'MATRICULA VENDEDOR')),
        situacao: texto(col(row, 'STATUS')),
        data_agendamento: dataHoraSP(col(row, 'DATA AGENDAMENTO')),
        data_abertura: dataHoraSP(col(row, 'DATA VENDA')),
        // A data real da instalação: o fim do atendimento em campo; sem ele, a data da ativação.
        data_fechamento: dataHoraSP(col(row, 'FIM EXECUÇÃO REAL')) || dataHoraSP(col(row, 'DATA ATIVACAO')),
        cod_pendencia: null,
        desc_pendencia: texto(col(row, 'PENDENCIA BA')),
        numero_ba: texto(col(row, 'NR BA')),
        venda_valida: null,                       // o painel não traz fg_venda_valida
        meio_pagamento: texto(col(row, 'MÉTODO PGTO')),
        campanha: texto(col(row, 'CAMPANHA')),
        flg_mei: texto(col(row, 'TP MEI')),
        motivo_cancelamento: texto(col(row, 'MOTIVO ORDEM')),
        submotivo_cancelamento: juntar(col(row, 'SUB MOTIVO'), col(row, 'DETALHE MOTIVO')),
        classificacao: null,
        // só o painel traz (0168):
        fonte: 'painel',
        atualizado_nio_em: dataHoraSP(atualizacao),
        data_ativacao: dataHoraSP(col(row, 'DATA ATIVACAO')),
        estado_ba: texto(col(row, 'ESTADO BA')),
        status_ba: texto(col(row, 'STATUS BA')),
        motivo_ba: texto(col(row, 'MOTIVO BA')),
        faixa_agendamento: texto(col(row, 'FAIXA AGENDAMENTO')),
        execucao_inicio: dataHoraSP(col(row, 'INÍCIO EXECUÇÃO REAL')),
        execucao_fim: dataHoraSP(col(row, 'FIM EXECUÇÃO REAL')),
      };
      situacoes[o.situacao || '(vazia)'] = (situacoes[o.situacao || '(vazia)'] || 0) + 1;
      if (o.dt_ref) dtRefs[o.dt_ref] = (dtRefs[o.dt_ref] || 0) + 1;
      // Pedido repetido: fica a linha atualizada por último.
      const atual = porPedido.get(pedido);
      if (!atual || String(o.atualizado_nio_em || '') > String(atual.atualizado_nio_em || '')) porPedido.set(pedido, o);
    }
    const linhas = [...porPedido.values()];
    const dtRef = Object.entries(dtRefs).sort((a, b) => b[1] - a[1])[0];
    return {
      fonte: 'painel',
      aba: melhor.nome,
      lidas,
      semPedido,
      duplicadas: lidas - semPedido - linhas.length,
      linhas,
      situacoes,
      dt_ref: dtRef ? dtRef[0] : null,
      filtros,
    };
  }

  // ---------- a mesma regra de public.aplicar_osab ----------
  const cancelada = (s) => !!s && (s === 'Cancelado' || s === 'Em Cancelamento' || s.startsWith('Reprovado') || s.startsWith('Draft-'));
  const RISCO_PENDENCIA = ['VENDA INDEVIDA', 'CANCELAMENTO ERRO DE DADOS DO CLIENTE'];
  const RISCO_MOTIVO = /(venda indevida|venda errada|pedido duplicado|possui pedido fibra instalado no mesmo endere)/i;
  const risco = (validaV, desc, motivo) => validaV === false || RISCO_PENDENCIA.includes(String(desc || '').trim().toUpperCase()) || RISCO_MOTIVO.test(motivo || '');

  function pendencia(o, v) {
    const cod = String(o.cod_pendencia || '').trim();
    const desc = String(o.desc_pendencia || '').trim();
    if (!cod && !desc) return { cod: v.nio_pendencia_cod, desc: v.nio_pendencia_desc };
    if (['OK', 'N/A'].includes(desc.toUpperCase()) || ['0', '00'].includes(cod)) return { cod: null, desc: null };
    return { cod: cod || null, desc: desc || null };
  }

  // o = linha do OSAB, v = venda do NIOGEN com o mesmo pedido.
  function classificar(o, v) {
    // E-mail: concluído E venda válida. Painel (0168): não traz a validade — vale concluído com a data real da instalação.
    const concl = o.situacao === 'Concluído'
      && (o.venda_valida === true || (o.fonte === 'painel' && o.venda_valida == null && !!o.data_fechamento));
    const motivo = [o.motivo_cancelamento, o.submotivo_cancelamento].filter(Boolean).join(' ');
    let para = null;
    if (concl && ['2_aguardando_instalacao', '3_instalado'].includes(v.status)) para = '4_ativo_provisorio';
    else if (cancelada(o.situacao) && ['1_vendido', '2_aguardando_instalacao'].includes(v.status)) para = 'saida';
    const p = pendencia(o, v);
    return {
      para,
      motivoSaida: para === 'saida'
        ? 'Nio: ' + (o.motivo_cancelamento || o.situacao) + (o.submotivo_cancelamento ? ' · ' + o.submotivo_cancelamento : '') : null,
      pendencia: !para && !!p.cod && ['1_vendido', '2_aguardando_instalacao'].includes(v.status) ? p : null,
      risco: risco(o.venda_valida, o.desc_pendencia, motivo),
    };
  }

  const api = { OBRIGATORIAS, OBRIGATORIAS_PAINEL, ler, classificar };
  if (typeof window !== 'undefined') window.NGOsab = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;   // node tests/osab_formatos.js
})();
