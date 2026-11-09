/* NIOGEN | docs/assets/conversa.js | 09/11/2026 — Claude Code (docs/Prompt_ajustes_operacao_ficha_conversa_091126_1535.md · ponto 4)
 * A conversa do cliente DENTRO do NIOGEN (o Chatwoot vira reserva: áudio, foto). Um componente, dois lugares:
 *   · Minha vez: abre no espaço da lista (a ficha fica ao lado) — fila.html;
 *   · ficha nas outras telas: painel à esquerda da ficha (gaveta) — ficha.js.
 * Linha 1: ← Lista · nome · Status (Aberta/Resolvida) · Atribuída (Sem dono · Mari atende / você / pessoa / time) · janela 24 h ·
 *          Abrir no Chatwoot ↗.  Linha 2: etiquetas + "+ etiqueta".
 * Pé fixo: Responder | Nota privada · Respostas rápidas (config_mari_textos rr_*: "Rótulo::texto"; janela fechada → templates
 * aprovados) · caixa + Enviar. Só as mensagens rolam; abre na última.
 * Tudo vai pela outbox chatwoot_acoes (RPC backoffice_responder / backoffice_conversa, 0090) — o front não tem token.
 * Os freios (horário, 2/dia · 15/mês, janela 24 h) são do banco: a mensagem do RAISE volta como aviso.
 * Uso: const c = NGConversa.montar(el, { conversaId, nome, aoFechar, rotuloFechar, aoMudar }); c.recarregar(); c.destruir().
 */
