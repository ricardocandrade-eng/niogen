/* NIOGEN | docs/assets/atendimento.js | 21/11/2026 — Claude Code (Opus 5.5)
 * Faixa de atendimento no topo da Live (Ricardo, 21/11: "Quero a faixa na Live"). Lê a atendimento_leitura() (0339): a leitura do
 * atendimento pelas MENSAGENS (v_atendimento_fatos), nunca pela vez nem pelo status do Chatwoot. Uma chamada a cada 2 min com a aba
 * visível, disparada depois da lista (não atrasa a fila). Mostra, dos leads dos últimos 60 dias de todas as origens:
 *   🔴 esperando nós (o cliente falou por último e ninguém respondeu — a única falha de atendimento) · 🟠 calado e esquecido ·
 *   💰 venda atrasada · 🟢 conversas vivas · ⚪ calados com a cadência/Retomada/dono cuidando · ⏱ % das respostas em até 15 min.
 * Clique num número vermelho/laranja abre a lista daqueles leads; clique num lead abre a ficha (NGFicha). Só leitura. */
(function () {
  const esc = (s) => NG.esc(s == null ? '' : String(s));
  const JANELA_DIAS = 60;
  const CADA_MS = 2 * 60 * 1000;
  let el = null; let dados = null; let aberto = null; let timer = null; let falhou = false;

  const ha = (iso) => {
    if (!iso) return '';
    const min = Math.max(0, (Date.now() - new Date(iso)) / 60000);
    if (min < 60) return `há ${Math.floor(min)} min`;
    if (min < 48 * 60) return `há ${Math.floor(min / 60)} h`;
    return `há ${Math.floor(min / 1440)} d`;
  };
  const dia = (iso) => (iso ? new Date(iso).toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', timeZone: 'America/Sao_Paulo' }) : '');

  const PARTES = [
    { k: 'esperando_nos', ic: '🔴', nome: 'Esperando nós', lista: true, ruim: true },
    { k: 'calado_esquecido', ic: '🟠', nome: 'Calados sem toque', lista: true, ruim: true },
    { k: 'venda_atrasada', ic: '💰', nome: 'Venda atrasada', lista: true, ruim: true },
    { k: 'conversa_viva', ic: '🟢', nome: 'Conversas vivas' },
    { k: 'calado_com_toque', ic: '⚪', nome: 'Calados com cadência' },
  ];

  function linhaLead(f) {
    const quando = f.caixa === 'esperando_nos' ? `esperando ${f.esperando_min ?? '?'} min`
      : f.caixa === 'venda_atrasada' ? `prazo venceu ${dia(f.prazo_em)}` : `cliente falou ${ha(f.cliente_falou_em)}`;
    return `<button type="button" class="at-lead" data-at-lead="${esc(f.lead_id)}"><b>${esc(f.nome || 'sem nome')}</b>`
      + `<span>${esc([f.cidade, f.etapa].filter(Boolean).join(' · '))}</span><em>${esc(quando)}</em></button>`;
  }

  function render() {
    if (!el) return;
    if (!dados) { el.innerHTML = falhou ? '<div class="at-faixa at-sem">Atendimento: sem leitura agora</div>' : ''; return; }
    const cx = dados.caixas || {};
    const tr = dados.tempo_resposta || {};
    const falhas = dados.falhas || [];
    const chips = PARTES.map((p) => {
      const n = cx[p.k] || 0;
      const cls = p.ruim ? (n ? 'at-ruim' : 'at-zero') : 'at-neutro';
      const clicavel = p.lista && n;
      return `<${clicavel ? 'button type="button"' : 'span'} class="at-chip ${cls}${aberto === p.k ? ' at-on' : ''}"${clicavel ? ` data-at="${p.k}"` : ''}`
        + ` title="${esc(p.nome)}">${p.ic} ${esc(p.nome)}: <b>${n}</b></${clicavel ? 'button' : 'span'}>`;
    }).join('');
    const pct = tr.pct_ate_15min != null ? `${String(tr.pct_ate_15min).replace('.', ',')}%` : '—';
    const lista = aberto ? falhas.filter((f) => f.caixa === aberto) : [];
    el.innerHTML = `<div class="at-faixa" role="group" aria-label="Atendimento pelas mensagens">`
      + `<span class="at-tit">Atendimento</span>${chips}`
      + `<span class="at-chip at-neutro" title="Respostas nossas em até 15 min, últimos ${JANELA_DIAS} dias">⏱ ${pct} em até 15 min</span></div>`
      + (lista.length ? `<div class="at-lista">${lista.map(linhaLead).join('')}</div>` : '');
  }

  async function ler() {
    if (document.hidden) return;
    const desde = new Date(Date.now() - JANELA_DIAS * 86400000).toISOString();
    const { data, error } = await NG.sb.rpc('atendimento_leitura', { p_desde: desde });
    if (error) { falhou = true; dados = null; } else { falhou = false; dados = data; }
    if (aberto && !((dados && dados.caixas) || {})[aberto]) aberto = null;
    render();
  }

  function montar(alvo) {
    el = alvo;
    if (!el) return;
    el.addEventListener('click', (ev) => {
      const ld = ev.target.closest('[data-at-lead]');
      if (ld) {
        const k = ld.dataset.atLead;
        if (k.startsWith('c:')) NGFicha.abrirConversa(k.slice(2)); else NGFicha.abrir(k);
        return;
      }
      const ch = ev.target.closest('[data-at]');
      if (ch) { aberto = aberto === ch.dataset.at ? null : ch.dataset.at; render(); }
    });
    ler();
    clearInterval(timer);
    timer = setInterval(ler, CADA_MS);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) ler(); });
  }

  window.NGAtendimento = { montar, ler };
})();
