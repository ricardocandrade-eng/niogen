/* NIOGEN | docs/assets/sidebar.js | 03/11/2026 · 04/11 menu ☰ no celular · 05/11 telas "em breve" abrem embreve.html
 * 05/11 (prompt 14b): Adimplência e Conciliação saíram de "em breve" — só admin/backoffice (vendedor não vê o item).
 * Barra lateral igual ao mockup. Telas que ainda não existem ficam visíveis e desabilitadas ("em breve").
 * 06/11 (prompt 25): Parceiros PAP (Vendas) e Pagamentos a parceiros (Financeiro) — só admin/backoffice, somem para o vendedor.
 * 04/11 (prompt 13): Funil saiu do menu — virou a vista Quadro da tela Vendas (funil.html redireciona).
 * 06/11 (prompt 27): contadores em "Mari · IA" (conversas aguardando humano — v_mari_aguardando_humano; vermelho se alguma
 * passou de 15 min em horário de contato) e em "Vendas" (novas em Qualificado desde a última visita — usuario_vistos — mais as
 * que precisam de ação). Consulta a cada 60 s (sem Realtime no Supabase Nio) e o total vai para o título da aba.
 * 08/11: link discreto "Guia do Backoffice" sob a data/versão (guia.html), com "• atualizado" se o guia foi publicado depois da
 * última leitura (localStorage niogen.guia.visto, em try/catch).
 * 09/11 (0082, prompt fluxo único): "Minha vez" (fila.html) é a 1ª do menu para admin/backoffice; o número = total da Fila
 * (NG.filaItens: conversas esperando o time + mensagens "mandar à mão" + vendas/instalações vermelhas ou amarelas).
 * Uso: <nav class="nav" id="sidebar" data-pagina="vendas"></nav> e NGSidebar.montar() depois do login.
 */
