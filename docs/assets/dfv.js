/* NIOGEN | docs/assets/dfv.js | 03/11/2026
 * Leitor do CSV da base DFV da Nio (HP/HC por fachada, ~45 MB) para a prévia em Configurações › Importação.
 * Lê em streaming no navegador (não carrega o arquivo inteiro na memória) e só conta: nada sai do navegador.
 * Os totais seguem a mesma regra de aplicar_dfv (migration 0011): linha repetida pela chave
 * COD_SURVEY + NO_FACHADA + COMPLEMENTO1 conta uma vez. A gravação ainda é pelo CLI (supabase/scripts/dfv_carga.py).
 */
(function () {
  'use strict';

  const OBRIGATORIAS = ['COD_SURVEY', 'NO_FACHADA', 'COMPLEMENTO1', 'CEP', 'BAIRRO', 'MUNICIPIO', 'UF', 'HP_TOT', 'HP_LIVRE', 'HC_TOT', 'dt_dfv_particao'];

  // Reconhece pelo cabeçalho (como o OSAB): COD_SURVEY, HP_LIVRE e dt_dfv_particao.
  function ehDfv(cabecalho) {
    const c = String(cabecalho || '').replace(/^﻿/, '').split(';').map((s) => s.trim());
    return ['COD_SURVEY', 'HP_LIVRE', 'dt_dfv_particao'].every((k) => c.includes(k));
  }

  async function primeiraLinha(file) {
    const txt = await file.slice(0, 8192).text();
    return txt.split(/\r?\n/)[0];
  }

  // epoch em ms → AAAA-MM-DD (UTC: 1793664000000 = 2026-11-03).
  const particaoISO = (ms) => new Date(Number(ms)).toISOString().slice(0, 10);

  async function ler(file, aoProgresso) {
    const leitor = file.stream().pipeThrough(new TextDecoderStream('utf-8')).getReader();
    let resto = '';
    let cab = null;
    let idx = null;
    let lidos = 0;
    const t = { linhas: 0, repetidas: 0, ruins: 0, hp_tot: 0, hp_livre: 0, hc_tot: 0, casas_ocupadas: 0 };
    const chaves = new Set(), bairros = new Set(), ceps = new Set(), municipios = new Set(), particoes = new Set();
    const num = (v) => (/^-?\d+$/.test(v) ? Number(v) : 0);

    function linha(l) {
      if (!l) return;
      if (!cab) {
        cab = l.replace(/^﻿/, '').split(';').map((s) => s.trim());
        idx = Object.fromEntries(cab.map((c, i) => [c, i]));
        return;
      }
      const r = l.split(';');
      if (r.length !== cab.length) { t.ruins++; return; }
      const k = `${r[idx.COD_SURVEY]}|${r[idx.NO_FACHADA]}|${r[idx.COMPLEMENTO1]}`;
      if (chaves.has(k)) { t.repetidas++; return; }
      chaves.add(k);
      t.linhas++;
      const hpTot = num(r[idx.HP_TOT]), hcTot = num(r[idx.HC_TOT]);
      t.hp_tot += hpTot;
      t.hp_livre += num(r[idx.HP_LIVRE]);
      t.hc_tot += hcTot;
      if (hpTot === 1 && hcTot >= 1) t.casas_ocupadas++;
      bairros.add(r[idx.BAIRRO]);
      ceps.add(r[idx.CEP]);
      municipios.add(`${r[idx.UF]} · ${r[idx.MUNICIPIO]}`);
      particoes.add(r[idx.dt_dfv_particao]);
    }

    for (;;) {
      const { value, done } = await leitor.read();
      if (done) break;
      lidos += value.length;
      const partes = (resto + value).split('\n');
      resto = partes.pop();
      for (const p of partes) linha(p.replace(/\r$/, ''));
      if (cab && !('COD_SURVEY' in idx)) break;   // não é DFV: para de ler
      if (aoProgresso) aoProgresso(Math.min(1, lidos / file.size));
    }
    linha(resto.replace(/\r$/, ''));

    const faltam = OBRIGATORIAS.filter((c) => !(c in (idx || {})));
    if (faltam.length) return { erro: `Faltam colunas do DFV: ${faltam.join(', ')}.` };
    return {
      ...t,
      colunas: cab.length,
      bairros: bairros.size,
      ceps: ceps.size,
      municipios: [...municipios],
      particoes: [...particoes].filter(Boolean).map(particaoISO),
    };
  }

  window.NGDfv = { ehDfv, primeiraLinha, ler };
})();
