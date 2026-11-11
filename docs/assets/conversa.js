/* NIOGEN | docs/assets/conversa.js | 09/11/2026 — Claude Code
 * A conversa do cliente DENTRO do NIOGEN, no jeito do WhatsApp Web. Um componente, três lugares: Conversas (conversas.html),
 * Live (no lugar da lista) e a ficha (painel à esquerda da gaveta).
 * rev. 09/11 ~23h (Ricardo: "Enter falhando… telas não estão robustas… funcionamento similar ao WhatsApp Web"):
 *   · O esqueleto é montado UMA vez. A caixa de digitar nunca é redesenhada: o texto e o cursor ficam onde estão. Antes, cada
 *     atualização redesenhava tudo — depois do Enter o texto voltava para a caixa e o cursor sumia (parecia que não enviou).
 *   · Enviar = a mensagem aparece na hora (🕓), a caixa esvazia e o cursor continua nela; ✓ quando o Chatwoot recebeu; ⚠ com
 *     "Reenviar" se falhar. Pode mandar várias seguidas (saem na ordem).
 *   · Só as mensagens se atualizam (a cada 4 s com a aba visível); cabeçalho e etiquetas só quando mudam, e nunca enquanto um
 *     menu deles está aberto. Fora do fim da conversa, chega "↓ novas mensagens" em vez de pular.
 *   · Separador de dia (Hoje, Ontem, data), hora no canto do balão, caixa que cresce até 6 linhas, Enter envia, Shift+Enter pula.
 *   · Sem limite de horário nem de quantidade (0095). Fica só a janela de 24 h do WhatsApp: fechada, só template aprovado.
 * Tudo vai pela outbox chatwoot_acoes (RPC backoffice_responder / backoffice_conversa) — o front não tem token.
 * Uso: const c = NGConversa.montar(el, { conversaId, nome, aoFechar, rotuloFechar, aoMudar }); c.recarregar(); c.destruir().
 */