(function () {
  'use strict';

  const VERSAO = 'v1.3 · 06/11';

  const MENU = [
    ['Backoffice', [
      { id: 'minhavez', ico: '☰', nome: 'Minha vez', href: 'fila.html', perfis: ['admin', 'backoffice'], esconder: true, badge: 'fila' },
    ]],
    ['Gestão', [
      { id: 'painel', ico: '◉', nome: 'Painel', href: 'painel.html' },
      { id: 'placar', ico: '▤', nome: 'Placar', breve: true },
    ]],
    ['Vendas', [
      { id: 'vendas', ico: '≡', nome: 'Vendas', href: 'vendas.html', badge: 'vendas' },
      { id: 'instalacoes', ico: '⊞', nome: 'Instalações', href: 'instalacoes.html', badge: 'agendar' },
      { id: 'parceiros', ico: '⚑', nome: 'Parceiros PAP', href: 'parceiros.html', perfis: ['admin', 'backoffice'], esconder: true },
      { id: 'tabela', ico: '▦', nome: 'Tabela e política', href: 'tabela.html' },
      { id: 'cobertura', ico: '⌖', nome: 'Cobertura (DFV)', href: 'cobertura.html' },
      { id: 'fila', ico: '☷', nome: 'Fila Vero', breve: true },
    ]],
    ['Mari', [
      { id: 'mari', ico: '◎', nome: 'Mari · IA', href: 'mari.html', perfis: ['admin', 'backoffice'], esconder: true, badge: 'mari' },
      { id: 'meta', ico: '▲', nome: 'Meta Ads', href: 'metaads.html' },
    ]],
    ['Financeiro', [
      { id: 'adimplencia', ico: '◇', nome: 'Adimplência', href: 'adimplencia.html', perfis: ['admin', 'backoffice'], esconder: true },
      { id: 'conciliacao', ico: '◆', nome: 'Conciliação', href: 'conciliacao.html', perfis: ['admin', 'backoffice'], esconder: true },
      { id: 'pagamentos', ico: '◈', nome: 'Pagamentos a parceiros', href: 'pagamentos.html', perfis: ['admin', 'backoffice'], esconder: true },
    ]],
    ['Sistema', [
      { id: 'config', ico: '⚙', nome: 'Configurações', href: 'configuracoes.html', perfis: ['admin', 'backoffice'] },
      { id: 'senha', ico: '◌', nome: 'Alterar senha', breve: true },
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
    // esconder: o item some (em vez de "em breve") para quem não tem o perfil — ex.: vendedor não vê a Mari.
    if (it.esconder && it.perfis && !it.perfis.includes((NG.usuario || {}).perfil)) return '';
    const conteudo = `<span class="ico" aria-hidden="true">${it.ico}</span>${NG.esc(it.nome)}` +
      (it.badge ? `<span class="badge" data-badge="${it.badge}" hidden></span>` : '') +
      (it.breve ? '<span class="tag-breve">em breve</span>' : '');
    // Telas "em breve" (05/11): abrem embreve.html com a frase do que vão mostrar, e o menu marca a atual.
    if (it.breve) return `<a class="nav-item breve${ativo ? ' ativo' : ''}" href="embreve.html?tela=${it.id}"${ativo ? ' aria-current="page"' : ''}>${conteudo}</a>`;
    if (!it.href || (it.perfis && !it.perfis.includes((NG.usuario || {}).perfil))) {
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
        <a class="nav-guia${pagina === 'guia' ? ' ativo' : ''}" href="guia.html" data-guia title="Como trabalhar com a Mari, o Chatwoot e o NIOGEN">Guia do Backoffice<span class="novo" data-guia-novo hidden>• atualizado</span></a>
      </div>
      <div class="nav-user">
        <div class="nav-avatar" aria-hidden="true">${NG.esc(iniciais(u.nome))}</div>
        <div class="nav-user-txt"><strong>${NG.esc(u.nome || '')}</strong><span>${NG.esc(NG.PERFIS[u.perfil] || '')}</span></div>
      </div>
      <div class="nav-items">
        ${MENU.map(([sec, itens]) => { const h = itens.map((it) => item(it, it.id === pagina)).join(''); return h ? `<div class="nav-sec">${sec}</div>${h}` : ''; }).join('')}
      </div>
      <div class="nav-foot"><button type="button" class="nav-item" data-sair><span class="ico" aria-hidden="true">⏏</span>Sair</button></div>`;

    nav.querySelector('[data-sair]').addEventListener('click', NG.sair);
    setInterval(() => { const r = nav.querySelector('[data-relogio]'); if (r) r.textContent = relogio(); }, 30000);
    menuMovel(nav, pagina);
    guiaNovo(nav, pagina);

    // Badge de Instalações: vendas esperando agendamento.
    const { count } = await NG.sb.from('v_instalacoes').select('id', { count: 'exact', head: true }).eq('coluna', 'agendar');
    const b = nav.querySelector('[data-badge="agendar"]');
    if (b && count) { b.textContent = count; b.hidden = false; }

    // Prompt 27: avisos de Mari (aguardando humano) e Vendas (novas + precisam de ação). O Realtime não está ligado no
    // Supabase Nio (publicação vazia): consulta a cada 60 s. O total vai também para o título da aba: "(3) Vendas · NIOGEN".
    tituloBase = document.title.replace(/^\(\d+\)\s*/, '');
    if (pagina === 'vendas') {
      // Abriu Vendas = viu as novas. "Visto em" fica no banco (por usuário), não no navegador.
      await NG.sb.from('usuario_vistos').upsert({ usuario_id: u.id, tela: 'vendas', visto_em: new Date().toISOString() }, { onConflict: 'usuario_id,tela' });
    }
    await avisos(nav);
    setInterval(() => avisos(nav), 60000);
  }

  // ---------- Guia do Backoffice (08/11): "• atualizado" se foi publicado depois da última vez que você abriu ----------
  async function guiaNovo(nav, pagina) {
    if (pagina === 'guia') return;   // a própria tela grava o "visto"
    try {
      const { data } = await NG.sb.from('conteudos').select('publicado_em, rev').eq('chave', 'guia_backoffice').maybeSingle();
      if (!data) return;
      let visto = null;
      try { visto = localStorage.getItem('niogen.guia.visto'); } catch (e) { /* modo privado: sem o ponto */ return; }
      const el = nav.querySelector('[data-guia-novo]');
      const novo = !visto || new Date(data.publicado_em) > new Date(visto);
      if (el) el.hidden = !novo;
      const a = nav.querySelector('[data-guia]');
      if (a && data.rev) a.title = `Guia do Backoffice · rev. ${data.rev}${novo ? ' · atualizado desde a sua última leitura' : ''}`;
    } catch (e) { /* o link do guia nunca derruba o menu */ }
  }

  // ---------- contadores do menu (prompt 27) ----------
  let tituloBase = '';
  // Horário do contrato (seg–sex 9–21, sáb 10–16): o atraso de 15 min só conta dentro dele.
  function noHorario(d) {
    const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: NG.TZ, weekday: 'short', hour: 'numeric', hour12: false }).formatToParts(d).map((x) => [x.type, x.value]));
    const h = Number(p.hour) % 24;
    if (p.weekday === 'Sun') return false;
    return p.weekday === 'Sat' ? h >= 10 && h < 16 : h >= 9 && h < 21;
  }
  function pinta(nav, chave, n, cls, titulo) {
    const el = nav.querySelector(`[data-badge="${chave}"]`);
    if (!el) return;
    el.textContent = n || '';
    el.hidden = !n;
    el.className = `badge${cls ? ` ${cls}` : ''}`;
    el.title = titulo;
    const item = el.closest('.nav-item');
    if (item) item.title = n ? titulo : '';
  }
  async function avisos(nav) {
    const u = NG.usuario || {};
    let total = 0;
    try {
      if (['admin', 'backoffice'].includes(u.perfil) && nav.querySelector('[data-badge="mari"]')) {
        const [{ data, error }, rsr] = await Promise.all([
          NG.sb.from('v_mari_aguardando_humano').select('id, ult_lead'),
          NG.sb.from('v_mari_sem_resposta').select('id'),   // 0081: cliente sem resposta (nem Mari, nem time) há ≥ 3 min
        ]);
        if (!error) {
          const lista = data || [];
          const ids = new Set(lista.map((a) => a.id));
          const silencio = (rsr && !rsr.error ? rsr.data || [] : []).filter((x) => !ids.has(x.id));
          const n = lista.length + silencio.length;
          const agora = new Date();
          const atrasada = silencio.length > 0 || (noHorario(agora) && lista.some((a) => (agora - new Date(a.ult_lead)) > 15 * 60000));
          pinta(nav, 'mari', n, atrasada ? 'alerta' : 'info',
            `${lista.length} ${lista.length === 1 ? 'conversa esperando' : 'conversas esperando'} alguém do time${silencio.length ? ` · ${silencio.length} sem resposta da Mari` : ''}${atrasada && !silencio.length ? ' — alguma há mais de 15 min' : ''}. ${NG.ajuda.menu_mari}`);
          total += n;
        }
      }
      let funil = null, ultC = null;
      if (nav.querySelector('[data-badge="vendas"]')) {
        const [rv, rc, rs] = await Promise.all([
          NG.sb.from('v_funil').select('*').neq('status', 'saida').limit(2000),
          NG.sb.from('contatos_cliente').select('venda_id, em').order('em', { ascending: false }).limit(5000),
          NG.sb.from('usuario_vistos').select('visto_em').eq('tela', 'vendas').maybeSingle(),
        ]);
        if (!rv.error) {
          const ult = NG.ultimosContatos(rc.data || []);
          funil = rv.data || []; ultC = ult;
          const visto = rs.data ? new Date(rs.data.visto_em) : null;
          const ids = new Set();
          let novas = 0, acao = 0;
          (rv.data || []).forEach((v) => {
            const nova = v.status === '0_qualificado' && (!visto || new Date(v.criado_em) > visto);
            const precisa = !!NG.proximoPasso(v, ult[v.id]).acao;
            if (nova) novas += 1;
            if (precisa) acao += 1;
            if (nova || precisa) ids.add(v.id);
          });
          pinta(nav, 'vendas', ids.size, novas ? 'alerta' : 'info',
            `${novas} ${novas === 1 ? 'venda nova' : 'vendas novas'} em Qualificado desde a sua última visita · ${acao} ${acao === 1 ? 'precisa' : 'precisam'} de ação. ${NG.ajuda.menu_vendas}`);
          total += ids.size;
        }
      }
      // 0082: número da Fila "Minha vez" (não soma no título: as mesmas vendas já contam em Vendas).
      if (['admin', 'backoffice'].includes(u.perfil) && nav.querySelector('[data-badge="fila"]') && funil) {
        const rf = await NG.sb.from('v_fila_backoffice').select('*');
        if (!rf.error) {
          const itens = NG.filaItens(rf.data || [], funil, ultC);
          const verm = itens.filter((x) => x.nivel === 'bad').length;
          pinta(nav, 'fila', itens.length, verm ? 'alerta' : 'info', `${itens.length} na sua fila · ${verm} em vermelho (prazo do contrato ou cliente esperando).`);
        }
      }
    } catch (e) { /* aviso do menu nunca derruba a tela */ }
    document.title = total ? `(${total}) ${tituloBase}` : tituloBase;
  }

  // Celular (≤ 760 px): o menu fica atrás do ☰ numa barra fina no topo; abre por cima da tela e fecha com
  // ×/Esc/clique fora ou ao escolher um item. No desktop a barra não aparece (CSS).
  function menuMovel(nav, pagina) {
    if (document.querySelector('.topo-movel')) return;
    const atual = MENU.flatMap(([, itens]) => itens).find((it) => it.id === pagina);
    const topo = document.createElement('div');
    topo.className = 'topo-movel';
    topo.innerHTML = '<button type="button" class="menu-btn" aria-label="Abrir menu" aria-controls="sidebar" aria-expanded="false">☰</button>'
      + `<strong>NIO<span>GEN</span></strong><span class="pag">${NG.esc(atual ? atual.nome : '')}</span>`;
    nav.parentElement.insertBefore(topo, nav);
    const btn = topo.querySelector('.menu-btn');
    let veu = null;
    const fechar = () => {
      nav.classList.remove('aberto');
      btn.setAttribute('aria-expanded', 'false');
      if (veu) { veu.remove(); veu = null; }
    };
    const abrir = () => {
      nav.classList.add('aberto');
      btn.setAttribute('aria-expanded', 'true');
      veu = document.createElement('div');
      veu.className = 'nav-veu';
      veu.addEventListener('click', fechar);
      document.body.appendChild(veu);
      const ativo = nav.querySelector('.nav-item.ativo') || nav.querySelector('a.nav-item');
      if (ativo) ativo.focus({ preventScroll: true });
    };
    btn.addEventListener('click', () => (nav.classList.contains('aberto') ? fechar() : abrir()));
    nav.addEventListener('click', (ev) => { if (ev.target.closest('a.nav-item')) fechar(); });
    document.addEventListener('keydown', (ev) => { if (ev.key === 'Escape' && nav.classList.contains('aberto')) { fechar(); btn.focus(); } });
    window.matchMedia('(min-width: 761px)').addEventListener('change', (m) => { if (m.matches) fechar(); });
  }

  // 09/11: o botão "Atualizar" das telas (NG.botaoAtualizar) refaz os contadores do menu junto com os dados.
  window.NGSidebar = { montar, avisos: () => { const nav = document.getElementById('sidebar'); return nav ? avisos(nav) : null; } };
})();
