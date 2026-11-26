/* NIOGEN | docs/assets/sidebar.js | 03/11/2026 · 04/11 menu ☰ no celular · 05/11 telas "em breve" abrem embreve.html
 * 05/11 (prompt 14b): Adimplência e Conciliação saíram de "em breve" — só admin/backoffice (vendedor não vê o item).
 * Barra lateral igual ao mockup. Telas que ainda não existem ficam visíveis e desabilitadas ("em breve").
 * 06/11 (prompt 25): Parceiros PAP (Vendas) e Pagamentos a parceiros (Financeiro) — só admin/backoffice, somem para o vendedor.
 * 04/11 (prompt 13): Funil saiu do menu — virou a vista Quadro da tela Vendas (funil.html redireciona).
 * 13/11 (etapa 4b): funil.html volta como o relatório "Funil de vendas" (v_leads); vendas.html vira "Quadro de vendas".
 * 22/11 (novo layout, passo 2): "Funil de vendas" saiu do menu — o Funil é a faixa do topo da tela Leads (funil.html redireciona).
 * 22/11 (novo layout, passo 1): "Quadro de vendas" passa a se chamar Vendas (só venda com OS gerada) e "Operações", Instalações.
 * O selo das vendas novas em Lead qualificado foi para Leads (quem ainda não tem OS aparece lá, não mais em Vendas).
 * 06/11 (prompt 27): contadores em "Mari · IA" (conversas aguardando humano — v_mari_aguardando_humano; vermelho se alguma
 * passou de 15 min em horário de contato) e em "Vendas" (novas em Qualificado desde a última visita — usuario_vistos — mais as
 * que precisam de ação). Consulta a cada 60 s (sem Realtime no Supabase Nio) e o total vai para o título da aba.
 * 08/11: link discreto "Guia do Backoffice" sob a data/versão (guia.html), com "• atualizado" se o guia foi publicado depois da
 * última leitura (localStorage niogen.guia.visto, em try/catch).
 * 09/11 (0082, prompt fluxo único): "Live" (fila.html) é a 1ª do menu para admin/backoffice.
 * 09/11 (0090, jornada única): Live, Funil e Mari contam pela MESMA regra — v_jornada.precisa_acao.
 * Uso: <nav class="nav" id="sidebar" data-pagina="vendas"></nav> e NGSidebar.montar() depois do login.
 * 23/11 (0361, perfil agencia): a agência da Meta Ads vê só Meta Ads, Placar e Tabela — sem Guia, Consulta, balanço, selos e
 * contadores (nada disso é dela, e o banco não devolve).
 * 15/11 (NIOGEN no celular): item "Pulso" (pulso.html, a aba do Pulso) no Backoffice, e carga de assets/movel.js (barra inferior,
 * instalar, avisos Web Push e sessão do app) — um lugar só, sem tocar no <head> de cada tela.
 */
