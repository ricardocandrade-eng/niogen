/* NIOGEN | docs/parceiro/pocket.js | 10/11/2026 — Claude Code (docs/Prompt_pocket_parceiro_101126_2025.md)
 * Pocket do Parceiro. Rotas por hash: #entrar · #seja · #inicio · #vendas · #enviar · #pagamentos · #eu.
 * Login v1 = link de acesso de uso único (?acesso=<token_hash>) que o admin manda pelo WhatsApp (edge function parceiro-acesso);
 * a sessão fica guardada e se renova sozinha (refresh token). Sessão própria (storageKey niogen-pocket): não mistura com o NIOGEN.
 * Dados: só RPCs SECURITY DEFINER do parceiro (parceiro_resumo, parceiro_minhas_vendas, parceiro_meus_pagamentos,
 * parceiro_consultar_endereco, parceiro_planos, parceiro_enviar_venda, parceiro_reenviar_venda, parceiro_termo_vigente,
 * parceiro_aceitar_termo, parceiro_material, parceiro_cadastrar). Texto: frases curtas, número grande, nada de sigla.
 */
(function () {
  'use strict';
  const cfg = window.NIOGEN_CONFIG || {};
  const sb = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false, storageKey: 'niogen-pocket' },
  });
  const TZ = 'America/Sao_Paulo';
  const $tela = document.getElementById('tela');
  const $menu = document.getElementById('menu');
  const $app = document.querySelector('.app');

  // ---------- utilidades ----------
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const dig = (s) => String(s ?? '').replace(/\D/g, '');
  const moeda = (v) => Number(v || 0).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL', minimumFractionDigits: Number(v) % 1 ? 2 : 0, maximumFractionDigits: 2 });
  const numero = (v) => Number(v || 0).toLocaleString('pt-BR', { maximumFractionDigits: 0 });
  const dataISO = (iso) => (iso ? new Date(`${String(iso).slice(0, 10)}T12:00:00-03:00`) : null);
  const ddmm = (iso) => (iso ? String(iso).slice(0, 10).split('-').reverse().slice(0, 2).join('/') : '');
  const diaSemana = (iso) => new Intl.DateTimeFormat('pt-BR', { timeZone: TZ, weekday: 'long' }).format(dataISO(iso));
  const nomeMes = (iso) => { const s = new Intl.DateTimeFormat('pt-BR', { timeZone: TZ, month: 'long' }).format(dataISO(iso)); return s.charAt(0).toUpperCase() + s.slice(1); };
  const hojeSP = () => new Intl.DateTimeFormat('en-CA', { timeZone: TZ }).format(new Date());
  const fmtTel = (t) => { let s = dig(t); if (s.startsWith('55') && s.length > 11) s = s.slice(2); return s.length === 11 ? `(${s.slice(0, 2)}) ${s.slice(2, 7)}-${s.slice(7)}` : s.length === 10 ? `(${s.slice(0, 2)}) ${s.slice(2, 6)}-${s.slice(6)}` : s; };
  const erroTxt = (e) => {
    const m = (e && (e.message || e.error_description || e.msg)) || String(e || 'Algo deu errado.');
    if (/Failed to fetch|NetworkError|network/i.test(m)) return 'Sem internet agora. Tente de novo.';
    return m.replace(/^.*?ERROR:\s*/, '');
  };
  let toastT = null;
  function toast(msg, tipo) {
    const t = document.getElementById('toast');
    t.textContent = msg; t.className = `toast${tipo === 'bad' ? ' bad' : ''}`; t.hidden = false;
    clearTimeout(toastT); toastT = setTimeout(() => { t.hidden = true; }, 4200);
  }
  async function rpc(nome, args) {
    const { data, error } = await sb.rpc(nome, args || {});
    if (error) throw error;
    return data;
  }
  const ICO = {
    ok: '<svg aria-hidden="true" viewBox="0 0 24 24"><path d="M5 12l5 5 9-10"/></svg>',
    alerta: '<svg aria-hidden="true" viewBox="0 0 24 24"><path d="M12 8v5M12 17h.01"/><circle cx="12" cy="12" r="9"/></svg>',
    x: '<svg aria-hidden="true" viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg>',
    mais: '<svg aria-hidden="true" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>',
    voltar: '<svg aria-hidden="true" viewBox="0 0 24 24"><path d="M15 6l-6 6 6 6"/></svg>',
    zap: '<svg aria-hidden="true" viewBox="0 0 24 24"><path d="M4 20l1.3-3.9A8 8 0 1 1 8 19z"/></svg>',
  };
  const faixa = (cor, titulo, texto) => `<div class="faixa ${cor}">${cor === 'verde' ? ICO.ok : cor === 'vermelho' ? ICO.x : ICO.alerta}<div>${titulo ? `<b>${esc(titulo)}</b>` : ''}${texto ? `<span>${esc(texto)}</span>` : ''}</div></div>`;
  const voltar = (titulo, para) => `<div class="voltar"><a href="#${para}" aria-label="Voltar">${ICO.voltar}</a><h1>${esc(titulo)}</h1></div>`;
  const linkZap = (num, texto) => (num ? `https://wa.me/${dig(num)}${texto ? `?text=${encodeURIComponent(texto)}` : ''}` : null);

  // ---------- estado ----------
  let RES = null;        // parceiro_resumo()
  let VENDAS = null;     // parceiro_minhas_vendas()
  let PAGS = null;       // parceiro_meus_pagamentos()
  let filtroVendas = null;
  const envio = { passo: 1, inicio: null, end: {}, cons: null, cli: {}, planos: null, plano: null, forma: 'boleto', obs: '', pref: '', enviando: false, ok: null };

  function menu(aba) {
    const logado = !!RES && RES.status === 'ativo';
    $menu.hidden = !logado || !aba;
    $app.classList.toggle('sem-menu', $menu.hidden);
    $menu.querySelectorAll('a').forEach((a) => a.classList.toggle('ativo', a.dataset.tab === aba));
  }
  function render(html, aba) { $tela.innerHTML = html; menu(aba); window.scrollTo(0, 0); }

  async function carregarResumo() { RES = await rpc('parceiro_resumo'); return RES; }
  async function carregarVendas() { VENDAS = await rpc('parceiro_minhas_vendas'); return VENDAS; }
  async function carregarPags() { PAGS = await rpc('parceiro_meus_pagamentos'); return PAGS; }

  // ================================================================ telas públicas
  function telaEntrar(msg) {
    render(`<div style="padding-top:24px"><div class="rot">Parceiro Dharma</div><h1 style="margin-top:6px">Venda Nio e receba toda sexta.</h1></div>
      ${msg ? faixa('amarelo', msg.titulo, msg.texto) : ''}
      <div class="cartao"><b>Já é parceiro?</b><p class="sub">O seu acesso chega pelo WhatsApp da Dharma. Toque no link da mensagem para entrar. Ele vale uma vez só.</p></div>
      <div class="acoes"><a class="bt" href="#seja">Quero ser parceiro</a></div>`, null);
  }

  async function telaSeja() {
    render('<div class="carregando">Carregando…</div>', null);
    let termo = null;
    try { termo = await rpc('parceiro_termo_vigente'); } catch (e) { termo = null; }
    const md = termo && termo.texto && window.NGMarkdown ? window.NGMarkdown.render(termo.texto).html : esc((termo && termo.texto) || '');
    render(`${voltar('Seja parceiro', 'entrar')}
      <p class="sub">Você indica, a Dharma liga para o cliente, faz o pedido e agenda a instalação. Instalou, você recebe na sexta.</p>
      <form id="f-seja" class="lista" novalidate style="gap:14px">
        <div class="campo"><label for="s-nome">Nome completo</label><input id="s-nome" name="nome" autocomplete="name" required></div>
        <div class="campo"><label for="s-cpf">CPF</label><input id="s-cpf" name="cpf" inputmode="numeric" autocomplete="off" placeholder="000.000.000-00" required></div>
        <div class="campo"><label for="s-zap">WhatsApp</label><input id="s-zap" name="zap" type="tel" inputmode="tel" autocomplete="tel" placeholder="(32) 90000-0000" required></div>
        <div class="campo"><label for="s-pix">Chave Pix <small>(tem que estar no seu CPF)</small></label><input id="s-pix" name="pix" autocomplete="off" required></div>
        <div class="campo"><label for="s-cid">Cidade onde você mora</label><input id="s-cid" name="cidade" autocomplete="address-level2" required></div>
        ${termo ? `<div class="campo"><span>Termo do programa</span><div class="termo">${md}</div>
          <label class="check"><input type="checkbox" name="aceite" required> <span>Li e aceito o termo (versão ${esc(termo.versao)}).</span></label></div>` : ''}
        <div class="erro" id="s-erro" role="alert"></div>
        <button type="submit" class="bt">Quero ser parceiro</button>
      </form>`, null);
    const f = document.getElementById('f-seja');
    f.cpf.addEventListener('input', () => { const s = dig(f.cpf.value).slice(0, 11); f.cpf.value = s.length > 9 ? `${s.slice(0, 3)}.${s.slice(3, 6)}.${s.slice(6, 9)}-${s.slice(9)}` : s.length > 6 ? `${s.slice(0, 3)}.${s.slice(3, 6)}.${s.slice(6)}` : s.length > 3 ? `${s.slice(0, 3)}.${s.slice(3)}` : s; });
    f.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const err = document.getElementById('s-erro');
      err.textContent = '';
      if (termo && !f.aceite.checked) { err.textContent = 'Marque que leu e aceita o termo.'; return; }
      const bt = f.querySelector('button[type=submit]');
      bt.disabled = true; bt.textContent = 'Enviando…';
      try {
        const r = await rpc('parceiro_cadastrar', { p_nome: f.nome.value, p_cpf: f.cpf.value, p_whatsapp: f.zap.value, p_pix: f.pix.value,
          p_cidade: f.cidade.value, p_termo_versao: termo ? termo.versao : null });
        render(`<div style="padding-top:40px" class="lista">${faixa('verde', r.mensagem || 'Recebemos.', '')}
          <p class="sub">Guarde este número da Dharma. É dele que vem o seu link de acesso.</p></div>`, null);
      } catch (e) {
        err.textContent = erroTxt(e);
        bt.disabled = false; bt.textContent = 'Quero ser parceiro';
      }
    });
  }

  async function telaTermo() {
    let termo = null;
    try { termo = await rpc('parceiro_termo_vigente'); } catch (e) { termo = null; }
    if (!termo) { location.hash = '#inicio'; return; }
    const md = window.NGMarkdown ? window.NGMarkdown.render(termo.texto).html : esc(termo.texto);
    render(`<h1>Termo do programa</h1><p class="sub">Versão ${esc(termo.versao)}. Leia e aceite para continuar.</p>
      <div class="termo" style="max-height:60vh">${md}</div>
      <label class="check"><input type="checkbox" id="t-ok"> <span>Li e aceito o termo.</span></label>
      <div class="acoes"><button type="button" class="bt" id="t-bt" disabled>Aceitar e continuar</button></div>`, null);
    const ck = document.getElementById('t-ok'), bt = document.getElementById('t-bt');
    ck.addEventListener('change', () => { bt.disabled = !ck.checked; });
    bt.addEventListener('click', async () => {
      bt.disabled = true;
      try { await rpc('parceiro_aceitar_termo', { p_versao: termo.versao }); await carregarResumo(); location.hash = '#inicio'; rota(); }
      catch (e) { toast(erroTxt(e), 'bad'); bt.disabled = false; }
    });
  }

  function telaStatus() {
    const msg = RES.status === 'aguardando'
      ? ['Cadastro em análise', 'A Dharma vai te chamar no WhatsApp. Depois de aprovado, é por aqui que você envia as vendas.']
      : RES.status === 'suspenso' ? ['Cadastro pausado', 'Agora você não pode enviar venda nova. O que já instalou continua sendo pago. Fale com a Dharma.']
        : ['Cadastro encerrado', 'Você não envia mais vendas. O que já instalou continua sendo pago. Fale com a Dharma.'];
    const zap = linkZap(RES.contato_whatsapp, `Oi, sou ${RES.nome}, parceiro Dharma.`);
    render(`<div class="topo"><div><div class="ola">Olá,</div><div class="nome">${esc(RES.primeiro_nome)}</div></div></div>
      ${faixa('amarelo', msg[0], msg[1])}
      ${zap ? `<div class="acoes"><a class="bt zap" href="${esc(zap)}" target="_blank" rel="noopener">${ICO.zap}Falar com a Dharma</a></div>` : ''}`, null);
  }

  // ================================================================ Início
  function termometro(pts) {
    const deg = (RES.degraus || []);
    if (!pts || !deg.length) return '';
    const max = Number(deg[deg.length - 1].pontos);
    const p = Number(pts.pontos || 0);
    const larg = Math.max(2, Math.min(100, (p / max) * 100));
    const prox = pts.proximo_degrau;
    const frase = prox
      ? `<b>Faltam ${numero(pts.faltam_pontos)} pontos</b>${pts.exemplo_plano ? ` (${esc(pts.exemplo_plano)})` : ''} para ganhar <b style="color:var(--verde)">${moeda(prox.premio)}</b> de ajuda este mês.`
      : `<b>Você chegou ao topo.</b> Ajuda de <b style="color:var(--verde)">${moeda(pts.degrau_atual && pts.degrau_atual.premio)}</b> este mês.`;
    return `<div class="cartao" style="gap:12px">
      <div class="linha"><div class="rot">Pontos de ${esc(nomeMes(pts.competencia))}</div><div class="num" style="font-size:22px">${numero(p)}</div></div>
      <div class="barra" role="img" aria-label="${numero(p)} de ${numero(max)} pontos"><i style="width:${larg}%"></i></div>
      <div class="marcas">${deg.map((d) => `<span class="${p >= Number(d.pontos) ? 'ok' : ''}">${numero(d.pontos)} · ${moeda(d.premio)}</span>`).join('')}</div>
      <div style="font-size:16px;line-height:1.4">${frase}</div>
      ${pts.indevida ? '<div class="erro">Este mês teve venda fora das regras: sem ajuda de custo no mês.</div>' : ''}
      <div class="sub">1 real do plano = 1 ponto. Conta só venda instalada.</div></div>`;
  }

  async function telaInicio() {
    render('<div class="carregando">Carregando…</div>', 'inicio');
    try { await Promise.all([carregarResumo(), carregarVendas()]); } catch (e) { return erroCarga(e); }
    if (RES.status !== 'ativo') return telaStatus();
    if (RES.termo && RES.termo.precisa_aceitar) return telaTermo();
    const pts = RES.pontos;
    const pr = RES.proximo;
    const nivel = pts && pts.degrau_atual ? pts.degrau_atual.nome : 'Começando';
    const receber = pr
      ? `<div class="cartao"><div class="rot">${esc(diaSemana(pr.recebe_em))}, ${ddmm(pr.recebe_em)} você recebe</div>
          <div class="grande">${moeda(pr.valor)}</div>
          <div style="font-size:14px;color:var(--suave)">${numero(pr.vendas)} ${Number(pr.vendas) === 1 ? 'venda instalada' : 'vendas instaladas'}${pr.instalacoes_de ? ` de ${ddmm(pr.instalacoes_de)} a ${ddmm(pr.instalacoes_ate)}` : ''}</div></div>`
      : Number(RES.a_confirmar && RES.a_confirmar.valor) > 0
        ? `<div class="cartao"><div class="rot">Você vai receber</div><div class="grande">${moeda(RES.a_confirmar.valor)}</div><div class="sub">Data a confirmar. A Dharma avisa a sexta.</div></div>`
        : `<div class="cartao"><div class="rot">Toda sexta você recebe</div><div style="font-size:16px">Quando a sua venda for instalada, o valor e a sexta do pagamento aparecem aqui.</div></div>`;
    const mesAtual = hojeSP().slice(0, 7);
    const garantia = pts && pts.garantia_ate && String(pts.garantia_ate).slice(0, 7) >= mesAtual
      ? `<div class="faixa verde" style="font-size:14px"><div>Garantia ativa: ${moeda(pts.garantia_piso)} por mês até ${esc(nomeMes(pts.garantia_ate).toLowerCase())}, fazendo ${numero(pts.garantia_min_pontos)} pontos.</div></div>` : '';
    const largada = RES.largada && RES.largada.paga_em && Number(RES.largada.saldo) > 0
      ? `<div class="faixa cinza" style="font-size:14px"><div>Largada: faltam ${moeda(RES.largada.saldo)} para abater (${moeda(RES.largada.por_venda)} por venda instalada).</div></div>` : '';
    const precisa = (VENDAS || []).filter((v) => v.precisa_de_voce);
    render(`<div class="topo"><div><div class="ola">Olá,</div><div class="nome">${esc(RES.primeiro_nome)}</div></div><div class="selo">${esc(nivel)}</div></div>
      ${receber}${termometro(pts)}${garantia}${largada}
      <a class="bt" href="#enviar">${ICO.mais}Enviar venda</a>
      ${precisa.length ? `<div class="lista"><div class="rot">Precisa de você</div>${precisa.map((v) => `<a class="aviso-link" href="#vendas"><span><b>${esc(v.primeiro_nome)}</b>${v.bairro ? ` · ${esc(v.bairro)}` : ''} — ${esc(v.detalhe || v.status_texto)}</span><span>Ver</span></a>`).join('')}</div>` : ''}`, 'inicio');
  }

  // ================================================================ Minhas vendas
  const COR = { nao_aprovada: 'vermelho', cancelada: 'cinza', precisa: 'amarelo', enviada: 'azul', ligando: 'azul', biometria: 'azul', agendando: 'azul', instalacao: 'azul', instalada: 'verde', paga: 'verde' };
  async function telaVendas() {
    render('<div class="carregando">Carregando…</div>', 'vendas');
    try { if (!RES) await carregarResumo(); await carregarVendas(); } catch (e) { return erroCarga(e); }
    if (RES.status !== 'ativo') return telaStatus();
    const lista = VENDAS || [];
    const meses = [...new Set(lista.map((v) => String(v.mes).slice(0, 7)))].sort().reverse();
    const nPrec = lista.filter((v) => v.precisa_de_voce).length;
    if (!filtroVendas || (filtroVendas !== 'precisa' && !meses.includes(filtroVendas))) filtroVendas = nPrec ? 'precisa' : (meses[0] || null);
    const vis = lista.filter((v) => (filtroVendas === 'precisa' ? v.precisa_de_voce : String(v.mes).slice(0, 7) === filtroVendas));
    const chips = [...meses.map((m) => `<button type="button" class="chip${filtroVendas === m ? ' ativo' : ''}" data-f="${m}">${esc(nomeMes(m + '-01'))} · ${lista.filter((v) => String(v.mes).slice(0, 7) === m).length}</button>`),
      `<button type="button" class="chip${filtroVendas === 'precisa' ? ' ativo' : ''}" data-f="precisa">Precisa de você · ${nPrec}</button>`].join('');
    render(`<h1>Minhas vendas</h1>
      ${lista.length ? `<div class="chips" role="group" aria-label="Filtro">${chips}</div>` : ''}
      <div class="lista">${vis.length ? vis.map((v) => `<div class="cartao pequeno venda${v.precisa_de_voce ? ' precisa' : ''}">
          <div class="linha"><b style="font-size:16px">${esc(v.primeiro_nome)}${v.bairro ? ` · ${esc(v.bairro)}` : ''}</b>
            <span class="num" style="font-size:16px${v.valor == null ? ';color:var(--mudo)' : ''}">${v.valor == null ? '—' : moeda(v.valor)}</span></div>
          <div class="linha centro"><span class="plano-nome">${esc(v.plano || '')}</span><span class="pill ${COR[v.situacao] || 'cinza'}">${esc(v.status_texto)}</span></div>
          ${v.detalhe ? `<div class="obs">${v.situacao === 'nao_aprovada' ? 'Motivo: ' : ''}${esc(v.detalhe)}</div>` : ''}
          ${v.pode_reenviar ? `<button type="button" class="bt peq" data-reenviar="${esc(v.venda_id)}">Já falei com o cliente — pode ligar de novo</button>` : ''}
        </div>`).join('') : `<div class="vazio">${lista.length ? 'Nada neste filtro.' : 'Você ainda não enviou vendas.'}</div>`}</div>
      ${!lista.length ? `<a class="bt" href="#enviar">${ICO.mais}Enviar a primeira venda</a>` : ''}`, 'vendas');
    $tela.querySelectorAll('[data-f]').forEach((b) => b.addEventListener('click', () => { filtroVendas = b.dataset.f; telaVendas(); }));
    $tela.querySelectorAll('[data-reenviar]').forEach((b) => b.addEventListener('click', async () => {
      b.disabled = true;
      try { const r = await rpc('parceiro_reenviar_venda', { p_venda: b.dataset.reenviar, p_obs: null }); toast(r.mensagem || 'Pronto.'); telaVendas(); }
      catch (e) { toast(erroTxt(e), 'bad'); b.disabled = false; }
    }));
  }

  // ================================================================ Enviar venda
  function limparEnvio() {
    Object.assign(envio, { passo: 1, inicio: null, end: {}, cons: null, cli: {}, planos: null, plano: null, forma: 'boleto', obs: '', pref: '', enviando: false, ok: null });
  }
  const barraPassos = (n) => `<div class="passos" aria-hidden="true">${[1, 2, 3].map((i) => `<i class="${i <= n ? 'feito' : ''}"></i>`).join('')}</div>`;

  async function telaEnviar() {
    if (!RES) { try { await carregarResumo(); } catch (e) { return erroCarga(e); } }
    if (RES.status !== 'ativo') return telaStatus();
    if (RES.termo && RES.termo.precisa_aceitar) return telaTermo();
    if (envio.ok) return telaEnviada();
    if (!envio.inicio) envio.inicio = Date.now();
    if (envio.passo === 1) return passoEndereco();
    if (envio.passo === 2) return passoCliente();
    return passoPlano();
  }

  function passoEndereco() {
    const e = envio.end;
    render(`${voltar('Enviar venda', 'inicio')}${barraPassos(1)}<div class="sub" style="font-size:15px">Passo 1 de 3 · Endereço do cliente</div>
      <form id="f-end" class="lista" novalidate style="gap:14px">
        <div class="campo"><label for="e-cep">CEP</label><input id="e-cep" inputmode="numeric" autocomplete="postal-code" maxlength="9" placeholder="00000-000" value="${esc(e.cep || '')}"></div>
        <div class="grade2">
          <div class="campo"><label for="e-num">Número</label><input id="e-num" inputmode="numeric" autocomplete="off" value="${esc(e.numero || '')}"></div>
          <div class="campo"><label for="e-comp">Complemento</label><input id="e-comp" autocomplete="off" placeholder="apto, casa" value="${esc(e.complemento || '')}"></div>
        </div>
        <div id="e-rua" class="sub">${e.cidade ? esc([e.logradouro, e.bairro, e.cidade].filter(Boolean).join(' · ')) : 'Digite o CEP: a rua e o bairro aparecem aqui.'}</div>
        <div class="campo" id="e-bairro-c" ${e.cidade ? '' : 'hidden'}><label for="e-bairro">Bairro</label><input id="e-bairro" autocomplete="off" value="${esc(e.bairro || '')}"></div>
        <div id="e-res">${envio.cons ? resEndereco(envio.cons) : ''}</div>
      </form>
      <div class="acoes"><div class="nota">Depois: dados do cliente e plano. A gente liga para ele, faz o pedido e a biometria.</div>
        <button type="button" class="bt sec" id="e-ver">Ver se tem Nio</button>
        <button type="button" class="bt" id="e-seguir" ${envio.cons && envio.cons.pode_seguir ? '' : 'hidden'}>Continuar</button></div>`, null);
    const cep = document.getElementById('e-cep'), num = document.getElementById('e-num'), comp = document.getElementById('e-comp'), bairro = document.getElementById('e-bairro');
    const invalida = () => { envio.cons = null; document.getElementById('e-res').innerHTML = ''; document.getElementById('e-seguir').hidden = true; };
    cep.addEventListener('input', async () => {
      const s = dig(cep.value).slice(0, 8);
      cep.value = s.length > 5 ? `${s.slice(0, 5)}-${s.slice(5)}` : s;
      invalida();
      if (s.length !== 8) return;
      document.getElementById('e-rua').textContent = 'Buscando o CEP…';
      try {
        const j = await fetch(`https://viacep.com.br/ws/${s}/json/`).then((r) => r.json());
        if (j.erro) throw new Error('CEP não encontrado');
        Object.assign(envio.end, { cep: s, logradouro: j.logradouro || '', bairro: j.bairro || '', cidade: j.localidade || '', uf: j.uf || 'MG' });
        document.getElementById('e-rua').textContent = [j.logradouro, j.bairro, `${j.localidade}/${j.uf}`].filter(Boolean).join(' · ');
        document.getElementById('e-bairro-c').hidden = false;
        bairro.value = j.bairro || '';
        if (!num.value) num.focus();
      } catch (err) {
        envio.end.cidade = '';
        document.getElementById('e-rua').textContent = 'Não achamos este CEP. Confira os números.';
      }
    });
    [num, comp, bairro].forEach((el) => el.addEventListener('input', invalida));
    document.getElementById('e-ver').addEventListener('click', async (ev) => {
      const b = ev.currentTarget;
      envio.end.numero = num.value.trim(); envio.end.complemento = comp.value.trim(); envio.end.bairro = bairro.value.trim();
      if (dig(cep.value).length !== 8 || !envio.end.cidade) { toast('Digite um CEP válido.', 'bad'); cep.focus(); return; }
      if (!envio.end.numero) { toast('Falta o número da casa.', 'bad'); num.focus(); return; }
      b.disabled = true; b.textContent = 'Conferindo…';
      try {
        envio.cons = await rpc('parceiro_consultar_endereco', { p_cep: envio.end.cep, p_numero: envio.end.numero, p_complemento: envio.end.complemento || null,
          p_cidade: envio.end.cidade, p_uf: envio.end.uf, p_bairro: envio.end.bairro || null });
        document.getElementById('e-res').innerHTML = resEndereco(envio.cons);
        document.getElementById('e-seguir').hidden = !envio.cons.pode_seguir;
      } catch (e) { toast(erroTxt(e), 'bad'); }
      b.disabled = false; b.textContent = 'Ver se tem Nio';
    });
    document.getElementById('e-seguir').addEventListener('click', () => { envio.passo = 2; envio.planos = null; telaEnviar(); });
    if (!e.cep) setTimeout(() => cep.focus(), 50);
  }
  function resEndereco(c) {
    const lugar = [envio.end.logradouro, envio.end.bairro, envio.end.cidade].filter(Boolean).join(' · ');
    if (c.pode_seguir && c.cobertura === 'tem') return faixa('verde', 'Tem Nio neste endereço', `${lugar}. Ninguém está atendendo este endereço. Pode seguir.`);
    if (c.pode_seguir) return faixa('amarelo', 'Pode enviar', c.mensagem);
    return faixa('vermelho', 'Não dá para enviar', c.mensagem);
  }

  function passoCliente() {
    const c = envio.cli;
    const seg = c.segmento || 'PF';
    render(`${voltar('Enviar venda', 'enviar')}${barraPassos(2)}<div class="sub" style="font-size:15px">Passo 2 de 3 · Cliente</div>
      <form id="f-cli" class="lista" novalidate style="gap:14px">
        <div class="campo"><span>Quem vai contratar</span><div class="seg" role="radiogroup" aria-label="Tipo de cliente">
          <label><input type="radio" name="seg" value="PF" ${seg === 'PF' ? 'checked' : ''}>Pessoa</label>
          <label><input type="radio" name="seg" value="MEI" ${seg === 'MEI' ? 'checked' : ''}>MEI</label>
          <label><input type="radio" name="seg" value="NMEI" ${seg === 'NMEI' ? 'checked' : ''}>Empresa</label></div></div>
        <div class="campo"><label for="c-nome">Nome completo do cliente</label><input id="c-nome" autocomplete="off" value="${esc(c.nome || '')}"></div>
        <div class="campo"><label for="c-doc" id="c-doc-rot">${seg === 'PF' ? 'CPF do cliente' : 'CNPJ da empresa'}</label><input id="c-doc" inputmode="numeric" autocomplete="off" value="${esc(c.doc || '')}"></div>
        <div class="campo"><label for="c-zap">WhatsApp do cliente <small>(a gente liga neste número)</small></label><input id="c-zap" type="tel" inputmode="tel" autocomplete="off" placeholder="(32) 90000-0000" value="${esc(c.zap || '')}"></div>
        <div class="campo"><label for="c-mail">E-mail do cliente <small>(se tiver)</small></label><input id="c-mail" type="email" inputmode="email" autocomplete="off" value="${esc(c.email || '')}"></div>
      </form>
      <div class="acoes"><div class="nota">O cliente precisa atender a ligação da Dharma para a venda seguir.</div>
        <button type="button" class="bt sec" id="c-volta">Voltar ao endereço</button><button type="button" class="bt" id="c-seguir">Continuar</button></div>`, null);
    const f = document.getElementById('f-cli');
    $tela.querySelector('.voltar a').addEventListener('click', (ev) => { ev.preventDefault(); guardarCli(); envio.passo = 1; telaEnviar(); });
    f.addEventListener('change', (ev) => { if (ev.target.name === 'seg') { document.getElementById('c-doc-rot').textContent = ev.target.value === 'PF' ? 'CPF do cliente' : 'CNPJ da empresa'; } });
    document.getElementById('c-volta').addEventListener('click', () => { guardarCli(); envio.passo = 1; telaEnviar(); });
    document.getElementById('c-seguir').addEventListener('click', () => {
      guardarCli();
      const d = dig(envio.cli.doc), z = dig(envio.cli.zap);
      if (!/\S+\s+\S+/.test(envio.cli.nome || '')) return toast('Escreva o nome completo do cliente.', 'bad');
      if (envio.cli.segmento === 'PF' ? d.length !== 11 : d.length !== 14) return toast(envio.cli.segmento === 'PF' ? 'O CPF tem 11 números.' : 'O CNPJ tem 14 números.', 'bad');
      if (z.length < 10) return toast('WhatsApp do cliente: DDD + número.', 'bad');
      envio.passo = 3; telaEnviar();
    });
    function guardarCli() {
      Object.assign(envio.cli, { segmento: (f.querySelector('input[name=seg]:checked') || {}).value || 'PF', nome: document.getElementById('c-nome').value.trim(),
        doc: document.getElementById('c-doc').value.trim(), zap: document.getElementById('c-zap').value.trim(), email: document.getElementById('c-mail').value.trim() });
    }
  }

  async function passoPlano() {
    render(`${voltar('Enviar venda', 'enviar')}${barraPassos(3)}<div class="carregando">Buscando os planos da cidade…</div>`, null);
    if (!envio.planos) {
      try { envio.planos = await rpc('parceiro_planos', { p_cidade: envio.end.cidade, p_uf: envio.end.uf, p_bairro: envio.end.bairro || null }); }
      catch (e) { toast(erroTxt(e), 'bad'); envio.passo = 2; return telaEnviar(); }
    }
    const seg = envio.cli.segmento || 'PF';
    const lista = (envio.planos || []).filter((p) => (p.segmentos || []).includes(seg));
    const preco = (p) => (envio.forma === 'cartao' && p.preco_cartao != null ? p.preco_cartao : p.preco);
    const FORMA = { boleto: 'Boleto', cartao: 'Cartão', dacc: 'Débito na conta' };
    const html = () => `${voltar('Enviar venda', 'enviar')}${barraPassos(3)}<div class="sub" style="font-size:15px">Passo 3 de 3 · Plano e pagamento</div>
      <div class="campo"><span>Como o cliente vai pagar</span><div class="seg" role="radiogroup" aria-label="Forma de pagamento">
        ${Object.entries(FORMA).map(([k, t]) => `<label><input type="radio" name="forma" value="${k}" ${envio.forma === k ? 'checked' : ''}>${t}</label>`).join('')}</div></div>
      <div class="lista" role="radiogroup" aria-label="Plano">${lista.length ? lista.map((p) => {
        const pode = (p.formas || []).includes(envio.forma);
        return `<label class="opcao"${pode ? '' : ' style="opacity:.45"'}><input type="radio" name="plano" value="${p.plano_id}" ${String(envio.plano) === String(p.plano_id) && pode ? 'checked' : ''} ${pode ? '' : 'disabled'}>
          <span class="o-txt"><span class="o-nome">${esc(p.nome_curto)}</span><span class="o-det">${moeda(preco(p))} por mês${pode ? '' : ` · não aceita ${FORMA[envio.forma].toLowerCase()}`}</span></span>
          <span class="o-ganha">você ganha<b>${p.comissao == null ? '—' : moeda(p.comissao)}</b></span></label>`;
      }).join('') : '<div class="vazio">Nenhum plano para este tipo de cliente nesta cidade.</div>'}</div>
      <div class="campo"><span>Melhor período para a instalação <small>(a gente não promete data)</small></span><div class="seg" role="radiogroup" aria-label="Período">
        <label><input type="radio" name="pref" value="" ${!envio.pref ? 'checked' : ''}>Tanto faz</label>
        <label><input type="radio" name="pref" value="manhã" ${envio.pref === 'manhã' ? 'checked' : ''}>Manhã</label>
        <label><input type="radio" name="pref" value="tarde" ${envio.pref === 'tarde' ? 'checked' : ''}>Tarde</label></div></div>
      <div class="campo"><label for="p-obs">Observação <small>(se precisar)</small></label><textarea id="p-obs" maxlength="400">${esc(envio.obs)}</textarea></div>
      <div id="p-ganha"></div>
      <div class="acoes"><button type="button" class="bt sec" id="p-volta">Voltar ao cliente</button><button type="button" class="bt" id="p-enviar">Enviar venda</button></div>`;
    const montar = () => {
      $tela.innerHTML = html();
      const sel = lista.find((p) => String(p.plano_id) === String(envio.plano) && (p.formas || []).includes(envio.forma));
      document.getElementById('p-ganha').innerHTML = sel && sel.comissao != null ? faixa('verde', `Você ganha ${moeda(sel.comissao)} nesta venda`, 'Quando a instalação for feita. Recebe na sexta do ciclo.') : '';
      document.getElementById('p-enviar').disabled = !sel || envio.enviando;
      $tela.querySelectorAll('input[name=forma]').forEach((i) => i.addEventListener('change', () => { envio.forma = i.value; guardar(); montar(); }));
      $tela.querySelectorAll('input[name=plano]').forEach((i) => i.addEventListener('change', () => { envio.plano = i.value; guardar(); montar(); }));
      $tela.querySelectorAll('input[name=pref]').forEach((i) => i.addEventListener('change', () => { envio.pref = i.value; }));
      document.getElementById('p-obs').addEventListener('input', (ev) => { envio.obs = ev.target.value; });
      document.getElementById('p-volta').addEventListener('click', () => { guardar(); envio.passo = 2; telaEnviar(); });
      $tela.querySelector('.voltar a').addEventListener('click', (e) => { e.preventDefault(); guardar(); envio.passo = 2; telaEnviar(); });
      document.getElementById('p-enviar').addEventListener('click', enviar);
    };
    const guardar = () => { const o = document.getElementById('p-obs'); if (o) envio.obs = o.value; };
    async function enviar(ev) {
      const b = ev.currentTarget;
      guardar();
      b.disabled = true; b.textContent = 'Enviando…'; envio.enviando = true;
      try {
        envio.ok = await rpc('parceiro_enviar_venda', { p: {
          cliente_nome: envio.cli.nome, cliente_doc: envio.cli.doc, cliente_whatsapp: envio.cli.zap, cliente_email: envio.cli.email || null,
          segmento: envio.cli.segmento, cep: envio.end.cep, logradouro: envio.end.logradouro, numero: envio.end.numero, complemento: envio.end.complemento || null,
          bairro: envio.end.bairro, cidade: envio.end.cidade, uf: envio.end.uf, plano_id: Number(envio.plano), forma_pagamento: envio.forma,
          instalacao_preferencia: envio.pref || null, observacao: envio.obs || null,
          tempo_s: envio.inicio ? Math.round((Date.now() - envio.inicio) / 1000) : null } });
        VENDAS = null;
        telaEnviada();
      } catch (e) {
        envio.enviando = false;
        toast(erroTxt(e), 'bad');
        b.disabled = false; b.textContent = 'Enviar venda';
      }
    }
    menu(null);
    montar();
  }

  function telaEnviada() {
    const r = envio.ok || {};
    render(`<div style="padding-top:32px" class="lista">${faixa('verde', 'Enviada.', r.mensagem ? r.mensagem.replace(/^Enviada\.\s*/, '') : 'A gente liga para o cliente.')}
      ${r.comissao != null ? `<div class="cartao"><div class="rot">Esta venda vale</div><div class="grande">${moeda(r.comissao)}</div><div class="sub">Quando instalar. Acompanhe em Minhas vendas.</div></div>` : ''}</div>
      <div class="acoes"><button type="button" class="bt" id="n-outra">${ICO.mais}Enviar outra venda</button><a class="bt sec" href="#vendas">Ver minhas vendas</a></div>`, 'inicio');
    document.getElementById('n-outra').addEventListener('click', () => { limparEnvio(); telaEnviar(); });
    $tela.querySelector('a[href="#vendas"]').addEventListener('click', () => limparEnvio());
  }

  // ================================================================ Pagamentos
  async function telaPagamentos() {
    render('<div class="carregando">Carregando…</div>', 'pagamentos');
    try { await Promise.all([carregarResumo(), carregarPags()]); } catch (e) { return erroCarga(e); }
    if (RES.status !== 'ativo' && !(PAGS || []).length) return telaStatus();
    const hoje = hojeSP();
    const porDia = {};
    (PAGS || []).forEach((g) => { if (g.tipo === 'largada') return; const k = g.vence_em || 'confirmar'; (porDia[k] = porDia[k] || []).push(g); });
    const soma = (l) => l.reduce((s, g) => s + Number(g.valor || 0), 0);
    const cal = (RES.calendario || []).filter((c) => c.recebe_em >= hoje);
    const prox = cal.map((c) => {
      const l = (porDia[c.recebe_em] || []).filter((g) => g.status === 'previsto');
      return `<div class="cartao pequeno"><div class="linha"><b>${esc(diaSemana(c.recebe_em))}, ${ddmm(c.recebe_em)}</b><span class="num" style="font-size:18px;color:${l.length ? 'var(--verde)' : 'var(--mudo)'}">${l.length ? moeda(soma(l)) : '—'}</span></div>
        <div class="sub">Instaladas de ${ddmm(c.de)} a ${ddmm(c.ate)}${c.confirmado ? '' : ' · data prevista'}</div></div>`;
    }).join('');
    const aConf = (porDia.confirmar || []).filter((g) => g.status === 'previsto');
    const pagos = Object.entries(porDia).filter(([k, l]) => k !== 'confirmar' && l.some((g) => g.status === 'pago')).sort((a, b) => (a[0] < b[0] ? 1 : -1));
    const ext = (PAGS || []).slice(0, 60).map((g) => `<div class="d-l"><span>${esc(g.tipo_texto)}${g.venda_primeiro_nome ? ` · ${esc(g.venda_primeiro_nome)}` : ''}<br><small>${g.status === 'pago' ? `pago ${ddmm(g.pago_em || g.vence_em)}` : g.vence_em ? `sexta ${ddmm(g.vence_em)}` : 'data a confirmar'}</small></span>
        <b class="${Number(g.valor) < 0 ? 'neg' : ''}">${moeda(g.valor)}${g.tem_comprovante && g.comprovante_path ? `<br><button type="button" class="link-bt" data-comp="${esc(g.comprovante_path)}">Comprovante</button>` : ''}</b></div>`).join('');
    render(`<h1>Pagamentos</h1><p class="sub">Você recebe na sexta depois que a Nio paga a Dharma pelas instalações do ciclo.</p>
      <div class="lista"><div class="rot">Próximas sextas</div>${prox || '<div class="vazio">O calendário das próximas sextas ainda não saiu.</div>'}
        ${aConf.length ? `<div class="cartao pequeno"><div class="linha"><b>Data a confirmar</b><span class="num" style="font-size:18px">${moeda(soma(aConf))}</span></div><div class="sub">A Dharma avisa a sexta assim que a Nio divulgar o ciclo.</div></div>` : ''}</div>
      ${pagos.length ? `<div class="lista"><div class="rot">Já pagas</div>${pagos.map(([k, l]) => `<div class="cartao pequeno"><div class="linha"><b>${ddmm(k)}</b><span class="num" style="font-size:18px">${moeda(soma(l.filter((g) => g.status === 'pago')))}</span></div></div>`).join('')}</div>` : ''}
      <details class="gaveta extrato"${ext ? '' : ' hidden'}><summary>Extrato</summary><div>${ext}</div></details>`, 'pagamentos');
    $tela.querySelectorAll('[data-comp]').forEach((b) => b.addEventListener('click', async () => {
      b.disabled = true;
      const { data, error } = await sb.storage.from('comprovantes_parceiros').createSignedUrl(b.dataset.comp, 60);
      b.disabled = false;
      if (error || !data) return toast('Não deu para abrir o comprovante agora.', 'bad');
      window.open(data.signedUrl, '_blank', 'noopener');
    }));
  }

  // ================================================================ Eu
  async function telaEu() {
    render('<div class="carregando">Carregando…</div>', 'eu');
    try { await carregarResumo(); } catch (e) { return erroCarga(e); }
    let planos = [], material = [];
    try {
      [planos, material] = await Promise.all([
        RES.status === 'ativo' && RES.cidade ? rpc('parceiro_planos', { p_cidade: RES.cidade, p_uf: 'MG', p_bairro: null }) : Promise.resolve([]),
        rpc('parceiro_material'),
      ]);
    } catch (e) { /* mostra o resto */ }
    const zap = linkZap(RES.contato_whatsapp, `Oi, sou ${RES.nome}, parceiro Dharma.`);
    const zapPix = linkZap(RES.contato_whatsapp, `Oi, sou ${RES.nome}, parceiro Dharma. Quero trocar a minha chave Pix.`);
    const t = RES.termo || {};
    const md = (s) => (window.NGMarkdown ? window.NGMarkdown.render(s || '').html : esc(s));
    render(`<h1>Eu</h1>
      <details class="gaveta" open><summary>Meus dados</summary><div>
        <div class="d-l"><span>Nome</span><b>${esc(RES.nome)}</b></div>
        <div class="d-l"><span>WhatsApp</span><b>${esc(fmtTel(RES.whatsapp))}</b></div>
        <div class="d-l"><span>Cidade</span><b>${esc(RES.cidade || '—')}</b></div>
        <div class="d-l"><span>Chave Pix</span><b>${esc(RES.pix_chave || '—')}${RES.pix_conferido ? '<br><small style="color:var(--verde)">conferida ✓</small>' : '<br><small style="color:var(--amarelo)">a Dharma ainda vai conferir</small>'}</b></div>
        ${zapPix ? `<a class="link-bt" href="${esc(zapPix)}" target="_blank" rel="noopener">Trocar a chave Pix (a Dharma confere o titular)</a>` : ''}
        <div class="d-l"><span>Termo aceito</span><b>${t.aceito ? `versão ${esc(t.aceito)} · ${ddmm(t.aceito_em)}` : '—'}</b></div>
      </div></details>
      ${planos.length ? `<details class="gaveta"><summary>Quanto você ganha por plano</summary><div>
        ${planos.map((p) => `<div class="d-l"><span>${esc(p.nome_curto)}<br><small>${moeda(p.preco)} por mês</small></span><b style="color:var(--verde)">${p.comissao == null ? '—' : moeda(p.comissao)}</b></div>`).join('')}
        <div class="sub">Tabela de ${esc(RES.cidade)}. Em outra cidade o valor pode mudar: o app mostra antes de enviar.</div></div></details>` : ''}
      <details class="gaveta"><summary>Regras que você tem que falar</summary><div class="md">
        <ul><li>Fale só os preços da tabela. Nada de desconto, brinde ou prazo diferente.</li>
        <li>Não prometa data de instalação. A Dharma agenda com o cliente.</li>
        <li>O link da biometria chega pela Nio, no WhatsApp e no e-mail do cliente. Ele precisa fazer.</li>
        <li>Quem já é cliente Nio, ou cancelou há pouco, não pode.</li>
        <li>O cliente precisa atender a ligação da Dharma. Sem isso a venda não segue.</li>
        <li>Venda fora das regras não paga e tira a ajuda de custo do mês.</li></ul></div></details>
      ${(material || []).map((m) => `<details class="gaveta"><summary>${esc(m.titulo || m.chave)}</summary><div class="md">${md(m.markdown)}</div></details>`).join('')}
      <div class="acoes">${zap ? `<a class="bt zap" href="${esc(zap)}" target="_blank" rel="noopener">${ICO.zap}Falar com a Dharma</a>` : ''}
        <button type="button" class="bt sec peq" id="sair">Sair deste celular</button></div>`, 'eu');
    document.getElementById('sair').addEventListener('click', async () => { await sb.auth.signOut(); RES = null; VENDAS = null; PAGS = null; location.hash = '#entrar'; rota(); });
  }

  function erroCarga(e) {
    const m = erroTxt(e);
    if (e && (e.code === '42501' || /Acesso só para parceiros/.test(m))) {
      sb.auth.signOut();
      RES = null;
      return telaEntrar({ titulo: 'Este acesso não é de parceiro', texto: 'Peça um novo link à Dharma.' });
    }
    render(`${faixa('amarelo', 'Não carregou', m)}<div class="acoes"><button type="button" class="bt" id="de-novo">Tentar de novo</button></div>`, null);
    document.getElementById('de-novo').addEventListener('click', rota);
  }

  // ================================================================ rotas e login
  let sessao = null;
  async function rota() {
    const h = (location.hash || '').replace('#', '') || (sessao ? 'inicio' : 'entrar');
    if (h === 'seja') return telaSeja();
    if (!sessao) return telaEntrar();
    if (h === 'vendas') return telaVendas();
    if (h === 'enviar') return telaEnviar();
    if (h === 'pagamentos') return telaPagamentos();
    if (h === 'eu') return telaEu();
    if (h === 'entrar') { location.hash = '#inicio'; return; }
    return telaInicio();
  }

  async function iniciar() {
    const qs = new URLSearchParams(location.search);
    const token = qs.get('acesso');
    if (token) {
      history.replaceState(null, '', location.pathname + '#inicio');
      render('<div class="carregando">Entrando…</div>', null);
      await sb.auth.signOut({ scope: 'local' }).catch(() => {});
      const { data, error } = await sb.auth.verifyOtp({ token_hash: token, type: 'magiclink' });
      if (error || !data || !data.session) {
        sessao = null;
        return telaEntrar({ titulo: 'Este link não vale mais', texto: 'Ele vale uma vez só e por pouco tempo. Peça um novo à Dharma.' });
      }
      sessao = data.session;
    } else {
      const { data } = await sb.auth.getSession();
      sessao = data ? data.session : null;
    }
    sb.auth.onAuthStateChange((_ev, s) => { sessao = s; });
    window.addEventListener('hashchange', () => {
      const h = location.hash.replace('#', '');
      if (h !== 'enviar' && (envio.ok || envio.passo === 1)) { if (envio.ok) limparEnvio(); }
      rota();
    });
    rota();
  }

  if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => { navigator.serviceWorker.register('sw.js', { scope: './' }).catch(() => {}); });
  }
  iniciar();
})();