(function () {
  'use strict';
  const { esc } = NG;
  // Etiquetas que o time usa no Chatwoot da Nio (as de automação ficam: handoff-*, biometria-pendente, instalacao-agendada).
  const ETIQUETAS = ['interesse-futuro', 'nao-contatar', 'handoff-humano', 'handoff-venda', 'biometria-pendente', 'instalacao-agendada'];
  let rapidasCache = null;
  let tplCache = null;

  const ha = (iso) => {
    const m = Math.max(0, (Date.now() - new Date(iso)) / 60000);
    if (m < 60) return `${Math.round(m)} min`;
    if (m < 48 * 60) return `${Math.floor(m / 60)} h`;
    return `${Math.floor(m / 1440)} d`;
  };
  // Texto do turno: mídia vira "📎 … · ouvir/ver no Chatwoot"; marcações internas da Mari somem.
  function textoTurno(t) {
    let s = String(t || '');
    s = s.replace(/\[MIDIA:(audio|voice)\]/gi, '📎 áudio do cliente · ouvir no Chatwoot')
      .replace(/\[MIDIA:(video)\]/gi, '📎 vídeo do cliente · ver no Chatwoot')
      .replace(/\[MIDIA:(sticker)\]/gi, '📎 figurinha')
      .replace(/\[MIDIA:[a-z]+\]/gi, '📎 arquivo do cliente · ver no Chatwoot')
      .replace(/\[Imagem enviada pelo cliente\]/g, '📎 foto do cliente · ver no Chatwoot');
    s = s.replace(/\[HANDOFF\][\s\S]*?(\[\/HANDOFF\]|$)/gi, '').replace(/\[[A-Z_]{3,}(?::[^\]]*)?\]/g, '');
    return s.trim();
  }

  async function rapidas() {
    if (rapidasCache) return rapidasCache;
    const { data } = await NG.sb.from('config_mari_textos').select('chave, texto').like('chave', 'rr\\_%').order('chave');
    rapidasCache = (data || []).map((r) => {
      const [rot, ...resto] = String(r.texto || '').split('::');
      return resto.length ? { rot: rot.trim(), texto: resto.join('::').trim() } : { rot: r.chave.replace(/^rr_\d*_?/, ''), texto: r.texto };
    });
    return rapidasCache;
  }
  async function templates() {
    if (tplCache) return tplCache;
    const { data } = await NG.sb.from('config_templates_waba').select('nome, corpo, status').eq('status', 'APPROVED').like('nome', 'nio\\_%').order('nome');
    // Só os de 1 parâmetro (o nome): os outros precisam de dados que a caixa não tem.
    tplCache = (data || []).filter((t) => (String(t.corpo || '').match(/\{\{\d+\}\}/g) || []).length <= 1);
    return tplCache;
  }

  function montar(host, opts) {
    const o = { rotuloFechar: '← Lista', ...opts };
    // Raiz própria: os ouvintes ficam nela e somem com ela (montar de novo no mesmo lugar não duplica clique).
    host.innerHTML = '';
    const el = document.createElement('div');
    el.className = 'cvp-raiz';
    host.appendChild(el);
    const st = { d: null, nota: false, tpl: null, rascunho: '', enviando: false, timer: null, fim: true, vivo: true };

    async function carregar() {
      const id = o.conversaId;
      const [rc, rt, ra, rq, rr, rtpl] = await Promise.all([
        NG.sb.from('mari_conversas').select('id, venda_id, telefone, cidade, nome_contato, dados, chatwoot_conversation_id, chatwoot_status, chatwoot_agente, chatwoot_time, chatwoot_etiquetas, humano_atribuido, nao_contatar, ultima_msg_lead_at').eq('id', id).maybeSingle(),
        NG.sb.from('mari_turnos').select('id, papel, texto, tags, created_at').eq('conversa_id', id).order('created_at').order('id').limit(500),
        NG.sb.from('chatwoot_acoes').select('id, tipo, momento, payload, status, erro, criada_em, feita_em').eq('conversa_id', id).in('tipo', ['nota', 'mensagem']).order('criada_em').limit(300),
        NG.sb.from('v_mari_quadro').select('contatos_hoje, contatos_mes, janela_24h_fecha_em').eq('id', id).maybeSingle(),
        rapidas(),
        templates(),
      ]);
      if (!st.vivo) return;
      if (rc.error || !rc.data) { st.d = { erro: rc.error ? NG.msgErro(rc.error) : 'Conversa não encontrada (ou sem permissão).' }; desenhar(); return; }
      st.d = { c: rc.data, turnos: rt.data || [], acoes: ra.data || [], q: rq.data || {}, rapidas: rr || [], tpls: rtpl || [] };
      desenhar();
    }

    const meuNome = () => ((NG.usuario || {}).nome || '').trim();
    function dono(c) {
      if (c.nao_contatar) return { v: 'parar', txt: 'Não contatar' };
      if (c.chatwoot_status === 'resolved') return { v: 'mari', txt: 'Sem dono · Mari atende' };
      if (c.chatwoot_agente) return c.chatwoot_agente === meuNome() ? { v: 'eu', txt: 'Você' } : { v: 'outro', txt: c.chatwoot_agente };
      if (c.humano_atribuido) return { v: 'time', txt: 'Time (assumida)' };
      if (c.chatwoot_time) return { v: 'time', txt: 'Time backoffice' };
      return { v: 'mari', txt: 'Sem dono · Mari atende' };
    }
    function janela(c, q) {
      const fecha = q.janela_24h_fecha_em || (c.ultima_msg_lead_at ? new Date(new Date(c.ultima_msg_lead_at).getTime() + 24 * 3600000).toISOString() : null);
      if (!fecha) return { aberta: false, txt: 'Janela 24 h · fechada (cliente ainda não escreveu)' };
      const min = (new Date(fecha) - Date.now()) / 60000 - 60;   // a Mari usa 23 h de folga: o banco também
      if (min <= 0) return { aberta: false, txt: 'Janela 24 h · fechada · só template' };
      return { aberta: true, txt: `Janela 24 h · fecha em ${min < 60 ? `${Math.round(min)} min` : `${Math.floor(min / 60)} h`}` };
    }
    function mensagens(d) {
      const nome = NG.primeiroNome(d.c.dados && d.c.dados.nome ? d.c.dados.nome : (o.nome || d.c.nome_contato || 'Cliente'));
      const itens = [];
      d.turnos.forEach((t) => {
        const txt = textoTurno(t.texto);
        if (!txt) return;
        if (t.papel === 'sistema') { itens.push({ em: t.created_at, html: `<div class="cvp-b sis">${esc(txt.replace(/^\[|\]$/g, ''))} · ${esc(NG.fmtHora(t.created_at))}</div>` }); return; }
        const quem = t.papel === 'lead' ? nome : t.papel === 'mari' ? (t.tags && t.tags.backoffice ? 'Mari · NIOGEN' : 'Mari') : 'Time';
        itens.push({ em: t.created_at, html: `<div class="cvp-b ${t.papel === 'lead' ? 'cli' : t.papel === 'mari' ? 'mari' : 'hum'}"><small>${esc(quem)} · ${esc(NG.fmtDataHora(t.created_at))}</small>${esc(txt)}</div>` });
      });
      // Notas privadas (nunca viram turno) e mensagens que ainda não saíram (ou não vão sair).
      d.acoes.forEach((a) => {
        const txt = (a.payload || {}).content || '';
        if (a.tipo === 'nota') {
          const s = a.status === 'feita' ? '' : a.status === 'erro' ? ' · ⚠ não foi ao Chatwoot' : ' · salvando…';
          itens.push({ em: a.criada_em, html: `<div class="cvp-b nota"><small>Nota privada · ${esc(a.momento === 'nota' ? 'time' : 'NIOGEN')} · ${esc(NG.fmtDataHora(a.criada_em))}${esc(s)}</small>${esc(txt)}</div>` });
          return;
        }
        if (a.status === 'feita') return;   // já virou turno (Mari pelo resultado; Time pelo motor da Mari)
        const s = a.status === 'bloqueada' ? `⚠ não saiu: ${a.erro || 'freio do contrato'} — mande à mão` : a.status === 'erro' ? `⚠ erro: ${a.erro || ''}`
          : a.status === 'cancelada' ? 'cancelada' : new Date(a.criada_em) < new Date(Date.now() - 3 * 60000) ? 'na fila do envio' : 'enviando…';
        itens.push({ em: a.criada_em, html: `<div class="cvp-b hum pend${['bloqueada', 'erro'].includes(a.status) ? ' falhou' : ''}"><small>${esc((a.payload || {}).como === 'humano' ? 'Você' : 'NIOGEN')} · ${esc(s)}</small>${esc(txt)}</div>` });
      });
      itens.sort((a, b) => new Date(a.em) - new Date(b.em));
      return itens.map((x) => x.html).join('') || '<div class="cvp-b sis">Sem mensagens ainda</div>';
    }

    function desenhar() {
      if (!st.vivo) return;
      const d = st.d;
      if (!d) { el.innerHTML = '<section class="cvp"><div class="cvp-msgs"><div class="carregando">Carregando a conversa…</div></div></section>'; return; }
      if (d.erro) { el.innerHTML = `<section class="cvp"><div class="cvp-l1"><button type="button" class="btn btn-sm" data-cv="fechar">${esc(o.rotuloFechar)}</button></div><div class="cvp-msgs"><div class="vazio">${esc(d.erro)}</div></div></section>`; return; }
      const c = d.c;
      const dn = dono(c);
      const jn = janela(c, d.q);
      const etq = (c.chatwoot_etiquetas || []).filter(Boolean);
      const link = NG.linkChatwoot(c.chatwoot_conversation_id);
      const nome = c.dados && c.dados.nome ? c.dados.nome : (o.nome || c.nome_contato || 'Cliente');
      const msgsAntes = el.querySelector('.cvp-msgs');
      const rolagem = msgsAntes ? msgsAntes.scrollTop : 0;
      const noFim = msgsAntes ? msgsAntes.scrollHeight - msgsAntes.scrollTop - msgsAntes.clientHeight < 40 : true;
      const txtAntes = el.querySelector('[data-cv-txt]');
      if (txtAntes) st.rascunho = txtAntes.value;
      const optsDono = [['mari', 'Sem dono · Mari atende'], ['eu', 'Você'], ['time', 'Time backoffice']];
      if (dn.v === 'outro') optsDono.push(['outro', dn.txt]);
      const usaTpl = !st.nota && !jn.aberta;
      const ajuda = st.nota ? 'Nota privada: só o time vê no Chatwoot.'
        : !jn.aberta ? 'Janela de 24 h fechada: só template aprovado (escolha em Respostas rápidas).'
        : dn.v === 'eu' ? 'Você é o dono · a Mari está calada.'
        : 'Enviar assume a conversa antes (a Mari cala).';
      el.innerHTML = `<section class="cvp${st.nota ? ' nota' : ''}" aria-label="Conversa com ${esc(nome)}">
        <div class="cvp-l1">
          ${o.aoFechar ? `<button type="button" class="btn btn-sm" data-cv="fechar">${esc(o.rotuloFechar)}</button>` : ''}
          <b class="cvp-nome">${esc(nome)}</b><span class="cvp-sep"></span>
          <label class="cvp-f">Status<select data-cv="status"${c.nao_contatar ? ' disabled' : ''}><option value="open"${c.chatwoot_status === 'resolved' ? '' : ' selected'}>Aberta</option><option value="resolved"${c.chatwoot_status === 'resolved' ? ' selected' : ''}>Resolvida</option></select></label>
          <label class="cvp-f">Atribuída<select data-cv="dono"${c.nao_contatar ? ' disabled' : ''}>${optsDono.map(([v, t]) => `<option value="${v}"${v === dn.v ? ' selected' : ''}${v === 'outro' ? ' disabled' : ''}>${esc(t)}</option>`).join('')}</select></label>
          <span class="cvp-sep"></span>
          <span class="cvp-f ${jn.aberta ? '' : 'warn-txt'}">${esc(jn.txt)}</span>
          ${link ? `<a class="cvp-cw" href="${esc(link)}" target="_blank" rel="noopener">Abrir no Chatwoot ↗</a>` : ''}
        </div>
        <div class="cvp-l2"><span class="cvp-f">Etiquetas</span>${etq.length ? etq.map((x) => `<span class="cvp-tg">${esc(x)}<button type="button" data-cv="tirar" data-tg="${esc(x)}" aria-label="Tirar a etiqueta ${esc(x)}" title="Tirar">×</button></span>`).join('') : '<span class="cvp-tg vazia">nenhuma</span>'}
          <select data-cv="etiqueta" aria-label="Pôr etiqueta"><option value="">+ etiqueta</option>${ETIQUETAS.filter((x) => !etq.includes(x)).map((x) => `<option>${esc(x)}</option>`).join('')}</select></div>
        <div class="cvp-msgs" tabindex="0" aria-label="Mensagens">${mensagens(d)}</div>
        <div class="cvp-pe">
          <div class="cvp-ctl">
            <div class="seg cvp-seg" role="group" aria-label="Tipo"><button type="button" data-cv="modo" data-m="resp" class="${st.nota ? '' : 'on'}">Responder</button><button type="button" data-cv="modo" data-m="nota" class="${st.nota ? 'on' : ''}">Nota privada</button></div>
            <select data-cv="rapida" aria-label="Respostas rápidas"><option value="">Respostas rápidas…</option>
              ${usaTpl ? '' : d.rapidas.map((r, i) => `<option value="r:${i}">${esc(r.rot)}</option>`).join('')}
              ${!st.nota && d.tpls.length ? `<optgroup label="Templates aprovados${jn.aberta ? ' (janela fechada)' : ''}">${d.tpls.map((t) => `<option value="t:${esc(t.nome)}"${st.tpl === t.nome ? ' selected' : ''}>${esc(t.nome.replace(/^nio_/, '').replace(/_/g, ' '))}</option>`).join('')}</optgroup>` : ''}
            </select>
            <span class="cvp-ajuda">${esc(ajuda)} · contatos hoje ${esc(d.q.contatos_hoje ?? 0)}/2 · mês ${esc(d.q.contatos_mes ?? 0)}/15</span>
          </div>
          <div class="cvp-caixa"><textarea data-cv-txt rows="2" placeholder="${st.nota ? 'Escrever nota privada…' : st.tpl ? 'Template escolhido — o texto sai como aprovado' : `Responder ${esc(NG.primeiroNome(nome))}…`}"${st.tpl ? ' readonly' : ''}>${esc(st.rascunho)}</textarea>
            <button type="button" class="btn btn-acc" data-cv="enviar"${st.enviando || c.nao_contatar ? ' disabled' : ''}>${st.nota ? 'Salvar nota' : 'Enviar'}</button></div>
        </div>
      </section>`;
      const msgs = el.querySelector('.cvp-msgs');
      if (msgs) msgs.scrollTop = st.fim || noFim ? msgs.scrollHeight : rolagem;
      st.fim = false;
    }

    async function conversaAcao(acao, valor, aviso) {
      const { data, error } = acao === 'momento'
        ? await NG.sb.rpc('backoffice_momento', { p_venda: null, p_momento: valor, p_dados: { conversa_id: o.conversaId } })
        : await NG.sb.rpc('backoffice_conversa', { p_conversa: o.conversaId, p_acao: acao, p_valor: valor });
      if (error) { NG.toast(NG.msgErro(error), 'bad'); await carregar(); return; }
      NG.toast((data && data.resumo) || aviso || 'Feito', 'ok');
      if (o.aoMudar) o.aoMudar(data);
      await carregar();
      depois();
    }
    // Depois de um clique, olha de novo algumas vezes (o n8n executa na hora; o motor grava a fala logo depois).
    function depois() {
      clearTimeout(st.timer);
      let n = 0;
      const passo = async () => { n += 1; if (!st.vivo) return; await carregar(); if (n < 6) st.timer = setTimeout(passo, 5000); };
      st.timer = setTimeout(passo, 3000);
    }

    async function enviar() {
      const ta = el.querySelector('[data-cv-txt]');
      const txt = ta ? ta.value.trim() : '';
      if (!st.tpl && !txt) { NG.toast(st.nota ? 'Escreva a nota.' : 'Escreva a mensagem.', 'bad'); return; }
      st.enviando = true;
      st.rascunho = txt;
      desenhar();
      const { data, error } = await NG.sb.rpc('backoffice_responder', { p_conversa: o.conversaId, p_texto: st.tpl ? '' : txt, p_nota: st.nota, p_template: st.nota ? null : st.tpl });
      st.enviando = false;
      if (error) { NG.toast(NG.msgErro(error), 'bad'); desenhar(); return; }
      st.rascunho = '';
      st.tpl = null;
      st.fim = true;
      NG.toast(data.resumo, 'ok');
      if (o.aoMudar) o.aoMudar(data);
      await carregar();
      depois();
    }

    el.addEventListener('click', (ev) => {
      const b = ev.target.closest('[data-cv]');
      if (!b || b.tagName === 'SELECT') return;
      const a = b.dataset.cv;
      if (a === 'fechar' && o.aoFechar) { o.aoFechar(); return; }
      if (a === 'modo') { st.nota = b.dataset.m === 'nota'; st.tpl = null; desenhar(); const t = el.querySelector('[data-cv-txt]'); if (t) t.focus(); return; }
      if (a === 'enviar') { enviar(); return; }
      if (a === 'tirar') { conversaAcao('etiqueta_remove', b.dataset.tg); }
    });
    el.addEventListener('change', (ev) => {
      const s = ev.target.closest('select[data-cv]');
      if (!s) return;
      const a = s.dataset.cv;
      if (a === 'status') { conversaAcao('status', s.value); return; }
      if (a === 'dono') {
        if (s.value === 'eu') conversaAcao('atribuir', 'eu');
        else if (s.value === 'mari') conversaAcao('atribuir', 'mari');
        else if (s.value === 'time') conversaAcao('atribuir', 'time');
        return;
      }
      if (a === 'etiqueta' && s.value) {
        if (s.value === 'nao-contatar' && !window.confirm('O cliente pediu para não ser contatado?\n\nUse "Cliente pediu para parar" na ficha: além da etiqueta, para tudo e resolve a conversa.')) { s.value = ''; return; }
        conversaAcao('etiqueta_add', s.value);
        return;
      }
      if (a === 'rapida' && s.value) {
        const ta = el.querySelector('[data-cv-txt]');
        if (s.value.startsWith('r:')) {
          const r = st.d.rapidas[Number(s.value.slice(2))];
          st.tpl = null;
          st.rascunho = r ? r.texto : '';
          desenhar();
          const t2 = el.querySelector('[data-cv-txt]');
          if (t2) { t2.focus(); t2.setSelectionRange(t2.value.length, t2.value.length); }
        } else if (s.value.startsWith('t:')) {
          const nome = s.value.slice(2);
          const tpl = st.d.tpls.find((t) => t.nome === nome);
          st.tpl = nome;
          st.rascunho = tpl ? NG.renderTpl(tpl.corpo, [NG.nomeCadencia((st.d.c.dados || {}).nome || st.d.c.nome_contato)]) : '';
          desenhar();
        }
        if (ta) ta.focus();
      }
    });
    el.addEventListener('keydown', (ev) => {
      if (ev.target.matches('[data-cv-txt]') && ev.key === 'Enter' && (ev.ctrlKey || ev.metaKey)) { ev.preventDefault(); enviar(); }
    });
    const intervalo = setInterval(() => { if (document.visibilityState === 'visible' && !st.enviando) carregar(); }, 20000);

    desenhar();
    carregar();
    return {
      recarregar: carregar,
      destruir() { st.vivo = false; clearTimeout(st.timer); clearInterval(intervalo); el.remove(); },
      get id() { return o.conversaId; },
    };
  }

  window.NGConversa = { montar, textoTurno };
})();
