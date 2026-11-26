/* NIOGEN | docs/assets/movel.js | 15/11/2026 13:40 — Claude Code (Opus 5.5)
 * NIOGEN no celular (protótipo aprovado pelo Ricardo: docs/LAYOUT_conversas_mobile_151126_1304.html). Carregado pelo sidebar.js
 * em todas as telas; só desenha em tela ≤ 640 px e para admin/backoffice (vendedor segue com o ☰ de sempre).
 *   · Barra inferior: Conversas · Live · Pulso · Mais (Mais = folha com o menu completo, os avisos deste aparelho e instalar).
 *     Os números da barra copiam os selos do menu lateral (sem chamada nova — regra 19).
 *   · Instalar: no navegador, um cartão discreto (Android: botão Instalar · iPhone: Compartilhar › Adicionar à Tela de Início).
 *   · Avisos (Web Push, 0215): a permissão NUNCA é pedida no carregamento. No primeiro uso do app instalado aparece um cartão
 *     "Receber os avisos do Live?"; só o toque em Ativar pede a permissão e grava a inscrição (push_inscrever). Desligar: Mais ›
 *     Avisos neste aparelho › Desligar (push_remover + cancela no navegador). Testar: push_testar (chega em ≤ 2 min).
 *   · Medida (item 6): uma linha em app_sessoes por aba aberta no app instalado (ou vinda do clique num aviso — ?envio=).
 * localStorage só para conveniências deste aparelho (cartão dispensado), sempre em try/catch.
 */