(function () {
  'use strict';

  const VERSAO = 'v1.3 · 06/11';

  // 22/11 (Ricardo: "organiza os itens do menu" → "Pela rotina"): seções pelo uso do dia — atender, vender, acompanhar,
  // financeiro e cadastros. Saíram os itens "em breve" (Placar e Alterar senha; embreve.html segue existindo).
  // 22/11 (novo layout, passo 6): o Placar voltou ao menu como tela de verdade (placar.html), em Acompanhamento.
  const MENU = [
    ['Atendimento', [
      // 26/11 (Ricardo: "Coloque o link da Live 2.0 no topo, com notificação caso tenha coisa pra fazer. E deixe a Live 1.0 abaixo,
      // sem indicadores e sem a bolinha vermelha, até eu decidir removê-la"): a 2.0 é a 1ª, com o número da fila dela (live2_fila);
      // a 1.0 fica logo abaixo, só o link.
      { id: 'live2', ico: '', nome: 'Live 2.0', vivo: true, href: 'live2.html', perfis: ['admin', 'backoffice'], esconder: true, badge: 'fila2', badge2: 'oport' },
      { id: 'minhavez', ico: '▤', nome: 'Live 1.0', href: 'fila.html', perfis: ['admin', 'backoffice'], esconder: true },
      { id: 'conversas', ico: '✉', nome: 'Conversas', href: 'conversas.html', perfis: ['admin', 'backoffice'], esconder: true, badge: 'conversas' },
      { id: 'cobertura', ico: '⌖', nome: 'Cobertura', href: 'cobertura.html' },   // 11/11: + crédito (antiga credito.html)
    ]],
    ['Vendas', [
      { id: 'leads', ico: '☰', nome: 'Leads', href: 'leads.html', badge: 'vendas' },   // 0156: todos os leads, com ou sem venda (escada única) · 22/11: o selo das novas veio para cá
      { id: 'vendas', ico: '≡', nome: 'Vendas', href: 'vendas.html' },   // 22/11: só venda com OS gerada, em ordem cronológica
      { id: 'operacoes', ico: '⊞', nome: 'Instalações', href: 'operacoes.html', badge: 'agendar' },   // 22/11: as mesmas vendas de Vendas, com foco na instalação
      { id: 'filavero', ico: '☷', nome: 'Fila Vero', href: 'filavero.html', perfis: ['admin', 'backoffice'], esconder: true },   // 16/11 (0242): tela da Fila Vero
    ]],
    ['Acompanhamento', [
      { id: 'painel', ico: '◉', nome: 'Painel', href: 'painel.html' },
      { id: 'placar', ico: '▥', nome: 'Placar', href: 'placar.html', perfis: ['admin', 'backoffice'], esconder: true },   // 22/11 (novo layout, passo 6): como está o dia e como vai o mês
      { id: 'radar', ico: '◬', nome: 'Radar Nio', href: 'radar.html', perfis: ['admin', 'backoffice'], esconder: true },   // 26/11 (0413): os indicadores do Dashboard da Nio, qualidade no topo
      { id: 'pulso', ico: '∿', nome: 'Pulso', href: 'pulso.html', perfis: ['admin', 'backoffice'], esconder: true },   // 15/11: o Pulso como aba
      { id: 'mari', ico: '◎', nome: 'Mari · IA', href: 'mari.html', perfis: ['admin', 'backoffice'], esconder: true, badge: 'mari' },
      { id: 'meta', ico: '▲', nome: 'Canais', href: 'metaads.html' },   // 23/11 (0369): Meta Ads virou Canais, com uma aba por canal pago
    ]],
    ['Financeiro', [
      { id: 'adimplencia', ico: '◇', nome: 'Adimplência', href: 'adimplencia.html', perfis: ['admin', 'backoffice'], esconder: true },
      { id: 'conciliacao', ico: '◆', nome: 'Conciliação', href: 'conciliacao.html', perfis: ['admin', 'backoffice'], esconder: true },
      { id: 'pagamentos', ico: '◈', nome: 'Pagamentos a parceiros', href: 'pagamentos.html', perfis: ['admin', 'backoffice'], esconder: true },
      { id: 'ferramentas', ico: '⚒', nome: 'Ferramentas', href: 'ferramentas.html', perfis: ['admin'], esconder: true },   // 26/11 (0415): no ar, custo e vencimento de cada ferramenta paga
    ]],
    ['Cadastros', [
      { id: 'parceiros', ico: '⚑', nome: 'Parceiros PAP', href: 'parceiros.html', perfis: ['admin', 'backoffice'], esconder: true },
      { id: 'tabela', ico: '▦', nome: 'Tabela e política', href: 'tabela.html' },
      { id: 'config', ico: '⚙', nome: 'Configurações', href: 'configuracoes.html', perfis: ['admin', 'backoffice'], badge: 'campanhas' },   // 0406: campanha da Meta sem dono
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

  const MENU_AGENCIA = ['meta', 'tabela'];   // 0361 · 25/11: sem o Placar (Ricardo: "ela não precisa ter acesso ao Placar")
  const souAgencia = () => (NG.usuario || {}).perfil === 'agencia';
  function item(it, ativo) {
    if (souAgencia() && !MENU_AGENCIA.includes(it.id)) return '';
    // esconder: o item some (em vez de "em breve") para quem não tem o perfil — ex.: vendedor não vê a Mari.
    if (it.esconder && it.perfis && !it.perfis.includes((NG.usuario || {}).perfil)) return '';
    const conteudo = `<span class="ico" aria-hidden="true">${it.vivo ? '<span class="live-dot"></span>' : it.ico}</span>${NG.esc(it.nome)}` +
      (it.badge ? `<span class="badge" data-badge="${it.badge}" hidden></span>` : '') +
      (it.badge2 ? `<span class="badge fogo" data-badge="${it.badge2}" hidden></span>` : '') +
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
    // 25/11 (0392): conta a abertura das três telas da comparação dos 7 dias (Live · Live 2.0 · Conversas). Sem esperar a resposta.
    if (['minhavez', 'live2', 'conversas'].includes(pagina) && ['admin', 'backoffice'].includes(u.perfil)) {
      try { NG.sb.rpc('tela_abriu', { p_tela: pagina }).then(() => {}, () => {}); } catch (e) { /* medição não derruba o menu */ }
    }
    nav.setAttribute('aria-label', 'Menu principal');
    nav.innerHTML = `
      <div class="nav-brand">
        <span class="kicker">Dharma Telecom · Nio</span>
        <h2>NIO<span>GEN</span></h2>
        <p>Renascer. Reconstruir. Crescer.</p>
        <p class="clock" data-relogio>${relogio()}</p>
        ${souAgencia() ? '' : `<a class="nav-guia${pagina === 'guia' ? ' ativo' : ''}" href="guia.html" data-guia title="Como trabalhar com a Mari, o Chatwoot e o NIOGEN">Guia do Backoffice<span class="novo" data-guia-novo hidden>• atualizado</span></a>`}
      </div>
      <div class="nav-user">
        <div class="nav-avatar" aria-hidden="true">${NG.esc(iniciais(u.nome))}</div>
        <div class="nav-user-txt"><strong>${NG.esc(u.nome || '')}</strong><span>${NG.esc(NG.PERFIS[u.perfil] || '')}</span></div>
      </div>
      <div class="nav-items">
        ${MENU.map(([sec, itens]) => { const h = itens.map((it) => item(it, it.id === pagina)).join(''); return h ? `<div class="nav-sec">${sec}</div>${h}` : ''; }).join('')}
      </div>
      <div class="nav-foot">
        ${souAgencia() ? '' : `<div class="nav-consulta"><button type="button" class="nav-item" data-consulta title="Consulta central: viabilidade, crédito, OS e GED360 de um cliente, sem sair desta tela"><span class="ico" aria-hidden="true">⌕</span>Consulta</button></div>`}
        <button type="button" class="nav-item" data-sair><span class="ico" aria-hidden="true">⏏</span>Sair</button>
      </div>`;

    nav.querySelector('[data-sair]').addEventListener('click', NG.sair);
    setInterval(() => { const r = nav.querySelector('[data-relogio]'); if (r) r.textContent = relogio(); }, 30000);
    menuMovel(nav, pagina);
    appMovel(pagina);
    if (souAgencia()) return;   // 0361: Consulta, guia, balanço, selos e contadores são do time
    consultaBotao(nav, pagina);   // 21/11: Consulta central (depois do menuMovel: o ⌕ vai na barra do celular)
    guiaNovo(nav, pagina);
    balancoBotao();
    setInterval(() => { if (document.visibilityState === 'visible') balancoBotao(); }, 300000);   // 5 min: pega o das 7h45 com a tela aberta
    // 22/11 (Ricardo): os selos Mari/Meta saíram do pé do menu; ficam só as bolinhas da barra do celular ("Pode manter as
    // bolinhas no celular"). status_operacao só é chamada com a barra do celular na tela (≤ 760 px).
    const celular = window.matchMedia('(max-width: 760px)');
    statusOperacao(nav);
    setInterval(() => { if (document.visibilityState === 'visible' && celular.matches) statusOperacao(nav); }, 120000);   // 2 min
    celular.addEventListener('change', (m) => { if (m.matches) statusOperacao(nav); });

    // Prompt 27: avisos de Mari (aguardando humano) e Vendas (novas + precisam de ação). O Realtime não está ligado no
    // Supabase Nio (publicação vazia): consulta a cada 60 s. O total vai também para o título da aba: "(3) Vendas · NIOGEN".
    tituloBase = document.title.replace(/^\(\d+\)\s*/, '');
    if (pagina === 'leads') {
      // Abriu Leads = viu as novas (22/11: quem ainda não tem OS aparece em Leads; a chave do visto segue 'vendas'). "Visto em" fica no banco (por usuário), não no navegador.
      await NG.sb.from('usuario_vistos').upsert({ usuario_id: u.id, tela: 'vendas', visto_em: new Date().toISOString() }, { onConflict: 'usuario_id,tela' });
    }
    // 25/11 (regra 19): na Live 2.0 os selos do menu esperam a fila aparecer — as leituras deles (jornada_live, live_situacoes,
    // oportunidades) disputavam o banco com a live2_fila e a primeira tela levava 1,75 s em vez de ~0,8 s.
    if (pagina === 'live2') setTimeout(() => avisos(nav), 3000); else await avisos(nav);
    NG.mudou('avisos', 2 * 60000);
    // 11/11: aba oculta não consulta · 14/11 (0190): só refaz se o banco foi gravado (ou a cada 2 min) — os mesmos 2 min da
    // Live, para as duas cargas caírem juntas na resposta dividida entre abas (NG compartilhado, 45 s).
    setInterval(async () => { if (document.visibilityState === 'visible' && await NG.mudou('avisos', 2 * 60000)) avisos(nav); }, 60000);
  }

  // ---------- Selos de operação no rodapé do menu (0129, Ricardo 12/11 ~01h) ----------
  // "Mari ok" e "Meta N no ar", lado a lado, acima do Sair. Uma chamada (status_operacao) a cada 2 min com a aba visível.
  // Verde = ok · âmbar = alerta · vermelho = falha (API do Claude sem crédito ou falhando, cliente esperando a Mari, pagamento
  // do Meta, conta bloqueada, nada no ar). O motivo vai no title; no celular, as duas bolinhas aparecem também na barra do ☰.
  const ST_COR = { ok: 'var(--accent)', alerta: 'var(--warn-dot)', falha: 'var(--bad-dot)' };
  // 0144: status_operacao() agora sai do pulso_operacao() (uma regra só). Na Live (body[data-pulso]) o menu não chama nada:
  // a faixa de pulso já lê tudo a cada 60 s e entrega os selos por NGSidebar.pintarStatus(selos).
  async function statusOperacao(nav) {
    if (document.body && document.body.dataset.pulso) return;
    if (!window.matchMedia('(max-width: 760px)').matches) return;   // 22/11: só as bolinhas do celular
    try {
      const { data, error } = await NG.sb.rpc('status_operacao');
      pintarStatus(error ? null : data, nav);
    } catch (e) { /* os selos nunca derrubam o menu */ }
  }
  function pintarStatus(data, navEl) {
    const nav = navEl || document.getElementById('sidebar');
    const caixa = nav && nav.querySelector('[data-status]');   // 22/11: não existe mais no menu (só as bolinhas do celular)
    try {
      if (!data || (!data.mari && !data.meta && !data.google)) { if (caixa) caixa.hidden = true; return; }
      if (caixa) caixa.hidden = false;
      const ks = ['mari', 'meta', 'google'].filter((k) => data[k]);   // módulo desligado = selo some (0144) · 0369: google só depois da 1ª coleta
      const perfil = (NG.usuario || {}).perfil;
      const selo = (k, s) => {
        const motivo = (s.motivos || []).join(' · ');
        const titulo = `${s.texto}${motivo ? ` — ${motivo}` : ''}`;
        // A tela Mari é só de admin/backoffice: para o vendedor o selo da Mari não é link.
        const link = s.href && !(k === 'mari' && !['admin', 'backoffice'].includes(perfil));
        const tag = link ? 'a' : 'span';
        return `<${tag} class="st-selo st-${s.nivel}"${link ? ` href="${s.href}"` : ''} title="${NG.esc(titulo)}" aria-label="${NG.esc(titulo)}">`
          + `<i class="mv-dot" style="--c:${ST_COR[s.nivel] || 'var(--muted)'}"></i><span>${NG.esc(s.texto)}</span></${tag}>`;
      };
      if (caixa) caixa.innerHTML = ks.map((k) => selo(k, data[k])).join('');
      const topo = document.querySelector('.topo-movel');
      if (topo) {
        let p = topo.querySelector('.st-pontos');
        if (!p) { p = document.createElement('span'); p.className = 'st-pontos'; topo.appendChild(p); }
        p.innerHTML = ks.map((k) => `<i class="mv-dot" style="--c:${ST_COR[data[k].nivel] || 'var(--muted)'}" title="${NG.esc(data[k].texto)}"></i>`).join('');
        p.setAttribute('aria-label', ks.map((k) => data[k].texto).join(' · '));
      }
    } catch (e) { /* os selos nunca derrubam o menu */ }
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

  // ---------- Balanço das conversas paradas (0127/0128, Ricardo 11/11 ~22h45) ----------
  // Botão flutuante em todas as telas, para todos os usuários, quando há balanço das últimas 24 h (n8n balanco_diario, Claude,
  // 7h45 seg–sáb). Balanço ainda não lido = botão grande "Balanço novo" pulsando; já lido = só o ícone. Abre num modal.
  // "Lido" fica no navegador (localStorage niogen.balanco.visto = id, em try/catch): sem storage, o botão fica sempre no modo novo.
  const BAL_KEY = 'niogen.balanco.visto';
  let balUltimo = null;
  function balVisto() { try { return localStorage.getItem(BAL_KEY); } catch (e) { return null; } }
  async function balancoBotao() {
    try {
      const desde = new Date(Date.now() - 24 * 3600e3).toISOString();
      const { data, error } = await NG.sb.from('balanco_diario').select('id, criado_em, itens, erro')
        .gte('criado_em', desde).order('criado_em', { ascending: false }).limit(1).maybeSingle();
      let bt = document.getElementById('bal-fab');
      if (error || !data || data.erro) { if (bt) bt.remove(); return; }
      balUltimo = data;
      const novo = balVisto() !== String(data.id);
      const n = (data.itens || []).length;
      if (!bt) {
        bt = document.createElement('button');
        bt.type = 'button';
        bt.id = 'bal-fab';
        bt.addEventListener('click', balancoAbrir);
        document.body.appendChild(bt);
      }
      bt.className = `bal-fab${novo ? ' novo' : ''}`;
      bt.innerHTML = `<span aria-hidden="true">📋</span>${novo ? `<b>Balanço novo</b>${n ? `<i>${n}</i>` : ''}` : ''}`;
      bt.title = `Balanço das conversas paradas (${NG.fmtHora(new Date(data.criado_em))}) · ${n ? `${n} com resposta sugerida` : 'nenhuma conversa parada'}`;
      bt.setAttribute('aria-label', bt.title);
    } catch (e) { /* o botão nunca derruba a tela */ }
  }
  async function balancoAbrir() {
    if (!balUltimo) return;
    const { data, error } = await NG.sb.from('balanco_diario').select('id, criado_em, resumo, itens').eq('id', balUltimo.id).maybeSingle();
    if (error || !data) { NG.toast(error ? NG.msgErro(error) : 'Balanço não encontrado', 'bad'); return; }
    const esc = NG.esc;
    const bo = ['admin', 'backoffice'].includes((NG.usuario || {}).perfil);
    const COR = { alta: 'var(--bad-dot)', media: 'var(--warn-dot)', baixa: 'var(--muted)' };
    const itens = data.itens || [];
    const quando = `${NG.diaSP(new Date(data.criado_em)) === NG.diaSP() ? 'hoje' : NG.fmtData(data.criado_em).slice(0, 5)} às ${NG.fmtHora(new Date(data.criado_em))}`;
    const d = document.createElement('dialog');
    d.className = 'modal bal-modal';
    d.innerHTML = `<div class="bal-cab"><h3>Balanço das conversas paradas</h3><span class="muted">${esc(quando)}</span>
        <button type="button" class="btn btn-ghost btn-sm" data-fechar aria-label="Fechar">✕</button></div>
      <div class="bal-corpo">
        ${data.resumo ? `<p class="resumo-txt">${esc(data.resumo)}</p>` : ''}
        ${itens.map((i, k) => `<div class="bal-item">
          <div class="bal-l1"><i class="mv-dot" style="--c:${COR[i.urgencia] || 'var(--muted)'}" title="urgência ${esc(i.urgencia)}"></i><b>${esc(i.nome)}</b>
            ${bo ? `<a class="btn btn-sm" href="conversas.html#c=${esc(i.conversa_id)}">Abrir</a>` : ''}</div>
          <p>${esc(i.situacao)}</p>
          <p class="bal-fazer"><b>Fazer:</b> ${esc(i.acao)}</p>
          <div class="bal-resp"><pre class="resumo-txt">${esc(i.resposta_sugerida)}</pre><button type="button" class="btn btn-sm" data-copiar="${k}">Copiar</button></div>
        </div>`).join('')}
        <p class="nota-campo">Escrito pelo Claude às 7h45 (seg–sáb) com as conversas em que o cliente espera o time há mais de 2 h. É sugestão: ouça o áudio e confira valor e data antes de mandar.</p>
      </div>`;
    document.body.appendChild(d);
    const fechar = () => { d.close(); d.remove(); };
    d.querySelector('[data-fechar]').addEventListener('click', fechar);
    d.addEventListener('cancel', (ev) => { ev.preventDefault(); fechar(); });
    d.addEventListener('click', (ev) => { if (ev.target === d) fechar(); });
    d.querySelectorAll('[data-copiar]').forEach((b) => b.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(itens[Number(b.dataset.copiar)].resposta_sugerida); NG.toast('Resposta copiada ✓', 'ok'); }
      catch (e) { NG.toast('Não deu para copiar — selecione o texto e copie à mão', 'bad'); }
    }));
    d.showModal();
    try { localStorage.setItem(BAL_KEY, String(data.id)); } catch (e) { /* sem storage: segue "novo" */ }
    balancoBotao();
  }

  // ---------- Auditoria da Mari (0130, Ricardo 12/11 ~01h20) ----------
  // Claude (Sonnet 5.5) lê as conversas e aponta falhas de prompt, contrato, venda perdida, cadência, handoff, erro e tom, com a
  // correção sugerida. Diária às 7h30 (seg–sáb) ou pedida aqui (admin/backoffice): o pedido vira linha 'pedido' e o n8n pega em
  // até 2 min, das 8h às 22h. NG.auditoria.abrir(id?) abre o modal; NG.auditoria.pedir(conversaId?) pede e abre; .nova() diz se a
  // diária mais recente ainda não foi vista neste navegador (localStorage niogen.auditoria.vista).
  const AUD_KEY = 'niogen.auditoria.vista';
  const AUD_TIPO = { venda_perdida: 'venda perdida', contrato: 'contrato', prompt: 'prompt', cadencia_template: 'cadência/template',
    handoff: 'handoff', erro_tecnico: 'erro técnico', tom: 'tom' };
  const AUD_COLS = 'id, modo, conversa_id, status, pedido_em, inicio, fim, janela_de, janela_ate, modelo, tokens_in, tokens_out, resumo, achados, numeros, erro';
  async function audNova() {
    try {
      const { data } = await NG.sb.from('auditoria_mari').select('id').eq('modo', 'diaria').eq('status', 'pronta')
        .order('fim', { ascending: false }).limit(1).maybeSingle();
      if (!data) return null;
      let visto = null;
      try { visto = localStorage.getItem(AUD_KEY); } catch (e) { return null; }
      return visto === String(data.id) ? null : data.id;
    } catch (e) { return null; }
  }
  function audTexto(a) {
    const n = a.numeros || {};
    const linhas = [`Auditoria da Mari #${a.id} · nota ${n.nota ?? '?'}/10 · ${NG.fmtDataHora(a.janela_de)} a ${NG.fmtDataHora(a.janela_ate)}`, '', a.resumo || '', ''];
    (a.achados || []).forEach((x, k) => {
      linhas.push(`${k + 1}. [${x.gravidade}] ${AUD_TIPO[x.tipo] || x.tipo} — ${x.titulo}`, `   O que aconteceu: ${x.o_que_aconteceu}`,
        `   Evidência: ${x.evidencia}`, `   Corrigir: ${x.correcao}`);
      if (x.trecho_prompt) linhas.push(`   Trecho do prompt: ${x.trecho_prompt}`);
      if ((x.conversa_ids || []).length) linhas.push(`   Conversas: ${x.conversa_ids.join(', ')}`);
      linhas.push('');
    });
    return linhas.join('\n');
  }
  function audCorpo(a) {
    const esc = NG.esc;
    if (!a) return '<p class="muted">Nenhuma auditoria ainda. Clique em <b>Auditar 24 h</b>.</p>';
    if (a.status === 'pedido' || a.status === 'rodando') {
      const h = Number(new Intl.DateTimeFormat('pt-BR', { timeZone: NG.TZ, hour: 'numeric', hour12: false }).format(new Date()));
      return `<div class="faixa amarelo">${a.status === 'rodando' ? '⏳ O Claude está lendo as conversas (cerca de 1 minuto)…'
        : `⏳ Na fila. ${h >= 8 && h < 22 ? 'O n8n pega em até 2 minutos.' : 'O n8n busca pedidos das 8h às 22h — sai às 8h.'}`}
        Esta janela atualiza sozinha.</div>`;
    }
    if (a.status === 'erro') return `<div class="faixa vermelho"><b>A auditoria falhou.</b> ${esc(a.erro || '')}</div>`;
    const n = a.numeros || {};
    const COR = { alta: 'var(--bad-dot)', media: 'var(--warn-dot)', baixa: 'var(--muted)' };
    const conv = (ids) => (ids || []).map((id, k) => `<a href="mari.html?conversa=${esc(id)}">conversa ${k + 1}</a>`).join(' · ');
    const custo = a.tokens_in ? ` · ${Math.round(a.tokens_in / 1000)} mil + ${Math.round((a.tokens_out || 0) / 1000)} mil tokens (~US$ ${((a.tokens_in * 2 + (a.tokens_out || 0) * 10) / 1e6).toFixed(2)})` : '';
    return `<p class="aud-meta"><b class="aud-nota">${n.nota ?? '–'}<small>/10</small></b>
        <span>${a.conversa_id ? '1 conversa' : `${n.conversas ?? '?'} conversas`} · ${esc(NG.fmtDataHora(a.janela_de))} a ${esc(NG.fmtDataHora(a.janela_ate))}<br>
        <span class="muted">${a.modo === 'diaria' ? 'diária' : 'pedida'} · ${esc(a.modelo || '')}${custo}</span></span></p>
      ${a.resumo ? `<p class="resumo-txt">${esc(a.resumo)}</p>` : ''}
      ${(n.bons || []).length ? `<div class="aud-bons"><b>Funcionou bem</b><ul>${n.bons.map((b) => `<li>${esc(b)}</li>`).join('')}</ul></div>` : ''}
      ${(a.achados || []).map((x) => `<div class="bal-item">
        <div class="bal-l1"><i class="mv-dot" style="--c:${COR[x.gravidade] || 'var(--muted)'}" title="gravidade ${esc(x.gravidade)}"></i>
          <span class="aud-tipo">${esc(AUD_TIPO[x.tipo] || x.tipo)}</span><b>${esc(x.titulo)}</b></div>
        <p>${esc(x.o_que_aconteceu)}</p>
        <p class="muted"><b>Evidência:</b> ${esc(x.evidencia)}</p>
        <p class="bal-fazer"><b>Corrigir:</b> ${esc(x.correcao)}</p>
        ${x.trecho_prompt ? `<pre class="resumo-txt aud-trecho">${esc(x.trecho_prompt)}</pre>` : ''}
        ${(x.conversa_ids || []).length ? `<p class="aud-conv">${conv(x.conversa_ids)}</p>` : ''}
      </div>`).join('') || '<p class="muted">Nenhum achado no período.</p>'}
      <p class="nota-campo">Escrito pelo Claude com as falas do período (CPF, telefone e e-mail mascarados). É diagnóstico: confira na conversa antes de mexer no prompt.</p>`;
  }
  async function audAbrir(idAlvo) {
    const { data: lista, error } = await NG.sb.from('auditoria_mari').select(AUD_COLS).order('pedido_em', { ascending: false }).limit(15);
    if (error) { NG.toast(NG.msgErro(error), 'bad'); return; }
    let atual = (lista || []).find((a) => String(a.id) === String(idAlvo)) || (lista || [])[0] || null;
    const esc = NG.esc;
    const opcao = (a) => `<option value="${a.id}"${atual && a.id === atual.id ? ' selected' : ''}>#${a.id} · ${a.modo === 'diaria' ? 'diária' : a.conversa_id ? 'conversa' : '24 h'} · ${esc(NG.fmtDataHora(a.pedido_em))}${a.status === 'pronta' ? ` · ${(a.achados || []).length} achado(s)` : ` · ${a.status}`}</option>`;
    const d = document.createElement('dialog');
    d.className = 'modal bal-modal aud-modal';
    d.innerHTML = `<div class="bal-cab"><h3>Auditoria da Mari</h3>
        <select class="sel" data-hist aria-label="Auditorias anteriores">${(lista || []).map(opcao).join('')}</select>
        <button type="button" class="btn btn-sm" data-copiar title="Copia o texto dos achados (para colar numa conversa com o Claude e corrigir o prompt)">Copiar</button>
        <button type="button" class="btn btn-sm btn-acc" data-pedir title="Pede ao Claude a auditoria das últimas 24 h">Auditar 24 h</button>
        <button type="button" class="btn btn-ghost btn-sm" data-fechar aria-label="Fechar">✕</button></div>
      <div class="bal-corpo" data-corpo>${audCorpo(atual)}</div>`;
    document.body.appendChild(d);
    let timer = null;
    const pintar = () => {
      d.querySelector('[data-corpo]').innerHTML = audCorpo(atual);
      d.querySelector('[data-copiar]').disabled = !atual || atual.status !== 'pronta';
      if (atual && atual.modo === 'diaria' && atual.status === 'pronta') { try { localStorage.setItem(AUD_KEY, String(atual.id)); } catch (e) { /* ok */ } }
      clearInterval(timer);
      if (atual && ['pedido', 'rodando'].includes(atual.status)) {
        timer = setInterval(async () => {
          const { data } = await NG.sb.from('auditoria_mari').select(AUD_COLS).eq('id', atual.id).maybeSingle();
          if (data && data.status !== atual.status) { atual = data; pintar(); }
        }, 10000);
      }
    };
    const fechar = () => { clearInterval(timer); d.close(); d.remove(); };
    d.querySelector('[data-fechar]').addEventListener('click', fechar);
    d.addEventListener('cancel', (ev) => { ev.preventDefault(); fechar(); });
    d.addEventListener('click', (ev) => { if (ev.target === d) fechar(); });
    d.querySelector('[data-hist]').addEventListener('change', (ev) => { atual = lista.find((a) => String(a.id) === ev.target.value) || atual; pintar(); });
    d.querySelector('[data-copiar]').addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(audTexto(atual)); NG.toast('Achados copiados ✓', 'ok'); }
      catch (e) { NG.toast('Não deu para copiar', 'bad'); }
    });
    d.querySelector('[data-pedir]').addEventListener('click', async (ev) => { ev.target.disabled = true; fechar(); await audPedir(null); });
    d.showModal();
    pintar();
  }
  async function audPedir(conversaId) {
    const { data, error } = await NG.sb.rpc('auditoria_mari_pedir', { p_conversa: conversaId || null });
    if (error) { NG.toast(NG.msgErro(error), 'bad'); return; }
    if (!data || !data.ok) { NG.toast((data && data.motivo) || 'Não deu para pedir a auditoria', 'bad'); return; }
    NG.toast(data.ja_havia ? 'Já havia uma auditoria na fila — abrindo' : 'Auditoria pedida ✓', 'ok');
    await audAbrir(data.id);
  }
  NG.auditoria = { abrir: audAbrir, pedir: audPedir, nova: audNova };

  // ---------- contadores do menu (prompt 27) ----------
  let tituloBase = '';
  function pinta(nav, chave, n, cls, titulo) {
    const el = nav.querySelector(`[data-badge="${chave}"]`);
    if (!el) return;
    el.textContent = n ? (chave === 'oport' ? `🔥 ${n}` : n) : '';
    el.hidden = !n;
    el.className = `badge${chave === 'oport' ? ' fogo' : ''}${cls ? ` ${cls}` : ''}`;
    el.title = titulo;
    const item = el.closest('.nav-item');
    if (item) item.title = n ? titulo : '';
  }
  // 0090: os três números saem da MESMA regra (v_jornada.precisa_acao): Live = todos · Funil = os que têm venda ·
  // Mari = os que têm conversa. Funil soma as vendas novas em Lead qualificado desde a última visita.
  async function avisos(nav) {
    const u = NG.usuario || {};
    let total = 0;
    try {
      const j = await NG.jornada();
      if (j.erro) return;
      const acao = j.lista.filter((x) => x.precisa_acao);
      // Instalações: biometria validada esperando abrir a OS, ou OS aberta esperando agendar (contrato: 4 h da biometria).
      const osAg = j.lista.filter((x) => x.botao === 'os' || x.botao === 'os_agendar' || (x.botao === 'agendar' && x.nivel === 'agora'));
      pinta(nav, 'agendar', osAg.length, osAg.length ? 'alerta' : 'info', `${osAg.length} esperando abrir a OS ou agendar a instalação (contrato: até 4 h da biometria).`);
      if (['admin', 'backoffice'].includes(u.perfil)) {
        // 10/11 (Ricardo: "não pode o mesmo cliente trazer 2 notificações no menu lateral"): cada cliente conta UMA vez.
        // Live conta tudo o que precisa de ação; Mari não repete esse número; Conversas conta só quem espera e NÃO está no Live.
        pinta(nav, 'mari', 0, 'info', '');
        // 26/11: o número do menu é o da Live 2.0 — as tarefas da fila dela (live2_fila), vermelho se há venda em risco ou
        // cliente esperando (urgência 4+). A Live 1.0 não conta mais nada no menu.
        const r2 = await Promise.resolve(NG.sb.rpc('live2_fila')).catch(() => null);
        const f2 = (r2 && !r2.error && r2.data && r2.data.fila) || null;
        if (f2) {
          const quentes = f2.filter((x) => x.risco || Number(x.urg) >= 4).length;
          pinta(nav, 'fila2', f2.length, quentes ? 'alerta' : 'info',
            `${f2.length} ${f2.length === 1 ? 'tarefa' : 'tarefas'} na Live 2.0 · ${quentes} ${quentes === 1 ? 'urgente' : 'urgentes'} (venda em risco ou cliente esperando).`);
          total = f2.length;
        }
        // 0107: 🔥 oportunidades — selo à parte; não entra no número verde nem no título da aba.
        // 0094/0102: Conversas = clientes esperando 3 min+ fora do Live (deveria ser 0; furo fica gravado). 11/11: as duas em paralelo.
        // 26/11 (Ricardo: "Põe o 🔥 de oportunidades na Live 2.0"): o selo à parte, ao lado do número da Live 2.0
        const [op, fu] = await Promise.all([NG.oportunidades(j), NG.furosJornada(j)]);
        if (!op.erro) pinta(nav, 'oport', op.lista.length, '', `${op.lista.length} ${op.lista.length === 1 ? 'oportunidade' : 'oportunidades'}: a Mari acha que uma mensagem sua esquenta a conversa. Não é obrigação.`);
        // 0406: campanha nova na conta da Meta sem dono — o admin diz se é da agência (Configurações › Agência)
        if (u.perfil === 'admin') {
          const rc = await Promise.resolve(NG.sb.rpc('meta_ads_campanhas_sem_dono')).catch(() => null);
          const nc = rc && !rc.error ? Number(rc.data) || 0 : 0;
          pinta(nav, 'campanhas', nc, 'alerta', nc ? `${nc} ${nc === 1 ? 'campanha nova' : 'campanhas novas'} na Meta esperando você dizer se é da agência ou nossa (Configurações › Agência).` : '');
          const it = nav.querySelector('[data-badge="campanhas"]');
          const a = it && it.closest('a');
          if (a) a.setAttribute('href', nc ? 'configuracoes.html#agencia' : 'configuracoes.html');
        }
        if (!fu.erro) {
          const n = fu.ids.size;
          pinta(nav, 'conversas', n, n ? 'alerta' : 'info', n ? `${n} ${n === 1 ? 'cliente esperando' : 'clientes esperando'} resposta há 3 min ou mais FORA do Live — deveria ser 0 (defeito registrado para corrigir).` : '');
        }
      }
      if (nav.querySelector('[data-badge="vendas"]')) {
        const rs = await NG.sb.from('usuario_vistos').select('visto_em').eq('tela', 'vendas').maybeSingle();
        let q = NG.sb.from('vendas').select('id').eq('status', '0_qualificado');
        if (rs.data && rs.data.visto_em) q = q.gt('criado_em', rs.data.visto_em);
        const rn = await q.limit(500);
        const novas = (rn.data || []).map((x) => x.id);
        const vend = acao.filter((x) => x.venda_id);
        const ids = new Set([...novas, ...vend.map((x) => x.venda_id)]);
        pinta(nav, 'vendas', ids.size, novas.length ? 'alerta' : 'info',
          `${novas.length} ${novas.length === 1 ? 'venda nova' : 'vendas novas'} em Lead qualificado desde a sua última visita · ${vend.length} ${vend.length === 1 ? 'precisa' : 'precisam'} de ação. ${NG.ajuda.menu_vendas}`);
        if (!['admin', 'backoffice'].includes(u.perfil)) total = ids.size;
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

  // ---------- Consulta central (21/11/2026, Ricardo): viabilidade · crédito · OS · GED360 num painel sobre qualquer tela ----------
  // Botão "Consulta | Guia" no pé do menu e ⌕ na barra do celular. assets/consulta.js só é baixado no 1º clique (regra 19) —
  // ou na abertura da tela se esta aba já tinha a consulta aberta/minimizada (sessionStorage niogen.consulta: volta como estava).
  // 22/11 (Ricardo: "Pôr na Live"): aparece também na Live (fila.html).
  let consultaP = null;
  function consultaCarregar() {
    if (window.NGConsulta) return Promise.resolve(window.NGConsulta);
    if (!consultaP) {
      consultaP = new Promise((ok, falhou) => {
        const s = document.createElement('script');
        s.src = 'assets/consulta.js?v=251126-cob3';
        s.onload = () => ok(window.NGConsulta);
        s.onerror = () => { consultaP = null; falhou(new Error('não carregou')); };
        document.head.appendChild(s);
      });
    }
    return consultaP;
  }
  // 22/11: a lupa da ficha (assets/ficha.js) abre a Consulta central já no cliente da ficha — mesmo carregamento sob demanda.
  // 25/11 (Ricardo: "Resolve a lentidão da primeira abertura do painel"): passar o mouse no ⌕ Consulta ou na lupa da ficha já
  // baixa o painel e monta a Cobertura escondida — no clique ela está pronta. Só com a intenção do usuário (nada na abertura da tela).
  window.NGConsultaPreparar = () => consultaCarregar().then((c) => c && c.preparar && c.preparar()).catch(() => {});
  window.NGConsultaAbrir = (cli) => consultaCarregar().then((c) => c && (c.abrirCliente ? c.abrirCliente(cli) : c.abrir()))
    .catch(() => NG.toast('A Consulta central não carregou — confira a internet e tente de novo.', 'bad'));
  function consultaBotao(nav, pagina) {
    try {
      if (!document.getElementById('nav-consulta-estilo')) {
        const st = document.createElement('style');
        st.id = 'nav-consulta-estilo';
        st.textContent = '.nav-consulta{display:flex;align-items:center;margin:0 0 6px}.nav-consulta .nav-item{flex:1;width:auto;color:var(--text)}.nav-consulta .nav-item .ico{color:var(--accent);font-size:15px}'
          + ''
          + '.topo-movel .cc-topo{margin-left:auto;width:34px;height:34px;border-radius:9px;border:1px solid var(--border);background:var(--surface-2);color:var(--accent);font-size:17px;line-height:1;cursor:pointer}';
        document.head.appendChild(st);
      }
      const ir = () => consultaCarregar().then((c) => c && c.alternar()).catch(() => NG.toast('A Consulta central não carregou — confira a internet e tente de novo.', 'bad'));
      const b = nav.querySelector('[data-consulta]');
      if (b) ['pointerenter', 'focus'].forEach((ev) => b.addEventListener(ev, window.NGConsultaPreparar, { once: true }));
      if (b) b.addEventListener('click', () => { if (nav.classList.contains('aberto')) { const m = document.querySelector('.topo-movel .menu-btn'); if (m) m.click(); } ir(); });
      const topo = document.querySelector('.topo-movel');
      if (topo && !topo.querySelector('.cc-topo')) {
        const t = document.createElement('button');
        t.type = 'button'; t.className = 'cc-topo'; t.textContent = '⌕';
        t.title = 'Consulta central'; t.setAttribute('aria-label', 'Abrir a Consulta central');
        t.addEventListener('click', ir);
        const pontos = topo.querySelector('.st-pontos');
        topo.insertBefore(t, pontos || null);
      }
      let salvo = null;
      try { salvo = JSON.parse(sessionStorage.getItem('niogen.consulta') || 'null'); } catch (e) { salvo = null; }
      if (salvo && ['aberto', 'minimizado'].includes(salvo.modo)) consultaCarregar().catch(() => {});
    } catch (e) { /* o botão nunca derruba o menu */ }
  }

  // 15/11: assets/movel.js (barra inferior do celular, instalar, avisos, sessão do app). Carrega uma vez, com o ?v= do CACHE.
  function appMovel(pagina) {
    const ir = () => { if (window.NGMovel) window.NGMovel.montar(pagina); };
    if (window.NGMovel) { ir(); return; }
    const s = document.createElement('script');
    s.src = 'assets/movel.js?v=261126-4';
    s.onload = ir;
    document.head.appendChild(s);
  }

  // 09/11: o botão "Atualizar" das telas (NG.botaoAtualizar) refaz os contadores do menu junto com os dados.
  window.NGSidebar = { montar, pintarStatus, avisos: () => { const nav = document.getElementById('sidebar'); return nav ? avisos(nav) : null; } };
})();