(function () {
  'use strict';
  const { esc } = NG;
  const ETIQUETAS = ['interesse-futuro', 'nao-contatar', 'handoff-humano', 'handoff-venda', 'biometria-pendente', 'instalacao-agendada'];
  let rapidasCache = null;
  let tplCache = null;

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
  // *negrito* e _itálico_ do WhatsApp, depois de escapar.
  const fmtWa = (s) => esc(s).replace(/\*([^*\n]+)\*/g, '<b>$1</b>').replace(/(^|\s)_([^_\n]+)_(?=\s|$)/g, '$1<i>$2</i>');
  const normal = (s) => String(s || '').replace(/\s+/g, ' ').trim();

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
    tplCache = (data || []).filter((t) => (String(t.corpo || '').match(/\{\{\d+\}\}/g) || []).length <= 1);
    return tplCache;
  }
  const diaRot = (iso) => {
    const d = NG.diaSP(iso);
    const h = NG.diaSP();
    if (d === h) return 'Hoje';
    if (d === NG.somaDias(h, -1)) return 'Ontem';
    return `${NG.fmtDiaSemana(iso)} ${NG.fmtData(iso)}`;
  };

  function montar(host, opts) {
    const o = { rotuloFechar: '← Lista', ...opts };
    host.innerHTML = '';
    const el = document.createElement('div');
    el.className = 'cvp-raiz';
    host.appendChild(el);
    const st = { d: null, nota: false, tpl: null, vivo: true, locais: [], seq: 0, fila: Promise.resolve(), sig: {}, nMsgs: 0, foco: true };

    el.innerHTML = `<section class="cvp">
      <div class="cvp-l1" data-cab><b class="cvp-nome">${esc(o.nome || 'Conversa')}</b></div>
      <div class="cvp-l2" data-etq></div>
      <div class="cvp-meio"><div class="cvp-msgs" data-msgs tabindex="0" aria-label="Mensagens" aria-live="polite"><div class="carregando">Carregando a conversa…</div></div>
        <button type="button" class="cvp-novas" data-cv="descer" hidden>↓ novas mensagens</button></div>
      <div class="cvp-pe">
        <div class="cvp-venda" data-venda hidden></div>
        <div class="cvp-ctl">
          <div class="seg cvp-seg" role="group" aria-label="Tipo"><button type="button" data-cv="modo" data-m="resp" class="on">Responder</button><button type="button" data-cv="modo" data-m="nota">Nota privada</button></div>
          <select data-cv="rapida" aria-label="Respostas rápidas"><option value="">Respostas rápidas…</option></select>
          <span class="cvp-ajuda" data-ajuda></span>
        </div>
        <div class="cvp-caixa"><textarea data-cv-txt rows="1" placeholder="Digite uma mensagem" aria-label="Mensagem"></textarea>
          <button type="button" class="btn btn-acc cvp-enviar" data-cv="enviar" aria-label="Enviar">Enviar</button></div>
      </div>
    </section>`;
    const $ = (s) => el.querySelector(s);
    const cab = $('[data-cab]'), etqEl = $('[data-etq]'), msgs = $('[data-msgs]'), novas = $('[data-cv="descer"]');
    const vendaEl = $('[data-venda]');
    const ta = $('[data-cv-txt]'), btEnviar = $('[data-cv="enviar"]'), selRap = $('[data-cv="rapida"]'), ajudaEl = $('[data-ajuda]');
    const secao = $('.cvp');

    // ---------- dados ----------
    const SEL_CONV = 'id, venda_id, telefone, cidade, nome_contato, dados, chatwoot_conversation_id, chatwoot_status, chatwoot_agente, chatwoot_time, chatwoot_etiquetas, humano_atribuido, nao_contatar, ultima_msg_lead_at';
    const SEL_TURNO = 'id, papel, texto, tags, created_at';
    const qAcoes = (id) => NG.sb.from('chatwoot_acoes').select('id, tipo, momento, payload, status, erro, criada_em, feita_em').eq('conversa_id', id).in('tipo', ['nota', 'mensagem']).order('criada_em', { ascending: false }).limit(200);
    // 11/11 (Live lenta): leve = a atualização de 4 s. Antes cada rodada baixava de novo as 400 mensagens, as 200 ações e a
    // v_jornada; agora traz só as mensagens novas (depois da última), o cabeçalho e as ações. A carga completa fica para a
    // abertura, a volta à aba e depois de uma ação. A linha da jornada vem da carga compartilhada (NG.jornadaLinha).
    async function carregar(leve) {
      const id = o.conversaId;
      const meu = ++st.seq;
      const ult = leve === true && st.d && st.d.turnos.length ? st.d.turnos[st.d.turnos.length - 1].created_at : null;
      const qTurnos = ult
        ? NG.sb.from('mari_turnos').select(SEL_TURNO).eq('conversa_id', id).gte('created_at', ult).order('created_at', { ascending: false }).order('id', { ascending: false }).limit(100)
        : NG.sb.from('mari_turnos').select(SEL_TURNO).eq('conversa_id', id).order('created_at', { ascending: false }).order('id', { ascending: false }).limit(400);
      const [rc, rt, ra, rr, rtpl, vj] = await Promise.all([
        NG.sb.from('mari_conversas').select(SEL_CONV).eq('id', id).maybeSingle(),
        qTurnos,
        qAcoes(id),
        rapidas(),
        templates(),
        // 10/11 (Ricardo): cliente com venda → lembrete âmbar acima da caixa: o próximo passo é pelo botão da ficha.
        NG.jornadaLinha({ conversaComVenda: id }).catch(() => null),
      ]);
      if (!st.vivo || meu !== st.seq) return;
      if (rc.error || !rc.data) {
        if (ult) return;   // falha passageira na atualização leve: mantém o que está na tela
        msgs.innerHTML = `<div class="vazio">${esc(rc.error ? NG.msgErro(rc.error) : 'Conversa não encontrada (ou sem permissão).')}</div>`;
        return;
      }
      st.venda = vj || null;
      let turnos = (rt.data || []).reverse();
      if (ult) {
        if (rt.error) return;
        const tem = new Set(st.d.turnos.map((t) => t.id));
        turnos = st.d.turnos.concat(turnos.filter((t) => !tem.has(t.id)));
      }
      st.d = { c: rc.data, turnos, acoes: ra.error && st.d ? st.d.acoes : (ra.data || []).reverse(), rapidas: rr || [], tpls: rtpl || [] };
      // A mensagem local some quando a ação dela aparece na fila do banco.
      st.locais = st.locais.filter((l) => !(l.acao_id && st.d.acoes.some((a) => a.id === l.acao_id)));
      // 10/11: a ficha/lista de quem abriu a conversa recarrega quando a fala aparece (turno novo, do cliente ou do time) ou a
      // ação enviada muda de estado (🕓 → ✓ / ⚠) — antes só recarregava no instante do envio e a pendência ficava presa.
      const ultT = st.d.turnos[st.d.turnos.length - 1];
      const sigFala = `${st.d.turnos.length}:${ultT ? ultT.id : ''}|${st.d.acoes.map((a) => `${a.id}:${a.status}`).join(',')}`;
      if (st.sigFala != null && st.sigFala !== sigFala && o.aoMudar) o.aoMudar({ eco: true });
      st.sigFala = sigFala;
      // 0107 (🔥 oportunidade no Live): o texto sugerido entra na caixa, editável; a 1ª mensagem sai pela oportunidade_enviar.
      if (o.oportunidade && !st.opPosta) {
        st.opPosta = true;
        if (o.oportunidade.template) st.tpl = o.oportunidade.template;
        ta.value = o.oportunidade.texto || '';
        st.foco = true;
      }
      desenhar();
      if (o.oportunidade && st.opPosta) ajusta();
      if (st.foco && !matchMedia('(max-width: 900px)').matches) { ta.focus({ preventScroll: true }); ta.setSelectionRange(ta.value.length, ta.value.length); st.foco = false; }
    }

    const meuNome = () => ((NG.usuario || {}).nome || '').trim();
    function dono(c) {
      if (c.nao_contatar) return { v: 'parar', txt: 'Não contatar' };
      if (c.chatwoot_agente) return c.chatwoot_agente === meuNome() ? { v: 'eu', txt: 'Você' } : { v: 'outro', txt: c.chatwoot_agente };
      if (c.humano_atribuido) return { v: 'time', txt: 'Time (assumida)' };
      if (c.chatwoot_status === 'resolved') return { v: 'mari', txt: 'Sem dono · Mari atende' };
      if (c.chatwoot_time) return { v: 'time', txt: 'Time backoffice' };
      return { v: 'mari', txt: 'Sem dono · Mari atende' };
    }
    function janela() {
      const d = st.d;
      const ult = d.turnos.filter((t) => t.papel === 'lead').map((t) => t.created_at).pop() || d.c.ultima_msg_lead_at;
      if (!ult) return { aberta: false, txt: 'Janela 24 h fechada · o cliente ainda não escreveu · só template' };
      const min = (new Date(ult).getTime() + 23 * 3600000 - Date.now()) / 60000;
      if (min <= 0) return { aberta: false, txt: 'Janela 24 h fechada · só template' };
      return { aberta: true, txt: `Janela 24 h · fecha em ${min < 60 ? `${Math.round(min)} min` : `${Math.floor(min / 60)} h`}` };
    }

    // ---------- desenho (cada parte só quando muda) ----------
    const troca = (chave, alvo, html) => {
      if (st.sig[chave] === html) return;
      if (alvo.contains(document.activeElement) && document.activeElement.tagName === 'SELECT') return;   // menu aberto: espera
      st.sig[chave] = html;
      alvo.innerHTML = html;
    };
    function desenhar() {
      if (!st.d) return;
      const c = st.d.c;
      const dn = dono(c);
      const jn = janela();
      const nome = (c.dados && c.dados.nome) || o.nome || c.nome_contato || 'Cliente';
      const link = NG.linkChatwoot(c.chatwoot_conversation_id);
      const optsDono = [['mari', 'Sem dono · Mari atende'], ['eu', 'Você'], ['time', 'Time backoffice']];
      // Cliente com venda: "Este cliente tem venda em {etapa} — o próximo passo é {botão}. …" (sem venda: nada).
      const vj = st.venda;
      const passo = vj ? (vj.botao && vj.botao !== 'abrir' && NG.BOTAO_PASSO[vj.botao] ? NG.BOTAO_PASSO[vj.botao] : vj.o_que_fazer) : '';
      const htmlVenda = vj ? `Este cliente tem venda em <b>${esc(vj.etapa_nome || '—')}</b> — o próximo passo é <b>${esc(passo || 'abrir a ficha')}</b>. Faça pelo botão da ficha para a venda andar. <a href="#venda=${esc(vj.venda_id)}">Abrir ficha →</a>` : '';
      vendaEl.hidden = !vj;
      troca('venda', vendaEl, htmlVenda);
      if (dn.v === 'outro') optsDono.push(['outro', dn.txt]);
      // 10/11 (Ricardo: "organiza melhor esse cabeçalho, seguindo esses padrões" — os da ficha): linha 1 = ← Lista · nome ·
      // Chatwoot ↗; linha 2 = chips pequenos (status, dono, janela — os dois primeiros trocam pelo próprio chip); linha 3 =
      // etiquetas em chips finos com o "+ etiqueta" do mesmo tamanho.
      troca('cab', cab, `<div class="cvp-topo">${o.aoFechar ? `<button type="button" class="btn btn-sm" data-cv="fechar">${esc(o.rotuloFechar)}</button>` : ''}
        <b class="cvp-nome" title="${esc(nome)}">${esc(nome)}</b>
        ${link ? `<a class="cvp-cw" href="${esc(link)}" target="_blank" rel="noopener" title="Só para ouvir áudio ou ver foto: responda por aqui">Chatwoot (áudio/foto) ↗</a>` : ''}
        ${o.aoConcluir ? '<button type="button" class="btn btn-acc btn-sm" data-cv="concluir" title="Terminou com este cliente? Fecha o caso e abre o próximo da fila. Até apertar aqui, a conversa fica aberta.">✓ Concluir</button>' : ''}</div>
        <div class="cvp-chips">
        <select class="cvp-pill" data-cv="status" aria-label="Status da conversa" title="Status da conversa"${c.nao_contatar ? ' disabled' : ''}><option value="open"${c.chatwoot_status === 'resolved' ? '' : ' selected'}>Aberta</option><option value="resolved"${c.chatwoot_status === 'resolved' ? ' selected' : ''}>Resolvida</option></select>
        <select class="cvp-pill" data-cv="dono" aria-label="Atribuída a" title="Atribuída a"${c.nao_contatar ? ' disabled' : ''}>${optsDono.map(([v, t]) => `<option value="${v}"${v === dn.v ? ' selected' : ''}${v === 'outro' ? ' disabled' : ''}>${esc(t)}</option>`).join('')}</select>
        <span class="cvp-pill fixo${jn.aberta ? '' : ' warn'}">${esc(jn.txt)}</span></div>`);
      const etq = (c.chatwoot_etiquetas || []).filter(Boolean);
      troca('etq', etqEl, `<span class="cvp-rot">ETIQUETAS</span>${etq.length ? etq.map((x) => `<span class="cvp-tg">${esc(x)}<button type="button" data-cv="tirar" data-tg="${esc(x)}" aria-label="Tirar a etiqueta ${esc(x)}" title="Tirar">×</button></span>`).join('') : '<span class="cvp-tg vazia">nenhuma</span>'}
        <select class="cvp-pill cvp-mais" data-cv="etiqueta" aria-label="Pôr etiqueta"><option value="">+ etiqueta</option>${ETIQUETAS.filter((x) => !etq.includes(x)).map((x) => `<option>${esc(x)}</option>`).join('')}</select>`);
      desenharMsgs();
      desenharPe(jn, dn, nome);
    }

    function itensMsgs() {
      const d = st.d;
      const its = [];
      const turnosOut = d.turnos.filter((t) => t.papel === 'humano' || t.papel === 'mari');
      d.turnos.forEach((t) => {
        const txt = textoTurno(t.texto);
        if (!txt) return;
        if (t.papel === 'sistema') { its.push({ em: t.created_at, tipo: 'sis', txt: txt.replace(/^\[|\]$/g, '') }); return; }
        its.push({ em: t.created_at, tipo: t.papel === 'lead' ? 'cli' : t.papel === 'mari' ? 'mari' : 'hum', txt,
          quem: t.papel === 'mari' ? (t.tags && t.tags.backoffice ? 'Mari · NIOGEN' : 'Mari') : t.papel === 'humano' ? 'Time' : '', tick: t.papel !== 'lead' ? '✓' : '' });
      });
      d.acoes.forEach((a) => {
        const txt = (a.payload || {}).content || '';
        if (a.tipo === 'nota') {
          its.push({ em: a.criada_em, tipo: 'nota', txt, quem: 'Nota privada', tick: a.status === 'feita' ? '✓' : a.status === 'erro' ? '⚠' : '🕓',
            erro: a.status === 'erro' ? (a.erro || 'não foi ao Chatwoot') : '' });
          return;
        }
        // Já virou fala (o motor grava a do time; o resultado grava a da Mari)? Então não repete.
        if (a.status === 'feita' && turnosOut.some((t) => normal(t.texto) === normal(txt) && new Date(t.created_at) >= new Date(new Date(a.criada_em).getTime() - 15000))) return;
        if (a.status === 'cancelada') return;
        const falhou = ['bloqueada', 'erro'].includes(a.status);
        its.push({ em: a.criada_em, tipo: 'hum', txt, quem: (a.payload || {}).como === 'humano' ? 'Você' : 'NIOGEN',
          tick: a.status === 'feita' ? '✓' : falhou ? '⚠' : '🕓', erro: falhou ? (a.erro || 'não saiu') : '', reenviar: falhou && (a.payload || {}).como === 'humano' ? txt : '' });
      });
      st.locais.forEach((l) => its.push({ em: l.em, tipo: l.nota ? 'nota' : 'hum', txt: l.texto, quem: l.nota ? 'Nota privada' : 'Você',
        tick: l.estado === 'erro' ? '⚠' : '🕓', erro: l.estado === 'erro' ? l.erro : '', reenviar: l.estado === 'erro' ? l.texto : '', local: l.id }));
      its.sort((a, b) => new Date(a.em) - new Date(b.em));
      return its;
    }
    function desenharMsgs() {
      const its = itensMsgs();
      let dia = '';
      const html = its.map((x) => {
        const sep = diaRot(x.em) !== dia ? `<div class="cvp-dia"><span>${esc((dia = diaRot(x.em)))}</span></div>` : '';
        if (x.tipo === 'sis') return `${sep}<div class="cvp-b sis">${esc(x.txt)} · ${esc(NG.fmtHora(x.em))}</div>`;
        return `${sep}<div class="cvp-b ${x.tipo}${x.erro ? ' falhou' : ''}${x.tick === '🕓' ? ' pend' : ''}">${x.quem ? `<small class="cvp-quem">${esc(x.quem)}</small>` : ''}<span class="cvp-t">${fmtWa(x.txt)}</span>
          <span class="cvp-h">${esc(NG.fmtHora(x.em))}${x.tick ? ` <i class="cvp-tick" title="${x.tick === '✓' ? 'entregue ao Chatwoot' : x.tick === '🕓' ? 'enviando' : 'não saiu'}">${x.tick}</i>` : ''}</span>
          ${x.erro ? `<span class="cvp-erro">${esc(x.erro)}${x.reenviar ? ` · <button type="button" class="link" data-cv="reenviar" data-txt="${esc(x.reenviar)}"${x.local ? ` data-local="${esc(x.local)}"` : ''}>Reenviar</button>` : ''}</span>` : ''}</div>`;
      }).join('') || '<div class="cvp-b sis">Sem mensagens ainda</div>';
      if (st.sig.msgs === html) return;
      const noFim = msgs.scrollHeight - msgs.scrollTop - msgs.clientHeight < 60 || !st.sig.msgs;
      const antes = st.nMsgs;
      st.sig.msgs = html;
      const topo = msgs.scrollTop;
      msgs.innerHTML = html;
      st.nMsgs = its.length;
      if (noFim || st.descer) { msgs.scrollTop = msgs.scrollHeight; novas.hidden = true; st.descer = false; }
      else { msgs.scrollTop = topo; if (its.length > antes) novas.hidden = false; }
    }
    function desenharPe(jn, dn, nome) {
      secao.classList.toggle('nota', st.nota);
      el.querySelectorAll('[data-cv="modo"]').forEach((b) => b.classList.toggle('on', (b.dataset.m === 'nota') === st.nota));
      const usaTpl = !st.nota && !jn.aberta;
      ta.placeholder = st.nota ? 'Escrever nota privada (só o time vê)…' : st.tpl ? 'Template escolhido — sai o texto aprovado' : usaTpl ? 'Janela de 24 h fechada: escolha um template em Respostas rápidas' : `Mensagem para ${NG.primeiroNome(nome)}`;
      ta.readOnly = !!st.tpl || (usaTpl && !st.tpl);
      btEnviar.textContent = st.nota ? 'Salvar nota' : 'Enviar';
      btEnviar.disabled = !!st.d.c.nao_contatar && !st.nota;
      const opRap = `<option value="">Respostas rápidas…</option>${usaTpl ? '' : st.d.rapidas.map((r, i) => `<option value="r:${i}">${esc(r.rot)}</option>`).join('')}
        ${!st.nota && st.d.tpls.length ? `<optgroup label="Templates aprovados">${st.d.tpls.map((t) => `<option value="t:${esc(t.nome)}">${esc(t.nome.replace(/^nio_/, '').replace(/_/g, ' '))}</option>`).join('')}</optgroup>` : ''}`;
      if (st.sig.rap !== opRap && document.activeElement !== selRap) { st.sig.rap = opRap; selRap.innerHTML = opRap; }
      const op = o.oportunidade && !st.nota;
      const aj = st.d.c.nao_contatar ? 'O cliente pediu para não ser contatado.'
        : st.nota ? 'Nota privada: só o time vê.'
        : op ? `🔥 Oportunidade · ${o.oportunidade.assumir ? 'você assume a conversa (a Mari cala)' : 'a Mari segue a conversa depois (sem dono)'} · nunca desconto nem data de instalação`
        : st.tpl ? 'Template escolhido · Esc cancela'
        : usaTpl ? 'Janela de 24 h fechada (regra do WhatsApp): só template aprovado.'
        : dn.v === 'eu' ? 'Você é o dono · a Mari está calada.' : 'Enviar assume a conversa (a Mari cala).';
      ajudaEl.textContent = `${aj} · Enter envia · Shift+Enter pula linha`;
    }

    // ---------- enviar (aparece na hora; a caixa esvazia e o cursor fica) ----------
    let nLocal = 0;
    function enviar() {
      if (!st.d) return;
      const txt = ta.value.trim();
      if (!st.tpl && !txt) { ta.focus(); return; }
      const item = { id: `l${++nLocal}`, texto: st.tpl ? txt || `[template ${st.tpl}]` : txt, nota: st.nota, tpl: st.nota ? null : st.tpl, em: new Date().toISOString(), estado: 'enviando',
        op: !st.nota && o.oportunidade ? o.oportunidade : null };
      if (item.op) o.oportunidade = null;   // só a 1ª mensagem é a da oportunidade
      st.locais.push(item);
      ta.value = '';
      st.tpl = null;
      ajusta();
      ta.focus();
      st.descer = true;
      desenhar();
      st.fila = st.fila.then(() => enviarUm(item));
    }
    async function enviarUm(item) {
      const { data, error } = item.op
        ? await NG.sb.rpc('oportunidade_enviar', { p_conversa: o.conversaId, p_texto: item.tpl ? '' : item.texto, p_assumir: !!item.op.assumir, p_template: item.tpl })
        : await NG.sb.rpc('backoffice_responder', { p_conversa: o.conversaId, p_texto: item.tpl ? '' : item.texto, p_nota: item.nota, p_template: item.tpl });
      if (item.op && !error) NG.toast(data && data.resumo ? data.resumo : 'Mensagem enviada', 'ok');
      if (!st.vivo) return;
      if (error) {
        if (item.op && !o.oportunidade) o.oportunidade = item.op;   // não saiu: o reenvio volta pela oportunidade
        item.estado = 'erro';
        item.erro = NG.msgErro(error);
        NG.toast(item.erro, 'bad');
      } else {
        item.acao_id = data.acao_id;
        if (data.assumiu) NG.toast('Conversa assumida: a Mari calou', 'ok');
        if (o.aoMudar) o.aoMudar(data);
      }
      desenharMsgs();
      setTimeout(() => carregar(), 1200);
    }

    async function conversaAcao(acao, valor) {
      const { data, error } = await NG.sb.rpc('backoffice_conversa', { p_conversa: o.conversaId, p_acao: acao, p_valor: valor });
      if (error) { NG.toast(NG.msgErro(error), 'bad'); st.sig.cab = st.sig.etq = null; await carregar(); return; }
      NG.toast((data && data.resumo) || 'Feito', 'ok');
      if (o.aoMudar) o.aoMudar(data);
      await carregar();
      setTimeout(() => carregar(), 3000);
    }

    const ajusta = () => { ta.style.height = 'auto'; ta.style.height = `${Math.min(ta.scrollHeight, 150)}px`; };
    ta.addEventListener('input', ajusta);
    // Enter envia; Shift+Enter pula linha. No meio de um acento (IME) não envia. Esc cancela o template.
    ta.addEventListener('keydown', (ev) => {
      if (ev.key === 'Enter' && !ev.shiftKey && !ev.isComposing && ev.keyCode !== 229) { ev.preventDefault(); ev.stopPropagation(); enviar(); return; }
      if (ev.key === 'Escape' && st.tpl) { ev.stopPropagation(); st.tpl = null; ta.value = ''; ajusta(); desenhar(); }
    });
    msgs.addEventListener('scroll', () => { if (msgs.scrollHeight - msgs.scrollTop - msgs.clientHeight < 60) novas.hidden = true; });
    el.addEventListener('click', (ev) => {
      const b = ev.target.closest('[data-cv]');
      if (!b || b.tagName === 'SELECT') return;
      const a = b.dataset.cv;
      if (a === 'fechar' && o.aoFechar) { o.aoFechar(); return; }
      if (a === 'concluir' && o.aoConcluir) { o.aoConcluir(); return; }
      if (a === 'enviar') { enviar(); return; }
      if (a === 'descer') { msgs.scrollTop = msgs.scrollHeight; novas.hidden = true; return; }
      if (a === 'modo') { st.nota = b.dataset.m === 'nota'; st.tpl = null; if (ta.readOnly) ta.value = ''; desenhar(); ta.focus(); return; }
      if (a === 'tirar') { conversaAcao('etiqueta_remove', b.dataset.tg); return; }
      if (a === 'reenviar') {
        if (b.dataset.local) st.locais = st.locais.filter((l) => l.id !== b.dataset.local);
        ta.value = b.dataset.txt || '';
        ajusta(); ta.focus(); desenharMsgs();
      }
    });
    el.addEventListener('change', (ev) => {
      const s = ev.target.closest('select[data-cv]');
      if (!s) return;
      const a = s.dataset.cv;
      if (a === 'status') { conversaAcao('status', s.value); return; }
      if (a === 'dono') { if (['eu', 'mari', 'time'].includes(s.value)) conversaAcao('atribuir', s.value); return; }
      if (a === 'etiqueta' && s.value) {
        if (s.value === 'nao-contatar' && !window.confirm('O cliente pediu para não ser contatado?\n\nUse "Cliente pediu para parar" na ficha: além da etiqueta, para tudo e resolve a conversa.')) { s.value = ''; return; }
        conversaAcao('etiqueta_add', s.value);
        return;
      }
      if (a === 'rapida' && s.value) {
        if (s.value.startsWith('r:')) {
          const r = st.d.rapidas[Number(s.value.slice(2))];
          st.tpl = null;
          ta.readOnly = false;
          ta.value = r ? r.texto : '';
        } else if (s.value.startsWith('t:')) {
          const nomeT = s.value.slice(2);
          const tpl = st.d.tpls.find((t) => t.nome === nomeT);
          st.tpl = nomeT;
          ta.value = tpl ? NG.renderTpl(tpl.corpo, [NG.nomeCadencia((st.d.c.dados || {}).nome || st.d.c.nome_contato)]) : '';
        }
        s.value = '';
        desenhar();
        ajusta();
        ta.focus();
        ta.setSelectionRange(ta.value.length, ta.value.length);
      }
    });
    const intervalo = setInterval(() => { if (document.visibilityState === 'visible') carregar(true); }, 4000);
    const aoVoltar = () => { if (document.visibilityState === 'visible') carregar(); };
    document.addEventListener('visibilitychange', aoVoltar);

    carregar();
    return {
      recarregar: () => carregar(),
      destruir() { st.vivo = false; clearInterval(intervalo); document.removeEventListener('visibilitychange', aoVoltar); el.remove(); },
      focar() { ta.focus(); },
      get id() { return o.conversaId; },
    };
  }

  window.NGConversa = { montar, textoTurno };
})();
