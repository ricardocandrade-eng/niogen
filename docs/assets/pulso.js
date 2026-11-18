/* NIOGEN | docs/assets/pulso.js | 12/11/2026 — Claude Code (docs/Prompt_pulso_live_121126_1035.md · layout docs/LAYOUT_pulso_live_121126_1035.html)
 * Faixa de pulso no topo da Live: Meta Ads → Entrada → Mari → Fluxos n8n + funil de hoje. Uma chamada (RPC pulso_operacao, 0144) a
 * cada 60 s com a aba visível; os "há X min" são refeitos no navegador a cada 30 s. Se a leitura falhar ou envelhecer, a faixa fica
 * cinza com "sem leitura há X" — nunca mostra verde velho. Nível nunca só por cor: bolinha (ok), triângulo (atenção), quadrado
 * (parado), anel (sem leitura) + o rótulo em texto. Clique num elo abre o detalhe; o alerta leva a Conversas › Esperando resposta.
 * 14/11: recolhida numa linha (batimento + rótulo de cada elo); o clique abre os dados por cima da lista, sem empurrar a tela.
 * Também entrega os selos do menu (NGSidebar.pintarStatus) — na Live o menu não faz chamada própria. Só leitura; sem dado de cliente.
 * 15/11 (NIOGEN no celular · docs/LAYOUT_conversas_mobile_151126_1304.html): o Pulso virou ABA (pulso.html, NGPulso.montarAba) —
 * os 4 elos em cartões (sinal, número, linha de detalhe; toque abre o detalhe), o funil de hoje e o alerta com a ação, nos estados
 * do LAYOUT_pulso_live (ok · atenção · parado · sem leitura). Na Live do celular (≤ 640 px) sobra só a faixa resumida: o toque
 * leva à aba em vez de abrir por cima. Mesma RPC (pulso_operacao), mesma cadência de 60 s.
 * 18/11 (Ricardo: "inclua a qualidade da Waba (green) e, com o disparo da Fila Vero em andamento, a bolinha pulsando"): duas partes
 * novas — WABA (quality_rating da última leitura) e Fila Vero (enviados hoje / ritmo; bolinha pulsa só enquanto envia). Vêm da
 * pulso_extra() (0294), chamada em paralelo com a pulso_operacao(); se ela falhar, as duas somem e o resto segue. Aberto, os cartões
 * ficam na mesma grade da barra (cada um embaixo do seu) e o resto da tela escurece; clique no escuro fecha. */