(function () {
  'use strict';
  const CEL = window.matchMedia('(max-width: 640px)');
  const instalado = () => window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone === true;
  const ls = {
    ler: (k) => { try { return localStorage.getItem(k); } catch (e) { return null; } },
    gravar: (k, v) => { try { localStorage.setItem(k, v); } catch (e) { /* sem storage: segue */ } },
  };
  const temPush = () => 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window && location.protocol === 'https:';
  let pedidoInstalar = null;   // beforeinstallprompt (Android/Chrome)
  let pagina = '';

  window.addEventListener('beforeinstallprompt', (ev) => { ev.preventDefault(); pedidoInstalar = ev; cartoes(); });
  window.addEventListener('appinstalled', () => { pedidoInstalar = null; cartoes(); NG.toast('NIOGEN instalado. Abra pelo ícone na tela inicial.', 'ok'); });

  // ---------- sessão (medida do resultado) ----------
  function registrarSessao() {
    const q = new URLSearchParams(location.search);
    const envio = q.get('envio');
    const deAviso = !!envio || q.get('de') === 'push';
    if (envio || q.get('de')) {   // limpa o endereço (o hash #conversa= / #c= fica: é ele que abre a linha)
      q.delete('envio'); q.delete('de');
      const qs = q.toString();
      history.replaceState(history.state, '', `${location.pathname}${qs ? `?${qs}` : ''}${location.hash}`);
    }
    if (!instalado() && !deAviso) return;
    try { if (sessionStorage.getItem('ng.sessao')) return; sessionStorage.setItem('ng.sessao', '1'); } catch (e) { /* segue */ }
    NG.sb.rpc('app_sessao_registrar', {
      p_modo: instalado() ? 'standalone' : 'navegador', p_tela: pagina, p_origem: deAviso ? 'push' : null,
      p_envio: /^[0-9a-f-]{36}$/i.test(envio || '') ? envio : null,
    }).then(() => {}, () => {});
  }

  // ---------- barra inferior ----------
  const ABAS = [
    { id: 'conversas', nome: 'Conversas', href: 'conversas.html', ico: '<path d="M4 5h16v11H8l-4 4z"/>', badge: 'conversas' },
    { id: 'live2', nome: 'Live', href: 'live2.html', ico: '<path d="M13 2 4 14h7l-1 8 9-12h-7z"/>', badge: 'fila2' },   // 26/11: a barra do celular abre a Live 2.0
    { id: 'pulso', nome: 'Pulso', href: 'pulso.html', ico: '<path d="M2 12h4l3-7 4 14 3-7h6"/>' },
    { id: 'mais', nome: 'Mais', ico: '<path d="M4 6h16M4 12h16M4 18h16"/>' },
  ];
  function barra() {
    if (document.querySelector('.mv-tabs')) return;
    const nav = document.createElement('nav');
    nav.className = 'mv-tabs';
    nav.setAttribute('aria-label', 'Navegação do app');
    nav.innerHTML = ABAS.map((a) => {
      const corpo = `<svg viewBox="0 0 24 24" aria-hidden="true">${a.ico}</svg><span>${a.nome}</span>`
        + (a.badge ? `<b class="mv-tab-n" data-espelho="${a.badge}" hidden></b>` : '')
        + (a.badge2 ? `<b class="mv-tab-n fogo" data-espelho="${a.badge2}" hidden></b>` : '');
      const on = a.id === pagina || (a.id === 'conversas' && pagina === 'conversas');
      return a.href
        ? `<a class="mv-tab${on ? ' on' : ''}" href="${a.href}"${on ? ' aria-current="page"' : ''}>${corpo}</a>`
        : `<button type="button" class="mv-tab" data-mais aria-haspopup="dialog">${corpo}</button>`;
    }).join('');
    document.body.appendChild(nav);
    document.body.classList.add('com-mv-tabs');
    nav.querySelector('[data-mais]').addEventListener('click', abrirMais);
    espelharSelos();
  }
  // Os selos do menu lateral (pintados pelo sidebar.js/pulso.js) aparecem na barra, sem consulta nova.
  function espelharSelos() {
    const lateral = document.getElementById('sidebar');
    if (!lateral) return;
    const copiar = () => document.querySelectorAll('.mv-tab-n[data-espelho]').forEach((b) => {
      const src = lateral.querySelector(`.badge[data-badge="${b.dataset.espelho}"]`);
      const n = src && !src.hidden ? src.textContent.trim() : '';
      b.textContent = n;
      b.hidden = !n || n === '0';
      b.classList.toggle('mv-alerta', !!(src && src.classList.contains('alerta')));
    });
    copiar();
    new MutationObserver(copiar).observe(lateral, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['hidden', 'class'] });
  }

  // ---------- folha "Mais" ----------
  async function abrirMais() {
    fecharMais();
    const veu = document.createElement('div');
    veu.className = 'mv-folha-veu';
    const f = document.createElement('section');
    f.className = 'mv-folha';
    f.setAttribute('role', 'dialog');
    f.setAttribute('aria-label', 'Mais');
    f.innerHTML = '<div class="mv-folha-pega" aria-hidden="true"></div><div class="carregando">…</div>';
    document.body.append(veu, f);
    veu.addEventListener('click', fecharMais);
    const ins = instalado();
    const est = await estadoAvisos();
    const linhasAviso = !temPush() ? '<p class="mv-folha-obs">Este navegador não recebe avisos. No iPhone, instale o app (Compartilhar › Adicionar à Tela de Início) e abra pelo ícone.</p>'
      : est.ligado ? `<p class="mv-folha-obs">Ligados neste aparelho: janela de 24 h fechando, objeção parada, documento vencendo, fatura antes do D+5, M-10 em risco${(NG.usuario || {}).perfil === 'admin' ? ' e Mari parada' : ''}. Mensagem comum de cliente não avisa.</p>
          <div class="mv-folha-bts"><button type="button" class="btn btn-sm" data-testar>Testar</button><button type="button" class="btn btn-sm btn-ghost" data-desligar>Desligar</button></div>`
      : est.negado ? '<p class="mv-folha-obs">Os avisos foram bloqueados neste aparelho. Para voltar: configurações do Android › Apps › NIOGEN (ou Chrome) › Notificações.</p>'
      : `<p class="mv-folha-obs">Desligados. Ligue para receber só o que vence: janela de 24 h, objeção parada, documentos, fatura, M-10.${ins ? '' : ' Funciona melhor com o app instalado.'}</p>
          <div class="mv-folha-bts"><button type="button" class="btn btn-sm btn-acc" data-ligar>Ativar avisos</button></div>`;
    f.innerHTML = `<div class="mv-folha-pega" aria-hidden="true"></div>
      <button type="button" class="mv-folha-item" data-menu><span>☰</span>Menu completo<small>todas as telas do NIOGEN</small></button>
      <a class="mv-folha-item" href="guia.html#no-celular"><span>?</span>Guia do Backoffice<small>No celular: instalar, abas, avisos</small></a>
      ${!ins && (pedidoInstalar || /iphone|ipad/i.test(navigator.userAgent)) ? `<button type="button" class="mv-folha-item" data-instalar><span>⇩</span>Instalar o app<small>${pedidoInstalar ? 'abre sem barra de endereço, igual app' : 'iPhone: Compartilhar › Adicionar à Tela de Início'}</small></button>` : ''}
      <div class="mv-folha-sec"><b>Avisos neste aparelho</b><span class="mv-folha-st ${est.ligado ? 'on' : ''}">${est.ligado ? 'ligados' : est.negado ? 'bloqueados' : 'desligados'}</span></div>
      ${linhasAviso}
      <button type="button" class="mv-folha-item sair" data-sair><span>⏏</span>Sair</button>`;
    f.addEventListener('click', async (ev) => {
      const b = ev.target.closest('button');
      if (!b) return;
      if (b.hasAttribute('data-menu')) { fecharMais(); const m = document.querySelector('.topo-movel .menu-btn'); if (m) m.click(); }
      else if (b.hasAttribute('data-instalar')) { fecharMais(); instalar(); }
      else if (b.hasAttribute('data-ligar')) { b.disabled = true; await ligarAvisos(); abrirMais(); }
      else if (b.hasAttribute('data-desligar')) { b.disabled = true; await desligarAvisos(); abrirMais(); }
      else if (b.hasAttribute('data-testar')) { b.disabled = true; const { data, error } = await NG.sb.rpc('push_testar'); NG.toast(error ? NG.msgErro(error) : (data && data.resumo) || 'Teste na fila', error ? 'bad' : 'ok'); b.disabled = false; }
      else if (b.hasAttribute('data-sair')) NG.sair();
    });
  }
  function fecharMais() { document.querySelectorAll('.mv-folha, .mv-folha-veu').forEach((x) => x.remove()); }
  document.addEventListener('keydown', (ev) => { if (ev.key === 'Escape') fecharMais(); });

  async function instalar() {
    if (pedidoInstalar) { pedidoInstalar.prompt(); try { await pedidoInstalar.userChoice; } catch (e) { /* */ } pedidoInstalar = null; cartoes(); return; }
    NG.toast('iPhone: toque em Compartilhar (□↑) › Adicionar à Tela de Início', 'info');
  }

  // ---------- avisos (Web Push) ----------
  const b64u8 = (b64) => {
    const p = '='.repeat((4 - (b64.length % 4)) % 4);
    const raw = atob((b64 + p).replace(/-/g, '+').replace(/_/g, '/'));
    return Uint8Array.from([...raw].map((ch) => ch.charCodeAt(0)));
  };
  async function estadoAvisos() {
    if (!temPush()) return { ligado: false, negado: false };
    if (Notification.permission === 'denied') return { ligado: false, negado: true };
    try {
      const reg = await navigator.serviceWorker.ready;
      const sub = await reg.pushManager.getSubscription();
      return { ligado: !!sub && Notification.permission === 'granted', negado: false, sub };
    } catch (e) { return { ligado: false, negado: false }; }
  }
  async function chavePublica() {
    const { data } = await NG.sb.from('config_regras').select('valor').eq('chave', 'push').maybeSingle();
    const v = data && data.valor;
    return v && v.ligado !== false ? v.vapid_publica || null : null;
  }
  async function gravar(sub) {
    const j = sub.toJSON();
    const { error } = await NG.sb.rpc('push_inscrever', { p_endpoint: j.endpoint, p_keys: j.keys, p_user_agent: navigator.userAgent });
    if (error) throw error;
  }
  async function ligarAvisos() {
    try {
      const chave = await chavePublica();
      if (!chave) { NG.toast('Os avisos ainda não estão ligados no servidor. Avise o Ricardo.', 'bad'); return false; }
      const perm = await Notification.requestPermission();   // só aqui, depois do toque
      if (perm !== 'granted') { NG.toast('Sem permissão, os avisos ficam desligados.', 'bad'); return false; }
      const reg = await navigator.serviceWorker.ready;
      let sub = await reg.pushManager.getSubscription();
      if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64u8(chave) });
      await gravar(sub);
      ls.gravar('niogen.avisos.cartao', 'feito');
      NG.toast('Avisos do Live ligados neste aparelho', 'ok');
      cartoes();
      return true;
    } catch (e) { NG.toast(`Não deu para ligar os avisos: ${NG.msgErro(e)}`, 'bad'); return false; }
  }
  async function desligarAvisos() {
    try {
      const reg = await navigator.serviceWorker.ready;
      const sub = await reg.pushManager.getSubscription();
      if (sub) { await NG.sb.rpc('push_remover', { p_endpoint: sub.endpoint }); await sub.unsubscribe(); }
      ls.gravar('niogen.avisos.cartao', 'feito');
      NG.toast('Avisos desligados neste aparelho', 'ok');
    } catch (e) { NG.toast(NG.msgErro(e), 'bad'); }
  }
  // A inscrição já existente é regravada uma vez por sessão (o banco pode tê-la desligado por 410) e quando o navegador a troca.
  async function renovar() {
    const est = await estadoAvisos();
    if (est.ligado && est.sub) { try { await gravar(est.sub); } catch (e) { /* segue */ } }
  }
  if ('serviceWorker' in navigator) navigator.serviceWorker.addEventListener('message', (ev) => { if (ev.data && ev.data.tipo === 'push-renovar') renovar(); });

  // ---------- cartões no topo (instalar / ativar avisos) ----------
  async function cartoes() {
    document.querySelectorAll('.mv-cartao').forEach((x) => x.remove());
    if (!CEL.matches || document.body.classList.contains('mv-thread')) return;
    const main = document.querySelector('main.main');
    if (!main) return;
    let html = '';
    if (instalado()) {
      // primeiro uso do app instalado: oferece os avisos (sem pedir permissão — só o toque em Ativar pede)
      if (temPush() && Notification.permission === 'default' && ls.ler('niogen.avisos.cartao') !== 'feito') {
        html = `<div class="mv-cartao"><div><b>Receber os avisos do Live?</b> Só o que vence: janela de 24 h fechando, objeção parada, documento, fatura, M-10. Mensagem comum não avisa.</div>
          <div class="mv-cartao-bts"><button type="button" class="btn btn-sm btn-acc" data-c-ligar>Ativar</button><button type="button" class="btn btn-sm btn-ghost" data-c-nao>Agora não</button></div></div>`;
      }
    } else if (ls.ler('niogen.instalar.cartao') !== 'fechado' && (pedidoInstalar || /iphone|ipad/i.test(navigator.userAgent))) {
      html = `<div class="mv-cartao"><div><b>Instalar como app:</b> ${pedidoInstalar ? 'abre sem barra de endereço, igual app, e recebe os avisos do Live.' : 'Compartilhar (□↑) › Adicionar à Tela de Início.'}</div>
        <div class="mv-cartao-bts">${pedidoInstalar ? '<button type="button" class="btn btn-sm btn-acc" data-c-instalar>Instalar</button>' : ''}<button type="button" class="mv-cartao-x" data-c-fechar aria-label="Fechar">✕</button></div></div>`;
    }
    if (!html) return;
    main.insertAdjacentHTML('afterbegin', html);
    const c = main.querySelector('.mv-cartao');
    c.addEventListener('click', async (ev) => {
      const b = ev.target.closest('button');
      if (!b) return;
      if (b.hasAttribute('data-c-ligar')) { b.disabled = true; await ligarAvisos(); }
      else if (b.hasAttribute('data-c-nao')) { ls.gravar('niogen.avisos.cartao', 'feito'); c.remove(); NG.toast('Dá para ligar depois em Mais › Avisos', 'info'); }
      else if (b.hasAttribute('data-c-instalar')) instalar();
      else if (b.hasAttribute('data-c-fechar')) { ls.gravar('niogen.instalar.cartao', 'fechado'); c.remove(); }
    });
  }

  function montar(pg) {
    pagina = pg || '';
    const u = NG.usuario || {};
    if (!u.id) return;
    registrarSessao();
    if (!['admin', 'backoffice'].includes(u.perfil)) return;
    const aplicar = () => {
      if (CEL.matches) { barra(); cartoes(); }
      else { document.querySelectorAll('.mv-tabs, .mv-cartao').forEach((x) => x.remove()); document.body.classList.remove('com-mv-tabs'); fecharMais(); }
    };
    aplicar();
    CEL.addEventListener('change', aplicar);
    renovar();
  }

  window.NGMovel = { montar, ligarAvisos, desligarAvisos };
})();
