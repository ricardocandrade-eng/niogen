/* NIOGEN | docs/assets/pulso.js | 12/11/2026 — Claude Code (docs/Prompt_pulso_live_121126_1035.md · layout docs/LAYOUT_pulso_live_121126_1035.html)
 * Faixa de pulso no topo da Live: Meta Ads → Entrada → Mari → Fluxos n8n + funil de hoje. Uma chamada (RPC pulso_operacao, 0144) a
 * cada 60 s com a aba visível; os "há X min" são refeitos no navegador a cada 30 s. Se a leitura falhar ou envelhecer, a faixa fica
 * cinza com "sem leitura há X" — nunca mostra verde velho. Nível nunca só por cor: bolinha (ok), triângulo (atenção), quadrado
 * (parado), anel (sem leitura) + o rótulo em texto. Clique num elo abre o detalhe; o alerta leva a Conversas › Esperando resposta.
 * Também entrega os selos do menu (NGSidebar.pintarStatus) — na Live o menu não faz chamada própria. Só leitura; sem dado de cliente. */
(function () {
  const ORDEM = ['meta', 'entrada', 'mari', 'fluxos'];
  const NOME = { meta: 'Meta Ads', entrada: 'Entrada', mari: 'Mari', fluxos: 'Fluxos n8n' };
  const NIVEL_TXT = { ok: 'ok', atencao: 'atenção', parado: 'parado', sem_leitura: 'sem leitura' };
  const VELHO_MS = 3 * 60 * 1000;   // retorno com mais de 3 min = sem leitura
  const ECG = 'M0 20 H42 L50 20 L56 6 L64 30 L70 14 L76 20 H104 L110 12 L116 24 L121 20 H150';
  const ECG_PARADO = 'M0 20 H42 L50 20 L56 6 L64 30 L70 14 L76 20 H150';

  let el = null; let dados = null; let recebido = 0; let desvio = 0; let aberto = null; let falhou = false; let timer = null;
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

  function pintar() {
    if (!el) return;
    const cinza = semLeitura();
    const elos = dados ? ORDEM.filter((k) => dados.elos[k]) : [];
    const nivelG = cinza ? 'sem_leitura' : (dados ? dados.geral.nivel : 'sem_leitura');
    el.innerHTML = `<section class="pl-faixa pl-n-${nivelG}" aria-label="Pulso da máquina">${geral(cinza)}${elos.map((k) => celula(k, dados.elos[k], cinza)).join('')}${funil()}</section>
      ${alerta(cinza)}${detalhe(cinza)}`;
    el.hidden = false;
  }

  async function ler() {
    try {
      const { data, error } = await NG.sb.rpc('pulso_operacao');
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
      const b = ev.target.closest('[data-elo],[data-ver],[data-fechar],[data-visto]');
      if (!b) return;
      if (b.hasAttribute('data-visto')) NG.sb.rpc('pulso_incidente_visto').then(() => {}, () => {});
      if (b.dataset.elo) { aberto = aberto === b.dataset.elo ? null : b.dataset.elo; pintar(); }
      else if (b.dataset.ver) { aberto = b.dataset.ver; pintar(); const d = el.querySelector('#pl-detalhe'); if (d) d.scrollIntoView({ block: 'nearest' }); }
      else if (b.hasAttribute('data-fechar')) { aberto = null; pintar(); }
    });
    el.addEventListener('keydown', (ev) => { if (ev.key === 'Escape' && aberto) { aberto = null; pintar(); } });
    ler();
    clearInterval(timer);
    timer = setInterval(() => { if (document.visibilityState === 'visible') ler(); }, 60000);
    setInterval(() => { if (document.visibilityState === 'visible') pintar(); }, 30000);
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && Date.now() - recebido > 30000) ler(); });
  }

  window.NGPulso = { montar, atualizar: ler };
})();