(function () {
  const ORDEM = ['meta', 'entrada', 'mari', 'fluxos'];
  const NOME = { meta: 'Meta Ads', entrada: 'Entrada', mari: 'Mari', fluxos: 'Fluxos n8n' };
  const NIVEL_TXT = { ok: 'ok', atencao: 'atenção', parado: 'parado', sem_leitura: 'sem leitura' };
  const VELHO_MS = 3 * 60 * 1000;   // retorno com mais de 3 min = sem leitura
  const ECG = 'M0 20 H42 L50 20 L56 6 L64 30 L70 14 L76 20 H104 L110 12 L116 24 L121 20 H150';
  const ECG_PARADO = 'M0 20 H42 L50 20 L56 6 L64 30 L70 14 L76 20 H150';

  let modoAba = false;   // 15/11: pulso.html (aba do celular / tela inteira)
  const CEL = window.matchMedia('(max-width: 640px)');
  let extra = null;   // 0294: pulso_extra() — WABA e Fila Vero
  let el = null; let dados = null; let recebido = 0; let desvio = 0; let aberto = null; let expandido = false; let falhou = false; let timer = null;
  const esc = (s) => NG.esc(s == null ? '' : String(s));

  // "agora" / "há 4 min" / "há 2 h" a partir de um ISO do servidor (corrigido pelo relógio do servidor).
  function ha(iso) {
    if (!iso) return null;
    const min = Math.max(0, (Date.now() - desvio - new Date(iso)) / 60000);
    if (min < 1) return 'agora';
    if (min < 60) return `há ${Math.floor(min)} min`;
    if (min < 48 * 60) return `há ${Math.floor(min / 60)} h`;
    return `há ${Math.floor(min / 1440)} d`;
  }
  const hm = (iso) => (iso ? new Date(iso).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit', timeZone: 'America/Sao_Paulo' }) : '—');
  const marca = (n) => `<i class="pl-marca pl-${n}" aria-hidden="true"></i>`;

  function semLeitura() {
    if (falhou && !dados) return true;
    return !dados || Date.now() - recebido > VELHO_MS;
  }

  // Textos que dependem do relógio, refeitos a cada 30 s.
  function vivo(k, e) {
    if (k === 'mari') return { principal: ha(e.ultima_resposta_em) || 'sem resposta' };
    if (k === 'meta') return { linha2: `lido ${ha(e.lido_em) || '—'}` };
    if (k === 'fluxos' && e.nivel === 'ok' && e.lido_em) return { principal: ha(e.lido_em) };
    return {};
  }

  // 0294: WABA e Fila Vero. Nível só da bolinha da própria parte — não mexe no "Saúde do ecossistema" (alarme, não trava).
  const NIVEL_WABA = { GREEN: 'ok', YELLOW: 'atencao', RED: 'parado' };
  const nfmt = (n) => Number(n || 0).toLocaleString('pt-BR');
  function extras(cinza) {
    if (!extra) return [];
    const out = [];
    const w = extra.waba;
    const num = extra.fila_vero && extra.fila_vero.numero;
    if (w || num) {
      // Mari e disparo da Fila Vero saem do MESMO número (1342993658907403). Duas leituras dele: waba_qualidade (8h e 14h) e a
      // guarda da Fila Vero (de hora em hora) — vale a mais nova.
      const lw = w && w.quality_rating ? { r: w.quality_rating, em: w.lida_em, tier: w.messaging_limit_tier } : null;
      const ln = num && num.rating ? { r: num.rating, em: num.em, tier: num.tier } : null;
      const l = !lw ? ln : !ln ? lw : (new Date(ln.em || 0) > new Date(lw.em || 0) ? { ...ln, tier: ln.tier || lw.tier } : lw);
      const r = l && l.r;
      const n = cinza || !r ? 'sem_leitura' : (NIVEL_WABA[r] || 'atencao');
      const linhas = ['número da Nio (Mari e Fila Vero)'];
      if (l && l.em) linhas.push(`lido ${ha(l.em) || '—'}`);
      const tier = l && l.tier ? `${String(l.tier).replace('TIER_', '').toLowerCase()}/dia` : '—';
      out.push({ k: 'waba', nome: 'WABA', n, rotulo: r || 'sem leitura', principal: tier, linhas, href: 'metaads.html' });
    }
    const f = extra.fila_vero;
    if (f) {
      let n; let rotulo;
      if (cinza) { n = 'sem_leitura'; rotulo = 'sem leitura'; }
      else if (f.enviando) { n = 'envio'; rotulo = 'enviando'; }
      else if (!f.ativo) { n = 'quieto'; rotulo = 'pausada'; }
      else if (!f.dentro_horario) { n = 'quieto'; rotulo = 'fora do horário'; }
      else if (f.hoje >= f.ritmo) { n = 'quieto'; rotulo = 'cota do dia'; }
      else { n = 'quieto'; rotulo = 'ligada · sem envio'; }
      const linhas = [`${nfmt(f.hoje)} de ${nfmt(f.ritmo)} enviados hoje`, f.ultimo_envio_em ? `último envio ${ha(f.ultimo_envio_em)}` : 'nenhum envio ainda'];
      out.push({ k: 'filavero', nome: 'Fila Vero', n, rotulo, principal: `${nfmt(f.hoje)}/${nfmt(f.ritmo)}`, linhas, href: 'filavero.html' });
    }
    return out;
  }
  function celulaExtra(x) {
    return `<a class="pl-elo pl-n-${x.n}" href="${x.href}" aria-label="${esc(x.nome)}: ${esc(x.rotulo)}. Abrir ${esc(x.nome)}">
      <span class="pl-cab">${marca(x.n)}<span class="pl-nome">${esc(x.nome)}</span><span class="pl-rot">${esc(x.rotulo)}</span></span>
      <span class="pl-princ">${esc(x.principal)}</span>
      <span class="pl-linhas">${x.linhas.slice(0, 3).map(esc).join('<br>')}</span></a>`;
  }

  function celula(k, e, cinza) {
    const n = cinza ? 'sem_leitura' : e.nivel;
    const v = vivo(k, e);
    const linhas = (e.linhas || []).slice(0, 2).map((l, i) => (i === 1 && v.linha2 ? v.linha2 : l));
    const sel = aberto === k ? ' pl-sel' : '';
    return `<button type="button" class="pl-elo pl-n-${n}${sel}" data-elo="${k}" aria-expanded="${aberto === k}" aria-controls="pl-detalhe"
        aria-label="${esc(NOME[k])}: ${esc(e.rotulo)}${cinza ? ' (leitura velha)' : ''}. Ver o detalhe">
      <span class="pl-cab">${marca(n)}<span class="pl-nome">${esc(NOME[k])}</span><span class="pl-rot">${esc(cinza ? 'sem leitura' : e.rotulo)}</span></span>
      <span class="pl-princ">${esc(v.principal || e.principal)}</span>
      <span class="pl-linhas">${linhas.map(esc).join('<br>')}</span>
    </button>`;
  }

  function geral(cinza) {
    const g = dados ? dados.geral : { nivel: 'sem_leitura', titulo: 'Sem leitura' };
    const n = cinza ? 'sem_leitura' : g.nivel;
    const titulo = cinza ? 'Sem leitura' : g.titulo;
    let sub;
    if (cinza) sub = recebido ? `última leitura ${ha(new Date(recebido - desvio).toISOString())}` : 'lendo…';
    else if (g.nivel !== 'ok' && g.desde) sub = `desde ${hm(g.desde)} · ${ha(g.desde).replace('há ', '')}`;
    else sub = new Date().toLocaleString('pt-BR', { weekday: 'short', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'America/Sao_Paulo' }).replace(',', ' ·').replace('.', '');
    return `<div class="pl-geral pl-n-${n}" role="status">
      <svg class="pl-ecg" aria-hidden="true" viewBox="0 0 150 34"><path class="${n === 'ok' ? 'pl-traco' : ''}" d="${n === 'parado' ? ECG_PARADO : ECG}"/></svg>
      <span class="pl-gtit">${esc(titulo)}</span><span class="pl-gsub">${esc(sub)}</span></div>`;
  }

  function funil() {
    const f = dados && dados.funil;
    if (!f) return '';
    const h = f.hoje; const o = f.ontem;
    return `<div class="pl-funil"><span class="pl-nome">Funil de hoje</span>
      <span class="pl-princ">${h.conversas}<i>›</i>${h.qualificadas}<i>›</i>${h.vendas}</span>
      <span class="pl-linhas">conversas · qualificada${h.qualificadas === 1 ? '' : 's'} · venda${h.vendas === 1 ? '' : 's'}<br>ontem fechou em ${o.conversas} · ${o.qualificadas} · ${o.vendas}</span></div>`;
  }

  function alerta(cinza) {
    if (cinza) {
      return `<div class="pl-alerta pl-n-sem_leitura" role="alert"><div class="pl-atxt"><strong>A faixa não consegue ler o estado da máquina${recebido ? ` desde ${hm(new Date(recebido - desvio).toISOString())}` : ''}.</strong>
        <span>Os números acima podem estar velhos. Confira a internet e aperte Atualizar.</span></div></div>`;
    }
    const a = dados && dados.alerta;
    if (!a) return '';
    const bt = [];
    if (a.acao === 'esperando' && a.n > 0) bt.push(`<a class="pl-bt pl-bt-pri" href="conversas.html?filtro=esperando" data-visto>Responder ${a.n === 1 ? 'o cliente' : `os ${a.n} clientes`}</a>`);
    if (a.acao === 'meta') bt.push('<a class="pl-bt pl-bt-pri" href="metaads.html" data-visto>Abrir Meta Ads</a>');
    bt.push(`<button type="button" class="pl-bt" data-ver="${esc(a.elo)}" data-visto>Ver o erro</button>`);
    return `<div class="pl-alerta pl-n-${a.nivel}" role="alert"><div class="pl-atxt"><strong>${esc(a.texto)}</strong></div><div class="pl-abts">${bt.join('')}</div></div>`;
  }

  function detalhe(cinza) {
    if (!aberto || !dados || !dados.elos[aberto]) return '';
    const e = dados.elos[aberto];
    let corpo;
    if (aberto === 'fluxos') {
      const linhas = (dados.fluxos || []).map((f) => {
        const ult = f.salva_ok
          ? (f.ultimo_ok_em ? `${hm(f.ultimo_ok_em)} · ${ha(f.ultimo_ok_em)}` : 'ainda sem batimento')
          : (f.ativo_n8n === false ? 'desligado' : f.lido_em ? 'ligado · só guarda erro' : 'ainda sem batimento');
        const est = cinza ? 'sem_leitura' : (f.estado === 'a_ligar' ? 'a_ligar' : f.estado);
        const erro = f.ultimo_erro && f.estado !== 'ok' ? `<small>${esc(f.ultimo_erro)}</small>` : (f.ultimo_erro_em && f.ultimo_erro ? `<small class="pl-velho">último erro ${esc(hm(f.ultimo_erro_em))} · ${esc(ha(f.ultimo_erro_em))}</small>` : '');
        return `<tr><td class="pl-mono">${esc(f.fluxo)}${f.critico ? ' <span class="pl-crit">crítico</span>' : ''}</td><td>${esc(f.descricao)}</td><td>${esc(f.roda)}</td>
          <td class="pl-mono">${esc(ult)}</td><td class="pl-sinal pl-n-${est}">${marca(est === 'a_ligar' ? 'sem_leitura' : est)}${esc(f.sinal)}${erro}</td></tr>`;
      }).join('');
      // 0183: erro de outro fluxo e aviso de governança (ex.: fala do time pelo Chatwoot) não são falha da Mari — aparecem aqui.
      const avisos = (e.motivos || []).map((m) => `<li>${esc(m)}</li>`).join('');
      corpo = (avisos ? `<ul class="pl-lista">${avisos}</ul>` : '') + `<div class="pl-tab"><table><thead><tr><th>Fluxo</th><th>O que faz</th><th>Roda</th><th>Última vez</th><th>Sinal</th></tr></thead><tbody>${linhas}</tbody></table></div>
        <p class="pl-nota">Só mari_principal, mari_cadencia e balanco_diario guardam a execução que deu certo; nos outros o sinal é "ligado e sem erro recente".</p>`;
    } else {
      const itens = [...(e.linhas || []), ...((e.motivos || []).filter((m) => !(e.linhas || []).includes(m)))];
      corpo = `<ul class="pl-lista">${itens.map((l) => `<li>${esc(l)}</li>`).join('')}</ul>`
        + (aberto === 'entrada' && e.custo_conversa ? `<p class="pl-nota">Custo médio por conversa dos últimos dias: R$ ${String(e.custo_conversa).replace('.', ',')}. Esperado = gasto de hoje ÷ esse custo.</p>` : '')
        + (aberto === 'mari' ? '<p class="pl-nota">Os erros da Mari, um a um, ficam na tela Mari › Erros.</p>' : '');
    }
    const link = e.href ? `<a class="pl-bt" href="${esc(aberto === 'entrada' ? 'conversas.html?filtro=abertas' : e.href)}">Abrir ${esc(aberto === 'entrada' ? 'Conversas' : NOME[aberto])}</a>` : '';
    return `<section class="pl-det" id="pl-detalhe" aria-label="Detalhe: ${esc(NOME[aberto])}">
      <div class="pl-dcab"><h2>${esc(NOME[aberto])}</h2><span>${aberto === 'fluxos' ? 'cada fluxo é lido na API do n8n a cada 5 min' : esc(e.rotulo)}</span>
      <span class="pl-dbts">${link}<button type="button" class="pl-bt" data-fechar aria-label="Fechar o detalhe">Fechar</button></span></div>${corpo}</section>`;
  }

  // 14/11 (Ricardo: "mais linhas visíveis na Live"): a faixa fica RECOLHIDA numa linha só — batimento, bolinha e rótulo de cada elo,
  // funil de hoje. Clique abre os dados completos POR CIMA da lista (não empurra a tela); Esc ou clique fora fecha.
  function barra(cinza, elos, nivelG) {
    const g = dados ? dados.geral : { titulo: 'Sem leitura' };
    const f = dados && dados.funil;
    const mini = elos.map((k) => {
      const e = dados.elos[k];
      const n = cinza ? 'sem_leitura' : e.nivel;
      return `<span class="pl-mini pl-n-${n}">${marca(n)}<span class="pl-nome">${esc(NOME[k])}</span><span class="pl-rot">${esc(cinza ? 'sem leitura' : e.rotulo)}</span></span>`;
    }).join('') + extras(cinza).map((x) => `<span class="pl-mini pl-n-${x.n}">${marca(x.n)}<span class="pl-nome">${esc(x.nome)}</span><span class="pl-rot">${esc(x.k === 'filavero' && x.n === 'envio' ? `enviando ${x.principal}` : x.rotulo)}</span></span>`).join('');
    return `<button type="button" class="pl-barra pl-n-${nivelG}" data-expandir aria-expanded="${expandido}" aria-controls="pl-pop"
        aria-label="${esc(cinza ? 'Sem leitura' : g.titulo)}. ${expandido ? 'Recolher' : 'Ver os dados'}" title="${expandido ? 'Recolher' : 'Ver os dados de cada elo'}">
      <span class="pl-mini pl-mgeral pl-n-${nivelG}"><svg class="pl-ecg" aria-hidden="true" viewBox="0 0 150 34"><path class="${nivelG === 'ok' ? 'pl-traco' : ''}" d="${nivelG === 'parado' ? ECG_PARADO : ECG}"/></svg>${nivelG === 'ok' ? '' : `<span class="pl-gtit">${esc(cinza ? 'Sem leitura' : g.titulo)}</span>`}</span>
      ${mini}
      ${f ? `<span class="pl-mini pl-mfunil"><span class="pl-nome">Funil de hoje</span><span class="pl-rot pl-mnum">${f.hoje.conversas} › ${f.hoje.qualificadas} › ${f.hoje.vendas}</span></span>` : ''}
      <span class="pl-chev" aria-hidden="true">${expandido ? '▴' : '▾'}</span></button>`;
  }

  // 15/11: a aba Pulso — cartão geral com os 4 elos, funil de hoje, alerta e detalhe do elo tocado.
  function pintarAba() {
    const cinza = semLeitura();
    const elos = dados ? ORDEM.filter((k) => dados.elos[k]) : [];
    const g = dados ? dados.geral : { titulo: 'Sem leitura', nivel: 'sem_leitura' };
    const nivelG = cinza ? 'sem_leitura' : g.nivel;
    let sub;
    if (cinza) sub = recebido ? `última leitura ${ha(new Date(recebido - desvio).toISOString())}` : 'lendo…';
    else if (g.nivel !== 'ok' && g.desde) sub = `desde ${hm(g.desde)} · ${ha(g.desde).replace('há ', '')}`;
    else sub = new Date().toLocaleString('pt-BR', { weekday: 'short', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit', timeZone: 'America/Sao_Paulo' }).replace(',', ' ·').replace('.', '');
    const linhasElo = elos.map((k) => {
      const e = dados.elos[k];
      const n = cinza ? 'sem_leitura' : e.nivel;
      const v = vivo(k, e);
      const det = (e.linhas || []).slice(0, 2).map((l, i) => (i === 1 && v.linha2 ? v.linha2 : l)).join(' · ');
      return `<button type="button" class="pa-elo pl-n-${n}${aberto === k ? ' pl-sel' : ''}" data-elo="${k}" aria-expanded="${aberto === k}" aria-controls="pl-detalhe">
        <span class="pa-nome">${esc(NOME[k])}</span>
        <span class="pa-corpo"><span class="pa-l1">${marca(n)}<span class="pa-sinal">${esc(cinza ? 'sem leitura' : e.rotulo)}</span><span class="pa-num">${esc(v.principal || e.principal)}</span></span>
        <span class="pa-det">${esc(det)}</span></span><span class="pa-chev" aria-hidden="true">›</span></button>`;
    }).join('') + extras(cinza).map((x) => `<a class="pa-elo pl-n-${x.n}" href="${x.href}">
        <span class="pa-nome">${esc(x.nome)}</span>
        <span class="pa-corpo"><span class="pa-l1">${marca(x.n)}<span class="pa-sinal">${esc(x.rotulo)}</span><span class="pa-num">${esc(x.principal)}</span></span>
        <span class="pa-det">${esc(x.linhas.join(' · '))}</span></span><span class="pa-chev" aria-hidden="true">›</span></a>`).join('');
    const f = dados && dados.funil;
    const funilHtml = f ? `<section class="pa-card"><div class="pa-cab"><b>Funil de hoje</b><span>ontem fechou em ${f.ontem.conversas} · ${f.ontem.qualificadas} · ${f.ontem.vendas}</span></div>
      <div class="pa-funil"><div class="pa-f1"><b>${f.hoje.conversas}</b><span>conversas</span></div><div><b>${f.hoje.qualificadas}</b><span>qualificada${f.hoje.qualificadas === 1 ? '' : 's'}</span></div><div class="pa-fv"><b>${f.hoje.vendas}</b><span>venda${f.hoje.vendas === 1 ? '' : 's'}</span></div></div></section>` : '';
    el.innerHTML = `<section class="pa-card pa-geral pl-n-${nivelG}" aria-label="Pulso da máquina">
        <div class="pa-cab">${marca(nivelG)}<b class="pa-tit">${esc(cinza ? 'Sem leitura' : g.titulo)}</b><span>${esc(sub)}</span></div>
        ${linhasElo || '<p class="pa-vazio">Lendo os elos…</p>'}</section>
      ${alerta(cinza)}
      ${aberto ? detalhe(cinza) : ''}
      ${funilHtml}
      <p class="pa-rodape">Toque num elo para ver o detalhe. Atualiza sozinho a cada minuto.</p>`;
    el.hidden = false;
  }

  function pintar() {
    if (!el) return;
    if (modoAba) { pintarAba(); return; }
    const cinza = semLeitura();
    const elos = dados ? ORDEM.filter((k) => dados.elos[k]) : [];
    const nivelG = cinza ? 'sem_leitura' : (dados ? dados.geral.nivel : 'sem_leitura');
    const pop = el.querySelector('.pl-pop');
    const pos = pop ? pop.scrollTop : 0;
    // 18/11: barra e cartões abertos na mesma grade (--pl-n = partes entre o batimento e a seta) — cada cartão embaixo do seu.
    const ext = extras(cinza);
    // Peso de cada coluna pelo tamanho do texto da barra (Fila Vero "enviando 214/500" é a mais larga; WABA "GREEN" a mais curta).
    const PESO = { meta: 1, entrada: 1, mari: 1.1, fluxos: 1.2, waba: 1, filavero: 1.45, funil: 1.15 };
    const cols = [...elos, ...ext.map((x) => x.k), ...(dados && dados.funil ? ['funil'] : [])].map((k) => `minmax(0, ${PESO[k] || 1}fr)`);
    el.style.setProperty('--pl-cols', `140px ${cols.join(' ')} 30px`);
    el.classList.toggle('pl-aberto', expandido);
    el.innerHTML = `${expandido ? '<div class="pl-fundo" data-fundo aria-hidden="true"></div>' : ''}${barra(cinza, elos, nivelG)}
      ${expandido ? `<div class="pl-pop" id="pl-pop"><section class="pl-faixa pl-n-${nivelG}" aria-label="Pulso da máquina">${geral(cinza)}${elos.map((k) => celula(k, dados.elos[k], cinza)).join('')}${ext.map(celulaExtra).join('')}${funil()}</section>${detalhe(cinza)}</div>` : ''}
      ${alerta(cinza)}`;
    const novo = el.querySelector('.pl-pop');
    if (novo) novo.scrollTop = pos;
    el.hidden = false;
  }

  async function ler() {
    try {
      const [{ data, error }, ex] = await Promise.all([NG.sb.rpc('pulso_operacao'), NG.sb.rpc('pulso_extra').then((r) => r, () => ({}))]);
      extra = ex && !ex.error && ex.data ? ex.data : null;   // 0294: falhou → WABA e Fila Vero somem; o resto segue
      if (error || !data) throw error || new Error('vazio');
      dados = data; recebido = Date.now(); falhou = false;
      desvio = Date.now() - new Date(data.gerado_em).getTime();
      if (Math.abs(desvio) < 5000) desvio = 0;
      if (window.NGSidebar && NGSidebar.pintarStatus && data.selos) NGSidebar.pintarStatus(data.selos);
    } catch (e) { falhou = true; }
    pintar();
  }

  function montar(alvo) {
    el = alvo;
    if (!el) return;
    el.addEventListener('click', (ev) => {
      const b = ev.target.closest('[data-expandir],[data-elo],[data-ver],[data-fechar],[data-visto],[data-fundo]');
      if (!b) return;
      if (b.hasAttribute('data-fundo')) { expandido = false; aberto = null; pintar(); return; }
      if (b.hasAttribute('data-visto')) NG.sb.rpc('pulso_incidente_visto').then(() => {}, () => {});
      // 15/11: no celular a faixa da Live é só o resumo — o toque leva à aba Pulso.
      if (b.hasAttribute('data-expandir') && !modoAba && CEL.matches) { location.href = 'pulso.html'; return; }
      if (b.hasAttribute('data-expandir')) { expandido = !expandido; if (!expandido) aberto = null; pintar(); }
      else if (b.dataset.elo) { aberto = aberto === b.dataset.elo ? null : b.dataset.elo; pintar(); }
      else if (b.dataset.ver) { expandido = true; aberto = b.dataset.ver; pintar(); }
      else if (b.hasAttribute('data-fechar')) { aberto = null; pintar(); }
    });
    const recolher = () => { if (expandido) { expandido = false; aberto = null; pintar(); } };
    el.addEventListener('keydown', (ev) => { if (ev.key === 'Escape' && expandido) { recolher(); const bt = el.querySelector('[data-expandir]'); if (bt) bt.focus(); } });
    document.addEventListener('click', (ev) => { if (expandido && !ev.composedPath().includes(el)) recolher(); });   // composedPath: o alvo pode ter sido redesenhado
    ler();
    clearInterval(timer);
    timer = setInterval(() => { if (document.visibilityState === 'visible') ler(); }, 60000);
    setInterval(() => { if (document.visibilityState === 'visible') pintar(); }, 30000);
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && Date.now() - recebido > 30000) ler(); });
  }

  function montarAba(alvo) { modoAba = true; aberto = null; montar(alvo); }

  window.NGPulso = { montar, montarAba, atualizar: ler };
})();
