/* NIOGEN | docs/assets/sidebar.js | 03/11/2026
 * Barra lateral igual ao mockup. Telas que ainda não existem ficam visíveis e desabilitadas ("em breve").
 * Uso: <nav class="nav" id="sidebar" data-pagina="funil"></nav> e NGSidebar.montar() depois do login.
 */
(function () {
  'use strict';

  const VERSAO = 'v0 · 03/11';

  const MENU = [
    ['Gestão', [
      { id: 'painel', ico: '◉', nome: 'Painel' },
      { id: 'placar', ico: '▤', nome: 'Placar' },
    ]],
    ['Vendas', [
      { id: 'funil', ico: '◈', nome: 'Funil', href: 'funil.html' },
      { id: 'instalacoes', ico: '⊞', nome: 'Instalações', href: 'instalacoes.html', badge: 'agendar' },
      { id: 'vendas', ico: '≡', nome: 'Vendas', href: 'vendas.html' },
      { id: 'fila', ico: '☷', nome: 'Fila Vero' },
    ]],
    ['Mari', [
      { id: 'mari', ico: '◎', nome: 'Mari · IA' },
      { id: 'meta', ico: '▲', nome: 'Meta Ads' },
    ]],
    ['Financeiro', [
      { id: 'adimplencia', ico: '◇', nome: 'Adimplência' },
      { id: 'conciliacao', ico: '◆', nome: 'Conciliação' },
    ]],
    ['Sistema', [
      { id: 'config', ico: '⚙', nome: 'Configurações' },
      { id: 'senha', ico: '◌', nome: 'Alterar senha' },
    ]],
  ];

  function iniciais(nome) {
    const p = String(nome || '').trim().split(/\s+/).filter(Boolean);
    if (!p.length) return '?';
    return (p.length > 1 ? p[0][0] + p[p.length - 1][0] : p[0].slice(0, 2)).toUpperCase();
  }

  function relogio() {
    const d = new Date();
    const f = (o) => new Intl.DateTimeFormat('pt-BR', { timeZone: NG.TZ, ...o }).format(d);
    return `${f({ weekday: 'short' }).replace('.', '')} ${f({ day: '2-digit', month: '2-digit' })} · ${f({ hour: '2-digit', minute: '2-digit' })} · ${VERSAO}`;
  }

  function item(it, ativo) {
    const conteudo = `<span class="ico" aria-hidden="true">${it.ico}</span>${NG.esc(it.nome)}` +
      (it.badge ? `<span class="badge" data-badge="${it.badge}" hidden></span>` : '');
    if (!it.href) {
      return `<span class="nav-item off" aria-disabled="true" title="em breve">${conteudo}</span>`;
    }
    return `<a class="nav-item${ativo ? ' ativo' : ''}" href="${it.href}"${ativo ? ' aria-current="page"' : ''}>${conteudo}</a>`;
  }

  async function montar() {
    const nav = document.getElementById('sidebar');
    if (!nav) return;
    const pagina = nav.dataset.pagina;
    const u = NG.usuario || {};
    nav.setAttribute('aria-label', 'Menu principal');
    nav.innerHTML = `
      <div class="nav-brand">
        <span class="kicker">Dharma Telecom · Nio</span>
        <h2>NIO<span>GEN</span></h2>
        <p>Renascer. Reconstruir. Crescer.</p>
        <p class="clock" data-relogio>${relogio()}</p>
      </div>
      <div class="nav-user">
        <div class="nav-avatar" aria-hidden="true">${NG.esc(iniciais(u.nome))}</div>
        <div class="nav-user-txt"><strong>${NG.esc(u.nome || '')}</strong><span>${NG.esc(NG.PERFIS[u.perfil] || '')}</span></div>
      </div>
      <div class="nav-items">
        ${MENU.map(([sec, itens]) => `<div class="nav-sec">${sec}</div>${itens.map((it) => item(it, it.id === pagina)).join('')}`).join('')}
      </div>
      <div class="nav-foot"><button type="button" class="nav-item" data-sair><span class="ico" aria-hidden="true">⏏</span>Sair</button></div>`;

    nav.querySelector('[data-sair]').addEventListener('click', NG.sair);
    setInterval(() => { const r = nav.querySelector('[data-relogio]'); if (r) r.textContent = relogio(); }, 30000);

    // Badge de Instalações: vendas esperando agendamento.
    const { count } = await NG.sb.from('v_instalacoes').select('id', { count: 'exact', head: true }).eq('coluna', 'agendar');
    const b = nav.querySelector('[data-badge="agendar"]');
    if (b && count) { b.textContent = count; b.hidden = false; }
  }

  window.NGSidebar = { montar };
})();
