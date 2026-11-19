/* NIOGEN | docs/parceiro/graficos.js | 19/11/2026 — Claude Code (Opus 5.5).
 * Gráficos do Pocket do Parceiro, em SVG puro (sem biblioteca): ganhos por mês, pago × a receber.
 * Pago = verde Nio sólido; a receber = mesmo verde com hachura (a diferença não depende só da cor). Toque/hover mostra o valor.
 * window.PG.ganhosPorMes(pagamentos, hojeISO, n) → [{mes, rot, pago, previsto}] · window.PG.barras(el, meses, {altura}) desenha e liga o toque.
 */
(function () {
  'use strict';
  const MESES = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'];
  const moeda = (v) => Number(v || 0).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL', minimumFractionDigits: Number(v) % 1 ? 2 : 0, maximumFractionDigits: 2 });
  const curto = (v) => (v >= 1000 ? `R$ ${(v / 1000).toLocaleString('pt-BR', { maximumFractionDigits: 1 })} mil` : moeda(v));
  const mesDe = (iso) => String(iso || '').slice(0, 7);
  const somaMes = (ym, d) => { const [a, m] = ym.split('-').map(Number); const t = new Date(Date.UTC(a, m - 1 + d, 1)); return `${t.getUTCFullYear()}-${String(t.getUTCMonth() + 1).padStart(2, '0')}`; };

  // Ganhos por mês: o pago conta no mês em que caiu; o previsto, no mês da sexta. Abatimento da largada (negativo) não entra.
  function ganhosPorMes(pags, hojeISO, n) {
    const atual = mesDe(hojeISO);
    const temFuturo = (pags || []).some((g) => g.status !== 'pago' && g.vence_em && mesDe(g.vence_em) > atual);
    const fim = temFuturo ? somaMes(atual, 1) : atual;
    const meses = [];
    for (let i = (n || 6) - 1; i >= 0; i--) { const ym = somaMes(fim, -i); meses.push({ mes: ym, rot: MESES[Number(ym.slice(5)) - 1], pago: 0, previsto: 0, atual: ym === atual }); }
    const idx = Object.fromEntries(meses.map((m, i) => [m.mes, i]));
    (pags || []).forEach((g) => {
      const v = Number(g.valor || 0);
      if (!(v > 0)) return;
      if (g.status === 'pago') { const k = mesDe(g.pago_em || g.vence_em); if (k in idx) meses[idx[k]].pago += v; }
      else if (g.status === 'previsto' && g.vence_em) { const k = mesDe(g.vence_em); if (k in idx) meses[idx[k]].previsto += v; }
    });
    return meses;
  }

  let seq = 0;
  function barras(el, meses, opts) {
    if (!el) return;
    const o = opts || {};
    const W = 320, H = o.altura || 150, topo = 22, base = H - 22;
    const n = meses.length;
    const passo = W / n, larg = Math.min(30, passo * 0.5);
    const total = (m) => m.pago + m.previsto;
    const max = Math.max(1, ...meses.map(total));
    const y = (v) => base - (v / max) * (base - topo);
    const id = `pg-hach-${++seq}`;
    const temPrev = meses.some((m) => m.previsto > 0);
    const iMax = meses.reduce((b, m, i) => (total(m) > total(meses[b]) ? i : b), 0);
    // Rótulo direto só no mês atual e no maior mês (o resto aparece no toque).
    const rotular = new Set([meses.findIndex((m) => m.atual), total(meses[iMax]) > 0 ? iMax : -1].filter((i) => i >= 0 && total(meses[i]) > 0));
    const topoArred = (x, y0, w, h) => {
      const r = Math.min(4, h, w / 2);
      return `M${x},${y0 + h}V${y0 + r}Q${x},${y0} ${x + r},${y0}H${x + w - r}Q${x + w},${y0} ${x + w},${y0 + r}V${y0 + h}Z`;
    };
    const cols = meses.map((m, i) => {
      const cx = passo * i + passo / 2, x = cx - larg / 2;
      const yPago = y(m.pago), yTot = y(total(m));
      const hPago = base - yPago, hPrev = yPago - yTot;
      const gap = m.pago > 0 && m.previsto > 0 ? 2 : 0;
      let marcas = '';
      if (total(m) <= 0) marcas = `<rect x="${x}" y="${base - 2}" width="${larg}" height="2" rx="1" class="pg-zero"/>`;
      else {
        // O segmento de cima leva o canto arredondado; o de baixo fica reto, com 2px de folga entre os dois.
        if (m.previsto > 0) marcas += `<path d="${topoArred(x, yTot, larg, Math.max(1, hPrev - gap))}" fill="url(#${id})" class="pg-prev"/>`;
        if (m.pago > 0) marcas += m.previsto > 0 ? `<rect x="${x}" y="${yPago}" width="${larg}" height="${Math.max(1, hPago)}" class="pg-pago"/>` : `<path d="${topoArred(x, yPago, larg, Math.max(1, hPago))}" class="pg-pago"/>`;
      }
      const lbl = rotular.has(i) ? `<text x="${cx}" y="${yTot - 6}" text-anchor="middle" class="pg-val">${curto(total(m))}</text>` : '';
      return `<g class="pg-col${m.atual ? ' atual' : ''}" data-i="${i}" tabindex="0" role="listitem" aria-label="${m.rot}: ${moeda(m.pago)} pago${m.previsto ? `, ${moeda(m.previsto)} a receber` : ''}">
        <rect x="${passo * i}" y="0" width="${passo}" height="${H}" fill="transparent"/>${marcas}${lbl}
        <text x="${cx}" y="${H - 6}" text-anchor="middle" class="pg-mes">${m.rot}</text></g>`;
    }).join('');
    el.innerHTML = `<div class="pg-legenda"><span><i class="pg-chave pago"></i>Pago</span>${temPrev ? '<span><i class="pg-chave prev"></i>A receber</span>' : ''}</div>
      <div class="pg-area"><svg viewBox="0 0 ${W} ${H}" role="list" aria-label="${o.titulo || 'Ganhos por mês'}">
        <defs><pattern id="${id}" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
          <rect width="6" height="6" class="pg-prev-fundo"/><rect width="2.5" height="6" class="pg-prev-risco"/></pattern></defs>
        <line x1="0" x2="${W}" y1="${base}" y2="${base}" class="pg-base"/>${cols}</svg>
        <div class="pg-dica" hidden></div></div>`;
    const dica = el.querySelector('.pg-dica');
    const svg = el.querySelector('svg');
    let fixo = null;
    const mostrar = (g) => {
      const m = meses[Number(g.dataset.i)];
      dica.innerHTML = `<b>${m.rot}${m.atual ? ' · este mês' : ''}</b><span><i class="pg-chave pago"></i>Pago <b>${moeda(m.pago)}</b></span>${m.previsto ? `<span><i class="pg-chave prev"></i>A receber <b>${moeda(m.previsto)}</b></span>` : ''}`;
      dica.hidden = false;
      el.querySelectorAll('.pg-col').forEach((c) => c.classList.toggle('foco', c === g));
      const caixa = svg.getBoundingClientRect(), area = el.querySelector('.pg-area').getBoundingClientRect();
      const cx = ((Number(g.dataset.i) + 0.5) / n) * caixa.width + (caixa.left - area.left);
      const w = dica.offsetWidth;
      dica.style.left = `${Math.max(0, Math.min(area.width - w, cx - w / 2))}px`;
    };
    const esconder = () => { if (fixo) return; dica.hidden = true; el.querySelectorAll('.pg-col').forEach((c) => c.classList.remove('foco')); };
    el.querySelectorAll('.pg-col').forEach((g) => {
      g.addEventListener('pointerenter', (ev) => { if (ev.pointerType === 'mouse') mostrar(g); });
      g.addEventListener('pointerleave', (ev) => { if (ev.pointerType === 'mouse') esconder(); });
      g.addEventListener('focus', () => mostrar(g));
      g.addEventListener('blur', () => { fixo = null; esconder(); });
      g.addEventListener('click', () => { if (fixo === g) { fixo = null; esconder(); } else { fixo = g; mostrar(g); } });
    });
  }

  window.PG = { ganhosPorMes, barras, moeda };
})();
