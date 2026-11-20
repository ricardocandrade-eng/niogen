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
 * 12/11 (Live redesenhada · docs/Prompt_live_redesenho_111126_2120.md): opção cheia = a conversa da tela do cliente em tela cheia —
 *   sem o aviso âmbar da venda (a ficha ao lado já diz o próximo passo), caixa de altura fixa e uma faixa da Mari acima dela
 *   (c.mari(html, registro): lembretes, contatos e "Registrar contato", que abre DENTRO da própria caixa). Os cliques da faixa
 *   são tratados por quem montou (a ficha).
 * 15/11 (NIOGEN no celular · docs/LAYOUT_conversas_mobile_151126_1304.html): opção movel = padrão WhatsApp em tela cheia —
 *   cabeçalho fixo (‹ voltar · avatar · nome · "Com a Mari" / "Com humano" · 📞 · ⋮ ficha), faixa de contexto (cidade · plano ·
 *   quanto vale · janela) e o botão "Devolver para a Mari" FIXO no cabeçalho e no fim da conversa, com confirmação de um toque
 *   (1º toque arma por 4 s, 2º devolve pela backoffice_conversa → devolver_mari: lembretes e cadência retomam como hoje).
 *   Envio continua só pelo NIOGEN (o link do Chatwoot não aparece no celular). Desktop: nada muda (sem a opção movel).
 */
(function () {
  'use strict';
  const { esc } = NG;
  const ETIQUETAS = ['interesse-futuro', 'nao-contatar', 'handoff-humano', 'handoff-venda', 'biometria-pendente', 'instalacao-agendada'];
  let rapidasCache = null;
  let tplCache = null;
  let semColunaMidia = false;
  const urlsMidia = new Map();   // caminho no bucket → { url, ate } (URL assinada de 1 h, pedida em lote)

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

  // 20/11 (Ricardo: "a medida que o cliente vai passando os dados pela conversa… sem ter que abrir o perfil dele e ficar copiando e
  // colando dado por dado"): o que dá para reconhecer sozinho numa fala do cliente. CPF só com dígito verificador certo; CEP só com
  // 8 dígitos isolados (não pega pedaço de CPF ou telefone). O resto (nome, rua, número…) vai pela seleção "Gravar como…".
  const CAMPO_ROT = { nome: 'Nome', cpf: 'CPF', email: 'E-mail', cep: 'CEP', rua: 'Rua', numero: 'Número', complemento: 'Complemento', referencia: 'Referência' };
  function capturas(txt) {
    const t = String(txt || '');
    const out = [];
    const vistos = new Set();
    const add = (campo, valor, mostra) => { const k = `${campo}:${valor}`; if (!vistos.has(k)) { vistos.add(k); out.push({ campo, valor, mostra }); } };
    (t.match(/[\w.+-]+@[\w-]+(\.[\w-]+)+/g) || []).forEach((e) => add('email', e.toLowerCase().replace(/\.$/, ''), e.toLowerCase()));
    (t.match(/(?<![\d.\-/])\d{3}\.?\d{3}\.?\d{3}[-\s]?\d{2}(?![\d.\-/])/g) || []).forEach((c) => {
      const n = c.replace(/\D/g, '');
      if (n.length === 11 && NG.documentoValido(n)) add('cpf', n, `${n.slice(0, 3)}.${n.slice(3, 6)}.${n.slice(6, 9)}-${n.slice(9)}`);
    });
    (t.match(/(?<![\d.\-/])\d{5}-?\d{3}(?![\d.\-/])/g) || []).forEach((c) => {
      const n = c.replace(/\D/g, '');
      if (n.length === 8 && !/^0{5}/.test(n)) add('cep', n, `${n.slice(0, 5)}-${n.slice(5)}`);
    });
    return out;
  }
  const normCampo = (campo, v) => (campo === 'email' ? String(v || '').trim().toLowerCase() : ['cpf', 'cep'].includes(campo) ? String(v || '').replace(/\D/g, '') : String(v || '').trim().toLowerCase());
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
  // 12/11 (Ricardo: "O Niogen está sem opção de enviar emojis"): lista fixa, sem biblioteca (regra 19). Recentes por usuário
  // no localStorage (conveniência, não dado de operação).
  const EMO_ABAS = [
    ['⭐', 'Mais usados', '👍 🙏 😊 😉 😄 ✅ 👏 🙌 ❤️ 🤝 👋 😅 🥰 😍 🤗 👌'],
    ['😀', 'Rostos', '😀 😃 😁 😂 🤣 🙂 😇 😌 😎 🤩 🤔 🤨 😐 😬 🙄 😮 😯 😢 😭 😔 😕 🙁 😴 🥳 😱 🤭 🫡 🫶'],
    ['👋', 'Gestos', '👍 👎 👌 ✌️ 🤞 🤙 👈 👉 👆 👇 ☝️ ✋ 🖐️ 👏 🙌 🙏 💪 🤝 👊 🫵'],
    ['📶', 'Atendimento', '📶 🏠 📍 📅 ⏰ 📞 📱 💻 📺 🎮 💬 📄 📝 💳 💰 🎉 🚀 ⚡ 🔧 🛠️ 📦 🔒'],
    ['✔️', 'Símbolos', '✔️ ✅ ❌ ⚠️ ℹ️ ❗ ❓ ⬇️ ⬆️ ➡️ 🔥 ⭐ ✨ 💙 💜 💚 🧡 💛 🔴 🟢 🟡 🔵'],
  ].map(([ico, rot, s]) => ({ ico, rot, lista: s.split(' ') }));
  const EMO_CHAVE = 'ng_emoji_rec';
  const emoRecentes = () => { try { const v = JSON.parse(localStorage.getItem(EMO_CHAVE) || '[]'); return Array.isArray(v) ? v.slice(0, 12) : []; } catch (e) { return []; } };
  const emoGuardar = (e) => { try { localStorage.setItem(EMO_CHAVE, JSON.stringify([e, ...emoRecentes().filter((x) => x !== e)].slice(0, 12))); } catch (x) { /* sem storage: segue */ } };
  const diaRot = (iso) => {
    const d = NG.diaSP(iso);
    const h = NG.diaSP();
    if (d === h) return 'Hoje';
    if (d === NG.somaDias(h, -1)) return 'Ontem';
    return `${NG.fmtDiaSemana(iso)} ${NG.fmtData(iso)}`;
  };

  // 18/11 (0297): estilo do ✨ Sugerir resposta, injetado uma vez (mesmos tokens do app.css; modo escuro e 390 px sem rolagem lateral).
  function estiloSugestao() {
    if (document.getElementById('cvp-sug-css')) return;
    const s = document.createElement('style');
    s.id = 'cvp-sug-css';
    s.textContent = `
.cvp-sug-bt { min-height: 30px; white-space: nowrap; }
.cvp-sug { margin: 6px 0 4px; font-size: 12.5px; }
.cvp-sug .link { background: none; border: 0; color: var(--link); cursor: pointer; font: inherit; padding: 0 4px; margin-left: auto; }
.cvp-sug-linha, .cvp-sug-faixa, .cvp-sug-cab { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; color: var(--muted); }
.cvp-sug-linha.erro { color: var(--warn-fg); }
.cvp-sug-faixa { background: var(--info-bg); color: var(--info-fg); border-radius: 8px; padding: 4px 8px; }
.cvp-sug-cab .aviso { color: var(--warn-fg); }
.cvp-sug-ops { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 6px; margin-top: 6px; }
.cvp-sug-op { display: flex; flex-direction: column; gap: 3px; text-align: left; background: var(--surface-2); color: var(--text);
  border: 1px solid var(--border-strong); border-radius: 10px; padding: 8px 10px; cursor: pointer; font: inherit; font-size: 13px; line-height: 1.35; min-width: 0; }
.cvp-sug-op:hover, .cvp-sug-op:focus-visible { border-color: var(--accent); outline: none; }
.cvp-sug-op small { color: var(--accent); font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .02em; }
.cvp-sug-op span { overflow-wrap: anywhere; white-space: pre-line; }
.cvp-sug-gira { display: inline-block; animation: cvp-sug-gira 1.2s linear infinite; }
@keyframes cvp-sug-gira { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) { .cvp-sug-gira { animation: none; } }
.cvp-raiz.cheia .cvp-pe.com-sug { height: auto; max-height: 72%; min-height: 196px; }
.cvp-raiz.cheia .cvp-pe.com-sug > :not(.cvp-sug) { flex: none; }
.cvp-raiz.cheia .cvp-pe.com-sug .cvp-sug { flex: 1 1 auto; min-height: 0; overflow-y: auto; margin: 0; }
.cvp-raiz.cheia .cvp-sug-cab { position: sticky; top: 0; z-index: 1; background: var(--bg); padding: 2px 0 4px; }
.cvp-raiz.cheia .cvp-sug-bt { height: 28px; min-height: 28px; font-size: 12.5px; }
@media (max-width: 640px) { .cvp-sug-ops { grid-template-columns: 1fr; max-height: 38vh; overflow-y: auto; } .cvp-raiz.movel .cvp-sug-bt { padding: 0 8px; } }`;
    document.head.appendChild(s);
  }

  function montar(host, opts) {
    const o = { rotuloFechar: '← Lista', ...opts };
    host.innerHTML = '';
    const el = document.createElement('div');
    el.className = 'cvp-raiz';
    host.appendChild(el);
    const st = { d: null, nota: false, sopro: false, tpl: null, vivo: true, locais: [], seq: 0, fila: Promise.resolve(), sig: {}, nMsgs: 0, foco: true };

    el.innerHTML = `<section class="cvp">
      <div class="cvp-mv-cab" data-mvcab hidden></div>
      <div class="cvp-ctx" data-ctx hidden></div>
      <div class="cvp-l1" data-cab><b class="cvp-nome">${esc(o.nome || 'Conversa')}</b></div>
      <div class="cvp-l2" data-etq></div>
      <div class="cvp-meio"><div class="cvp-msgs" data-msgs tabindex="0" aria-label="Mensagens" aria-live="polite"><div class="carregando">Carregando a conversa…</div></div>
        <button type="button" class="cvp-novas" data-cv="descer" hidden>↓ novas mensagens</button></div>
      <div class="cvp-devolver" data-devolver hidden></div>
      <div class="cvp-pe">
        <div class="cvp-venda" data-venda hidden></div>
        <div class="cvp-mari" data-mari hidden></div>
        <div class="cvp-ctl">
          <div class="seg cvp-seg" role="group" aria-label="Tipo"><button type="button" data-cv="modo" data-m="resp" class="on">Responder</button><button type="button" data-cv="modo" data-m="nota">Nota privada</button><button type="button" data-cv="modo" data-m="sopro" hidden title="Soprar: o cliente recebe como fala da Mari; a Mari segue com a conversa (ninguém assume)">🌬️ Soprar</button></div>
          <select data-cv="rapida" aria-label="Respostas rápidas"><option value="">Respostas rápidas…</option></select>
          <button type="button" class="btn btn-sm cvp-sug-bt" data-cv="sugerir" hidden>✨ Sugerir resposta</button>
          <span class="cvp-ajuda" data-ajuda></span>
        </div>
        <div class="cvp-sug" data-sug hidden aria-live="polite"></div>
        <div class="cvp-cita" data-cita hidden></div>
        <div class="cvp-anexo" data-anexo hidden></div>
        <div class="cvp-caixa vazia"><span class="cvp-quem-ico" data-quem hidden></span><button type="button" class="cvp-clip" data-cv="clip" aria-label="Anexar foto ou documento" aria-expanded="false" title="Anexar foto ou documento">📎</button><div class="cvp-clip-menu" data-clipmenu hidden><button type="button" data-cv="clip-foto">📷 Foto</button><button type="button" data-cv="clip-doc">📄 Documento</button></div><input type="file" data-arq="imagem" accept="image/jpeg,image/png,image/webp" hidden><input type="file" data-arq="arquivo" accept=".pdf,.doc,.docx,.xls,.xlsx,.txt,application/pdf" hidden><button type="button" class="cvp-emo-bt" data-cv="emoji" aria-label="Emojis" aria-expanded="false" title="Emojis">😊</button><div class="cvp-emo" data-emo hidden></div><textarea data-cv-txt rows="1" placeholder="Digite uma mensagem" aria-label="Mensagem"></textarea>
          <button type="button" class="cvp-mic" data-cv="mic" aria-label="Gravar áudio" title="Gravar áudio">🎤</button><button type="button" class="btn btn-acc cvp-enviar" data-cv="enviar" aria-label="Enviar">Enviar</button></div>
      </div>
    </section>`;
    const $ = (s) => el.querySelector(s);
    const cab = $('[data-cab]'), etqEl = $('[data-etq]'), msgs = $('[data-msgs]'), novas = $('[data-cv="descer"]');
    const vendaEl = $('[data-venda]');
    const mariEl = $('[data-mari]');
    if (o.cheia) el.classList.add('cheia');
    if (o.movel) el.classList.add('movel');
    const mvCab = $('[data-mvcab]'), ctxEl = $('[data-ctx]'), devEl = $('[data-devolver]');
    const quemEl = $('[data-quem]');
    const ta = $('[data-cv-txt]'), btEnviar = $('[data-cv="enviar"]'), selRap = $('[data-cv="rapida"]'), ajudaEl = $('[data-ajuda]');
    const secao = $('.cvp');
    const emoBt = $('[data-cv="emoji"]'), emoEl = $('[data-emo]');
    st.emoAba = 0;
    const sugBt = $('[data-cv="sugerir"]'), sugEl = $('[data-sug]');
    // 18/11 (0297, docs/Prompt_sugerir_resposta_ia_181126_1825.md): ✨ Sugerir resposta — em Conversas e na ficha (a ficha monta a
    // conversa no modo cheia, em qualquer tela — Ricardo, 18/11: "Faltou acrescentar o botão ✨ na conversa da ficha") e, desde
    // 18/11 ~20h10, também na tela Live (Ricardo: "Mas dá pra colocar aqui tbem" — regra 20 atendida: pedido dele). Só admin/backoffice.
    const podeSugerir = ['admin', 'backoffice'].includes(((NG.usuario || {}).perfil) || '');
    if (podeSugerir) estiloSugestao();
    // 18/11 (0299, Ricardo: "Faz só o soprar pra Mari agora" — ponderação 3 de 16/11): "Pela Mari" = o time escreve, o cliente recebe
    // como fala da Mari e ela segue dona e com o contexto (ninguém assume nem devolve). Só admin/backoffice; o banco confere tudo.
    if (podeSugerir) $('[data-m="sopro"]').hidden = false;

    // ---------- dados ----------
    const SEL_CONV = 'id, venda_id, telefone, cidade, nome_contato, dados, chatwoot_conversation_id, chatwoot_status, chatwoot_agente, chatwoot_time, chatwoot_etiquetas, humano_atribuido, nao_contatar, ultima_msg_lead_at';
    // 12/11 (0145): midia = áudio/foto do cliente no bucket privado. Banco sem a coluna ainda → cai para a lista antiga.
    const SEL_TURNO_BASE = 'id, papel, texto, tags, created_at';
    const selTurno = () => (semColunaMidia ? SEL_TURNO_BASE : `${SEL_TURNO_BASE}, midia`);
    const qTurnosDe = (id, ult) => (ult
      ? NG.sb.from('mari_turnos').select(selTurno()).eq('conversa_id', id).gte('created_at', ult).order('created_at', { ascending: false }).order('id', { ascending: false }).limit(100)
      : NG.sb.from('mari_turnos').select(selTurno()).eq('conversa_id', id).order('created_at', { ascending: false }).order('id', { ascending: false }).limit(400));
    const qAcoes = (id) => NG.sb.from('chatwoot_acoes').select('id, tipo, momento, payload, status, erro, criada_em, feita_em').eq('conversa_id', id).in('tipo', ['nota', 'mensagem', 'midia']).order('criada_em', { ascending: false }).limit(200);
    // 11/11 (Live lenta): leve = a atualização de 4 s. Antes cada rodada baixava de novo as 400 mensagens, as 200 ações e a
    // v_jornada; agora traz só as mensagens novas (depois da última), o cabeçalho e as ações. A carga completa fica para a
    // abertura, a volta à aba e depois de uma ação. A linha da jornada vem da carga compartilhada (NG.jornadaLinha).
    async function carregar(leve) {
      const id = o.conversaId;
      const meu = ++st.seq;
      const ult = leve === true && st.d && st.d.turnos.length ? st.d.turnos[st.d.turnos.length - 1].created_at : null;
      const qTurnos = qTurnosDe(id, ult).then((r) => {
        if (r.error && !semColunaMidia && /midia/i.test(String(r.error.message || ''))) { semColunaMidia = true; return qTurnosDe(id, ult); }
        return r;
      });
      // 10/11 (Ricardo): cliente com venda → lembrete âmbar acima da caixa: o próximo passo é pelo botão da ficha.
      // 11/11: não segura as mensagens — entra quando a jornada chegar.
      NG.jornadaLinha({ conversaComVenda: id }).then((vj) => {
        if (!st.vivo || o.conversaId !== id) return;
        st.venda = vj || null;
        if (st.d) desenhar();
      }, () => {});
      // 12/11 (0146): voz e imagem que a Mari mandou (mari_midia_envios) — na mesma rodada paralela (regra 19)
      const qEnvios = NG.sb.from('mari_midia_envios').select('id, tipo, texto, caminho, imagem_url, passo, origem, created_at')
        .eq('conversa_id', id).eq('ok', true).order('created_at', { ascending: false }).limit(60).then((r) => r, () => ({ data: [] }));
      // 20/11 (0331, prompt "conversa sem Chatwoot", item 1): o anúncio que o cliente clicou — só na 1ª carga, na mesma rodada paralela
      // (regra 19); lê do banco o que a coleta da Meta trouxe (nunca a Meta na abertura). Sem referral, não aparece.
      const qAnuncio = ult || st.anuncio !== undefined ? Promise.resolve(null)
        : NG.sb.from('v_mari_conversa_anuncio').select('ad_nome, titulo, anuncio_texto, titulo_ad, arte_url, arte_miniatura, campanha_nome, referral_em, source_url')
          .eq('conversa_id', id).maybeSingle().then((r) => (r && !r.error ? r.data || null : null), () => null);
      // 20/11 (0334): status de cada mensagem no Chatwoot (✓ enviada · ✓✓ entregue · ✓✓ azul lida) e o id para citar
      const qMsgCw = (ult ? NG.sb.from('mari_msg_cw').select('cw_msg_id, direcao, status, texto, criado_em').eq('conversa_id', id).gt('atualizado_em', st.msgCwAte || ult)
        : NG.sb.from('mari_msg_cw').select('cw_msg_id, direcao, status, texto, criado_em').eq('conversa_id', id).order('criado_em', { ascending: false }).limit(300))
        .then((r) => (r && !r.error ? r.data || [] : null), () => null);
      const tMsgCw = new Date().toISOString();
      const [rc, rt, ra, rr, rtpl, rme, ran, rmc] = await Promise.all([
        NG.sb.from('mari_conversas').select(SEL_CONV).eq('id', id).maybeSingle(),
        qTurnos,
        qAcoes(id),
        rapidas(),
        templates(),
        qEnvios,
        qAnuncio,
        qMsgCw,
      ]);
      if (rmc) { if (!st.msgCw || !ult) st.msgCw = new Map(); rmc.forEach((m) => st.msgCw.set(m.cw_msg_id, m)); st.msgCwAte = tMsgCw; }
      if (!ult && st.anuncio === undefined) st.anuncio = ran || null;
      if (!st.vivo || meu !== st.seq) return;
      if (rc.error || !rc.data) {
        if (ult) return;   // falha passageira na atualização leve: mantém o que está na tela
        msgs.innerHTML = `<div class="vazio">${esc(rc.error ? NG.msgErro(rc.error) : 'Conversa não encontrada (ou sem permissão).')}</div>`;
        return;
      }
      let turnos = (rt.data || []).reverse();
      if (ult) {
        if (rt.error) return;
        const tem = new Set(st.d.turnos.map((t) => t.id));
        turnos = st.d.turnos.concat(turnos.filter((t) => !tem.has(t.id)));
      }
      st.d = { c: rc.data, turnos, acoes: ra.error && st.d ? st.d.acoes : (ra.data || []).reverse(), rapidas: rr || [], tpls: rtpl || [],
        envios: rme && !rme.error ? (rme.data || []).reverse() : (st.d ? st.d.envios || [] : []) };
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
      pedirUrls();
      if (o.oportunidade && st.opPosta) ajusta();
      if (st.foco && !matchMedia('(max-width: 900px)').matches) { ta.focus({ preventScroll: true }); ta.setSelectionRange(ta.value.length, ta.value.length); st.foco = false; }
    }

    const meuNome = () => ((NG.usuario || {}).nome || '').trim();
    function dono(c) {
      if (c.nao_contatar) return { v: 'parar', txt: 'Não contatar' };
      // 15/11: logo depois do "Devolver para a Mari" o espelho do Chatwoot ainda pode trazer o agente por alguns segundos —
      // a tela segue mostrando "Com a Mari" (o que o banco já gravou) por 30 s em vez de piscar de volta para "Com humano".
      if (st.devolvidoEm && Date.now() - st.devolvidoEm < 30000) return { v: 'mari', txt: 'Sem dono · Mari atende' };
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
      const nome = NG.nomeLegivel((c.dados && c.dados.nome) || o.nome || c.nome_contato || 'Cliente', c.telefone);   // 16/11: nome legível
      const link = NG.linkChatwoot(c.chatwoot_conversation_id);
      // 14/11 (Ricardo: "não precisamos das opções Ricardo, Time backoffice e Mari… um botão de interruptor entre os dois"):
      // o seletor de dono virou interruptor de 2 posições — Mari ⇄ Time backoffice. Conversa com uma pessoa (agente no
      // Chatwoot ou assumida) fica do lado do Time; ligar a Mari = devolver_mari, ligar o Time = atribuir ao time (tira o agente).
      const ladoTime = dn.v !== 'mari' && dn.v !== 'parar';
      const titSw = c.nao_contatar ? 'O cliente pediu para não ser contatado.'
        : ladoTime ? `Ligado: Time backoffice${dn.v === 'outro' || dn.v === 'eu' ? ` (com ${dn.v === 'eu' ? 'você' : dn.txt})` : ''} — a Mari está calada. Clique para devolver à Mari.`
        : 'Ligado: a Mari atende. Clique para passar ao time backoffice (a Mari cala).';
      const htmlSw = `<button type="button" class="cvp-sw ${ladoTime ? 'time' : 'mari'}" data-cv="dono-sw" role="switch" aria-checked="${ladoTime}" aria-label="Quem atende: ${ladoTime ? 'Time backoffice' : 'Mari'}" title="${esc(titSw)}"${c.nao_contatar || st.trocandoDono ? ' disabled' : ''}>
          <span class="cvp-sw-opc mari">Mari</span><span class="cvp-sw-trilho" aria-hidden="true"><span class="cvp-sw-bola"></span></span><span class="cvp-sw-opc time">Time backoffice</span></button>`;
      // Cliente com venda: "Este cliente tem venda em {etapa} — o próximo passo é {botão}. …" (sem venda: nada).
      const vj = st.venda;
      const passo = vj ? (vj.botao && vj.botao !== 'abrir' && NG.BOTAO_PASSO[vj.botao] ? NG.BOTAO_PASSO[vj.botao] : vj.o_que_fazer) : '';
      const htmlVenda = vj ? `Este cliente tem venda em <b>${esc(vj.etapa_nome || '—')}</b> — o próximo passo é <b>${esc(passo || 'abrir a ficha')}</b>. Faça pelo botão da ficha para a venda andar. <a href="#venda=${esc(vj.venda_id)}">Abrir ficha →</a>` : '';
      vendaEl.hidden = !vj || !!o.cheia;
      troca('venda', vendaEl, htmlVenda);
      // 10/11 (Ricardo: "organiza melhor esse cabeçalho, seguindo esses padrões" — os da ficha): linha 1 = ← Lista · nome ·
      // Chatwoot ↗; linha 2 = chips pequenos (status, dono, janela — os dois primeiros trocam pelo próprio chip); linha 3 =
      // etiquetas em chips finos com o "+ etiqueta" do mesmo tamanho.
      troca('cab', cab, `<div class="cvp-topo">${o.aoFechar ? `<button type="button" class="btn btn-sm" data-cv="fechar">${esc(o.rotuloFechar)}</button>` : ''}
        <b class="cvp-nome" title="${esc(nome)}">${esc(nome)}</b>
        ${link ? `<a class="cvp-cw" href="${esc(link)}" target="_blank" rel="noopener" title="Áudio e foto aparecem aqui na conversa. O Chatwoot fica para vídeo e documento — responda por aqui">Chatwoot ↗</a>` : ''}
        ${o.aoConcluir ? '<button type="button" class="btn btn-acc btn-sm" data-cv="concluir" title="Terminou com este cliente? Fecha o caso e abre o próximo da fila. Até apertar aqui, a conversa fica aberta.">✓ Concluir</button>' : ''}</div>
        <div class="cvp-chips">
        <span class="cvp-pill fixo" title="Só leitura (17/11, passo 6 — regra de ouro 4): quem abre e fecha a conversa é a situação do lead. Responder, Assumir, Devolver, Em espera e Saída fazem isso sozinhos.">${c.chatwoot_status === 'resolved' ? 'Resolvida' : 'Aberta'}</span>
        ${htmlSw}
        <span class="cvp-pill fixo${jn.aberta ? '' : ' warn'}">${esc(jn.txt)}</span></div>`);
      const etq = (c.chatwoot_etiquetas || []).filter(Boolean);
      // 17/11 (passo 6, Ricardo: "Deixe as etiquetas também só leitura" — regra de ouro 4): a etiqueta sai da situação do lead
      // (projetor da porta); aqui só se vê. Não contatar é o botão "Cliente pediu para parar"; Saída/Silenciar, os da ficha.
      troca('etq', etqEl, `<span class="cvp-rot">ETIQUETAS</span>${etq.length ? etq.map((x) => `<span class="cvp-tg" title="Só leitura: a etiqueta vem da situação do cliente">${esc(x)}</span>`).join('') : '<span class="cvp-tg vazia">nenhuma</span>'}`);
      if (o.movel) desenharMovel(c, dn, jn, nome);
      desenharMsgs();
      desenharPe(jn, dn, nome);
    }

    // ---------- celular (15/11): cabeçalho de WhatsApp, contexto e Devolver para a Mari ----------
    const COR_AV = ['#22c55e', '#6FA8FF', '#F2B84B', '#C79BFF', '#FF8A65', '#4DD0E1'];
    function desenharMovel(c, dn, jn, nome) {
      const ladoTime = dn.v !== 'mari' && dn.v !== 'parar';
      const ini = (String(nome).trim().split(/\s+/).filter(Boolean).slice(0, 2).map((p) => p[0]).join('') || '?').toUpperCase();
      const cor = COR_AV[[...String(c.id)].reduce((a, ch) => a + ch.charCodeAt(0), 0) % COR_AV.length];
      const sub = c.nao_contatar ? '<small class="parar">Não contatar</small>'
        : ladoTime ? `<small class="time">Com humano · ${esc(dn.v === 'eu' ? 'você' : dn.v === 'outro' ? dn.txt : 'time backoffice')}</small>`
        : `<small class="mari${st.devolvidoEm && Date.now() - st.devolvidoEm < 4000 ? ' acabou' : ''}">Com a Mari</small>`;
      const armadoCab = st.armado === 'cab';
      const tel = NG.soDigitos(c.telefone || '');
      const ficha = c.venda_id ? `#venda=${esc(c.venda_id)}` : `#conversa=${esc(c.id)}`;
      troca('mvcab', mvCab, `<button type="button" class="cvp-mv-voltar" data-cv="fechar" aria-label="Voltar para a lista">‹</button>
        <span class="cvp-mv-av" style="--av:${cor}" aria-hidden="true">${esc(ini)}</span>
        <span class="cvp-mv-id"><b title="${esc(nome)}">${esc(nome)}</b>${sub}</span>
        ${ladoTime && !c.nao_contatar ? `<button type="button" class="cvp-mv-dev${armadoCab ? ' armado' : ''}" data-cv="devolver" data-onde="cab" aria-label="${armadoCab ? 'Toque de novo para devolver a conversa à Mari' : 'Devolver para a Mari'}"${st.trocandoDono ? ' disabled' : ''}>${armadoCab ? 'Confirmar?' : '↩ Devolver'}</button>` : ''}
        ${tel ? `<a class="cvp-mv-ico" href="tel:+${esc(tel)}" aria-label="Ligar para ${esc(NG.primeiroNome(nome))}">📞</a>` : ''}
        <a class="cvp-mv-ico" href="${ficha}" aria-label="Abrir a ficha (status, etiquetas, saída)">⋮</a>`);
      mvCab.hidden = false;
      const cx = o.contexto || {};
      const partes = [cx.cidade || c.cidade, cx.plano, cx.vale ? `vale <b>${esc(cx.vale)}</b>` : ''].filter(Boolean)
        .map((x) => (String(x).includes('<b>') ? x : esc(x)));
      partes.push(`<span class="${jn.aberta ? '' : 'fechada'}">${esc(jn.txt.replace('Janela 24 h · ', 'janela ').replace('Janela 24 h fechada', 'janela fechada'))}</span>`);
      troca('ctx', ctxEl, partes.join('<i>·</i>'));
      ctxEl.hidden = false;
      const armadoFim = st.armado === 'fim';
      devEl.hidden = !ladoTime || !!c.nao_contatar;
      troca('dev', devEl, ladoTime && !c.nao_contatar ? `<span>${dn.v === 'eu' ? 'Você está com este cliente.' : 'Conversa com o time.'} A Mari está calada e os lembretes, parados.</span>
        <button type="button" class="btn btn-sm cvp-mv-dev-fim${armadoFim ? ' armado' : ''}" data-cv="devolver" data-onde="fim"${st.trocandoDono ? ' disabled' : ''}>${armadoFim ? 'Toque de novo para devolver' : '↩ Devolver para a Mari'}</button>` : '');
    }
    function devolver(onde) {
      if (st.trocandoDono) return;
      if (st.armado !== onde) {   // 1º toque: arma por 4 s
        st.armado = onde;
        clearTimeout(st.tArmado);
        st.tArmado = setTimeout(() => { st.armado = null; desenhar(); }, 4000);
        desenhar();
        return;
      }
      clearTimeout(st.tArmado);
      st.armado = null;
      st.trocandoDono = true;
      desenhar();
      NG.sb.rpc('backoffice_conversa', { p_conversa: o.conversaId, p_acao: 'atribuir', p_valor: 'mari' }).then(({ data, error }) => {
        st.trocandoDono = false;
        if (error) { NG.toast(NG.msgErro(error), 'bad'); desenhar(); return; }
        st.devolvidoEm = Date.now();
        // retorno visual na hora ("Com humano" → "Com a Mari"); o carregar confirma pelo banco
        if (st.d) { st.d.c.chatwoot_agente = null; st.d.c.humano_atribuido = false; st.d.c.chatwoot_time = null; }
        desenhar();
        NG.toast((data && data.resumo) || 'Com a Mari de novo — lembretes e cadência retomados', 'ok');
        if (o.aoMudar) o.aoMudar(data);
        carregar();
        setTimeout(() => { carregar(); }, 3000);
        setTimeout(() => desenhar(), 4100);
      });
    }

    function itensMsgs() {
      const d = st.d;
      const its = [];
      const turnosOut = d.turnos.filter((t) => t.papel === 'humano' || t.papel === 'mari');
      // 19/11 (caso Arilton): cutucada que saiu como voz/imagem também fica gravada como turno de texto — o cliente recebeu SÓ a
      // mídia; o turno não vira um 2º balão (a mídia já mostra o texto/transcrição).
      const midiaCad = (d.envios || []).filter((e) => e.origem === 'cadencia' && e.passo)
        .map((e) => ({ passo: e.passo, em: new Date(e.created_at).getTime() }));
      const virouMidia = (t) => {
        const p = t.papel === 'mari' && t.tags && t.tags.cadencia;
        if (!p) return false;
        const em = new Date(t.created_at).getTime();
        return midiaCad.some((e) => e.passo === p && Math.abs(e.em - em) < 120000);
      };
      const comMidia = (t) => Array.isArray(t.midia) && t.midia.length > 0;
      d.turnos.forEach((t) => {
        const txt = textoTurno(t.texto);
        if ((!txt && !comMidia(t)) || virouMidia(t)) return;
        if (t.papel === 'sistema') { its.push({ em: t.created_at, tipo: 'sis', txt: txt.replace(/^\[|\]$/g, '') }); return; }
        its.push({ em: t.created_at, tipo: t.papel === 'lead' ? 'cli' : t.papel === 'mari' ? 'mari' : 'hum', txt, midia: comMidia(t) ? t.midia : null,
          quem: t.papel === 'mari' ? (t.tags && t.tags.backoffice === 'sopro' ? 'Mari · soprada pelo time' : t.tags && t.tags.backoffice ? 'Mari · NIOGEN' : 'Mari') : t.papel === 'humano' ? 'Time' : '', tick: t.papel !== 'lead' ? '✓' : '' });
      });
      (d.envios || []).forEach((e) => {
        const passo = e.passo ? ` · ${e.passo}` : '';
        its.push({ em: e.created_at, tipo: 'mari', txt: e.tipo === 'imagem' ? (e.texto || '') : '', tick: '✓',
          quem: e.tipo === 'voz' ? `Mari · 🔊 áudio${passo}` : `Mari · 🖼️ imagem${passo}`,
          midia: e.tipo === 'voz' ? [{ tipo: 'audio', caminho: e.caminho, transcricao: e.texto }] : [{ tipo: 'imagem', url: e.imagem_url }] });
      });
      d.acoes.forEach((a) => {
        const txt = (a.payload || {}).content || '';
        if (a.tipo === 'nota') {
          its.push({ em: a.criada_em, tipo: 'nota', txt, quem: 'Nota privada', tick: a.status === 'feita' ? '✓' : a.status === 'erro' ? '⚠' : '🕓',
            erro: a.status === 'erro' ? (a.erro || 'não foi ao Chatwoot') : '' });
          return;
        }
        // 0333: mídia do time — feita vira turno (com a mídia); até lá, o balão da ação com o nome do arquivo
        if (a.tipo === 'midia') {
          if (a.status === 'feita' && d.turnos.some((t) => t.tags && Number(t.tags.acao_id) === a.id)) return;
          if (a.status === 'cancelada') return;
          const pm = a.payload || {};
          const falhouM = ['bloqueada', 'erro'].includes(a.status);
          its.push({ em: a.criada_em, tipo: 'hum', txt: pm.content || '', quem: 'Você',
            midia: [{ tipo: pm.tipo_midia || 'arquivo', caminho: pm.caminho, nome: pm.nome, mime: pm.mime, do_time: true }],
            tick: a.status === 'feita' ? '✓' : falhouM ? '⚠' : '🕓', erro: falhouM ? (a.erro || 'não saiu') : '' });
          return;
        }
        // Já virou fala (o motor grava a do time; o resultado grava a da Mari)? Então não repete.
        if (a.status === 'feita' && turnosOut.some((t) => normal(t.texto) === normal(txt) && new Date(t.created_at) >= new Date(new Date(a.criada_em).getTime() - 15000))) return;
        if (a.status === 'cancelada') return;
        const falhou = ['bloqueada', 'erro'].includes(a.status);
        const sop = a.momento === 'sopro';
        const ir = (((a.payload || {}).content_attributes) || {}).in_reply_to;   // 0334: resposta citando
        const citaTxt = ir && st.msgCw && st.msgCw.get(Number(ir)) ? `↩ ${String(st.msgCw.get(Number(ir)).texto || '📎 mídia').slice(0, 140)}` : ir ? '↩ mensagem do cliente' : '';
        its.push({ em: a.criada_em, tipo: sop ? 'mari' : 'hum', txt, cita: citaTxt, quem: (a.payload || {}).como === 'humano' ? 'Você' : sop ? 'Mari · soprada pelo time' : 'NIOGEN',
          tick: a.status === 'feita' ? '✓' : falhou ? '⚠' : '🕓', erro: falhou ? (a.erro || 'não saiu') : '', reenviar: falhou && (a.payload || {}).como === 'humano' ? txt : '' });
      });
      st.locais.forEach((l) => its.push({ em: l.em, tipo: l.nota ? 'nota' : l.sopro ? 'mari' : 'hum', txt: l.texto, quem: l.nota ? 'Nota privada' : l.sopro ? 'Mari · soprada pelo time' : 'Você',
        midia: l.midiaLocal ? [l.midiaLocal] : null, cita: l.cita ? `↩ ${l.cita.txt}` : '',
        tick: l.estado === 'erro' ? '⚠' : '🕓', erro: l.estado === 'erro' ? l.erro : '', reenviar: l.estado === 'erro' ? l.texto : '', local: l.id }));
      its.sort((a, b) => new Date(a.em) - new Date(b.em));
      casarChatwoot(its);
      return its;
    }
    function casarChatwoot(its) {
      if (!st.msgCw || !st.msgCw.size) return;
      const lista = [...st.msgCw.values()];
      const usados = new Set();
      const nt = (t) => normal(String(t || '')).slice(0, 120);
      its.forEach((x) => {
        if (!['cli', 'mari', 'hum'].includes(x.tipo) || x.local) return;
        const dir = x.tipo === 'cli' ? 'in' : 'out';
        const em = new Date(x.em).getTime();
        const alvo = nt(x.txt);
        let melhor = null, dist = 6 * 60000;
        lista.forEach((m) => {
          if (m.direcao !== dir || usados.has(m.cw_msg_id)) return;
          const d = Math.abs(new Date(m.criado_em).getTime() - em);
          if (d > dist) return;
          const mt = nt(m.texto);
          if (alvo ? !(mt && (mt === alvo || alvo.startsWith(mt) || mt.startsWith(alvo))) : !!mt) return;
          melhor = m; dist = d;
        });
        if (!melhor) return;
        usados.add(melhor.cw_msg_id);
        x.cw = melhor.cw_msg_id;
        if (dir === 'out' && melhor.status) x.tick = melhor.status === 'lida' ? '✓✓l' : melhor.status === 'entregue' ? '✓✓' : melhor.status === 'falhou' ? '⚠' : '✓';
      });
    }
    // ---------- mídia do cliente (0145): player + transcrição, miniatura da foto ----------
    // URLs assinadas de 1 h, num lote só por rodada; só pede o que falta (ou vence em < 5 min). Falhou → não repete por 10 min.
    let pedindoUrls = false;
    async function pedirUrls() {
      if (pedindoUrls || !st.d) return;
      const falta = new Set();
      [...st.d.turnos, ...(st.d.envios || []).filter((e) => e.tipo === 'voz').map((e) => ({ midia: [{ tipo: 'audio', caminho: e.caminho }] })),
        ...(st.d.acoes || []).filter((x) => x.tipo === 'midia' && x.payload && x.payload.caminho).map((x) => ({ midia: [{ tipo: x.payload.tipo_midia, caminho: x.payload.caminho }] }))]
        .forEach((t) => (Array.isArray(t.midia) ? t.midia : []).forEach((m) => {
        if (!m || !m.caminho || !['audio', 'imagem', 'arquivo', 'figurinha'].includes(m.tipo)) return;
        const u = urlsMidia.get(m.caminho);
        if (!u || u.ate < Date.now() + 5 * 60000) falta.add(m.caminho);
      }));
      if (!falta.size) return;
      pedindoUrls = true;
      try {
        const lista = [...falta];
        const { data, error } = await NG.sb.storage.from('midia_conversas').createSignedUrls(lista, 3600);
        const ok = new Set();
        if (!error) (data || []).forEach((r) => { if (r && r.signedUrl && r.path) { urlsMidia.set(r.path, { url: r.signedUrl, ate: Date.now() + 55 * 60000 }); ok.add(r.path); } });
        lista.filter((c) => !ok.has(c)).forEach((c) => urlsMidia.set(c, { url: null, ate: Date.now() + 10 * 60000 }));
      } finally { pedindoUrls = false; }
      if (st.vivo) desenharMsgs();
    }
    function htmlMidia(midia, txt) {
      let resto = String(txt || '');
      const partes = [];
      midia.forEach((m) => {
        if (m && m.tipo === 'imagem' && m.url && !m.caminho) {   // cartão do plano (público) que a Mari mandou
          partes.push(`<button type="button" class="cvp-foto" data-cv="foto" data-url="${esc(m.url)}" aria-label="Abrir a imagem em tamanho grande"><img src="${esc(m.url)}" alt="Imagem enviada pela Mari" loading="lazy"></button>`);
          return;
        }
        // 20/11 (prompt "conversa sem Chatwoot"): prévia local (ainda subindo), documento, figurinha e localização
        if (m && m.local) {
          if (m.tipo === 'imagem') partes.push(`<span class="cvp-foto"><img src="${esc(m.local)}" alt=""></span>`);
          else if (m.tipo === 'audio') partes.push(`<div class="cvp-audio"><audio controls preload="metadata" src="${esc(m.local)}"></audio></div>`);
          else partes.push(`<span class="cvp-doc">📄 <b>${esc(m.nome || 'documento')}</b></span>`);
          return;
        }
        if (m && m.tipo === 'local' && (m.lat != null || m.endereco || m.nome)) {
          const q = m.lat != null && m.lng != null ? `${m.lat},${m.lng}` : (m.endereco || m.nome);
          partes.push(`<a class="cvp-local" href="https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(q)}" target="_blank" rel="noopener">📍 <span><b>${esc(m.nome || 'Localização')}</b>${m.endereco ? `<small>${esc(m.endereco)}</small>` : ''}<small>abrir no mapa ↗</small></span></a>`);
          resto = resto.replace('[Localização enviada pelo cliente]', '');
          return;
        }
        if (m && m.caminho && ['arquivo', 'figurinha'].includes(m.tipo)) {
          const u0 = urlsMidia.get(m.caminho);
          const url0 = u0 && u0.url ? u0.url : null;
          if (m.tipo === 'figurinha') partes.push(url0 ? `<img class="cvp-fig" src="${esc(url0)}" alt="figurinha">` : '<span class="cvp-carrega">🙂 figurinha</span>');
          else partes.push(url0 ? `<a class="cvp-doc" href="${esc(url0)}" target="_blank" rel="noopener">📄 <b>${esc(m.nome || 'documento')}</b><small>abrir ↗</small></a>` : `<span class="cvp-doc">📄 <b>${esc(m.nome || 'documento')}</b><small>carregando…</small></span>`);
          resto = resto.replace('📎 figurinha', '');
          return;
        }
        if (!m || !m.caminho || !['audio', 'imagem'].includes(m.tipo)) return;
        const u = urlsMidia.get(m.caminho);
        const url = u && u.url ? u.url : null;
        const falhou = u && !u.url;
        if (m.tipo === 'audio') {
          if (m.transcricao) resto = resto.replace(`🎤 (áudio) ${m.transcricao}`, '');
          resto = resto.replace('📎 áudio do cliente · ouvir no Chatwoot', '');
          const player = url ? `<audio controls preload="metadata" src="${esc(url)}"></audio>`
            : `<span class="cvp-carrega">${falhou ? '🎤 áudio indisponível · ouvir no Chatwoot' : '🎤 carregando o áudio…'}</span>`;
          const tr = m.transcricao ? `<details class="cvp-transc" open><summary>Transcrição</summary><span>${esc(m.transcricao)}</span></details>`
            : '<small class="cvp-transc-sem">sem transcrição</small>';
          partes.push(`<div class="cvp-audio">${player}${tr}</div>`);
        } else {
          resto = resto.replace('📎 foto do cliente · ver no Chatwoot', '');
          partes.push(url ? `<button type="button" class="cvp-foto" data-cv="foto" data-url="${esc(url)}" aria-label="Abrir a foto em tamanho grande"><img src="${esc(url)}" alt="Foto do cliente" loading="lazy"></button>`
            : `<span class="cvp-carrega">${falhou ? '📷 foto indisponível · ver no Chatwoot' : '📷 carregando a foto…'}</span>`);
        }
      });
      if (!partes.length) return null;
      return { html: partes.join(''), txt: resto.replace(/\n{2,}/g, '\n').trim() };
    }
    function abrirFoto(url) {
      const ov = document.createElement('div');
      ov.className = 'cvp-foto-grande';
      ov.setAttribute('role', 'dialog');
      ov.setAttribute('aria-label', 'Foto do cliente');
      ov.innerHTML = `<img src="${esc(url)}" alt="Foto do cliente"><button type="button" class="btn btn-sm" aria-label="Fechar">Fechar ✕</button>`;
      const fechar = () => { ov.remove(); document.removeEventListener('keydown', esc1, true); };
      const esc1 = (ev) => { if (ev.key === 'Escape') { ev.stopPropagation(); fechar(); } };
      ov.addEventListener('click', fechar);
      document.addEventListener('keydown', esc1, true);
      document.body.appendChild(ov);
    }

    // 20/11 (0331): "veio do anúncio" — miniatura (clica e abre a arte inteira), nome, 1ª linha do texto e a campanha.
    const TIQUE_TIT = { '✓': 'enviada', '✓✓': 'entregue no celular do cliente', '✓✓l': 'lida pelo cliente', '🕓': 'enviando', '⚠': 'não saiu' };
    function anuncioHtml() {
      const a = st.anuncio;
      if (!a) return '';
      const arte = a.arte_miniatura || a.arte_url;
      const linha1 = String(a.anuncio_texto || a.titulo || '').split(String.fromCharCode(10)).map((x) => x.trim()).find(Boolean) || '';
      return `<div class="cvp-anuncio">${arte ? `<a href="${esc(a.arte_url || arte)}" target="_blank" rel="noopener" title="Abrir a arte do anúncio"><img src="${esc(arte)}" alt="" loading="lazy" referrerpolicy="no-referrer"></a>` : '<span class="cvp-an-sem">📣</span>'}
        <div class="cvp-an-t"><small>Veio do anúncio${a.referral_em ? ` · ${esc(NG.fmtDataHora(a.referral_em))}` : ''}</small><b>${esc(a.ad_nome || a.titulo || 'anúncio da Meta')}</b>
        ${linha1 ? `<span title="${esc(a.anuncio_texto || '')}">${esc(linha1.slice(0, 140))}</span>` : ''}${a.campanha_nome ? `<em>${esc(a.campanha_nome)}</em>` : ''}</div></div>`;
    }
    // ---------- 20/11: gravar na ficha o que o cliente mandou (só quando quem montou passou o.gravar: a ficha, para admin/backoffice) ----------
    // o.gravar = { atual(): {campo: valor gravado}, salvar(campo, valor): Promise<bool>, campos: [...] }
    st.gravados = new Set();
    function chipsGravar(txt) {
      if (!o.gravar) return '';
      const atual = o.gravar.atual() || {};
      const cs = capturas(txt).filter((c) => (o.gravar.campos || []).includes(c.campo));
      if (!cs.length) return '';
      return `<span class="cvp-grav">${cs.map((c) => {
        const ja = normCampo(c.campo, atual[c.campo]) === normCampo(c.campo, c.valor) || st.gravados.has(`${c.campo}:${c.valor}`);
        return ja ? `<span class="cvp-grav-ok" title="Já está na ficha">✓ ${esc(CAMPO_ROT[c.campo])} na ficha</span>`
          : `<button type="button" class="cvp-grav-b" data-cv="gravar" data-campo="${c.campo}" data-valor="${esc(c.valor)}" title="${atual[c.campo] ? `Na ficha hoje: ${esc(atual[c.campo])} — troca por este` : 'Grava na ficha do cliente'}">＋ Gravar ${esc(CAMPO_ROT[c.campo])} ${esc(c.mostra)}</button>`;
      }).join('')}</span>`;
    }
    async function gravarCampo(campo, valor, b) {
      if (!o.gravar || !valor) return;
      const atual = (o.gravar.atual() || {})[campo];
      if (atual && normCampo(campo, atual) !== normCampo(campo, valor)
          && !window.confirm(`${CAMPO_ROT[campo]} na ficha hoje: ${atual}\nTrocar por: ${valor}?`)) return;
      if (b) b.disabled = true;
      const ok = await o.gravar.salvar(campo, valor);
      if (ok) { st.gravados.add(`${campo}:${valor}`); st.sig.msgs = null; desenharMsgs(); } else if (b && b.isConnected) b.disabled = false;
    }
    // Selecionar um trecho numa fala do cliente → menu "Gravar como…"
    const selMenu = document.createElement('div');
    selMenu.className = 'cvp-selmenu';
    selMenu.hidden = true;
    el.appendChild(selMenu);
    let selTxt = '';
    function selAbrir() {
      if (!o.gravar) return;
      const sel = window.getSelection();
      const t = sel && !sel.isCollapsed ? String(sel).replace(/\s+/g, ' ').trim() : '';
      const no = sel && sel.anchorNode ? (sel.anchorNode.nodeType === 1 ? sel.anchorNode : sel.anchorNode.parentElement) : null;
      if (!t || t.length > 160 || !no || !no.closest('.cvp-b.cli')) { selMenu.hidden = true; return; }
      selTxt = t;
      const r = sel.getRangeAt(0).getBoundingClientRect();

      selMenu.innerHTML = `<small>Gravar “${esc(t.length > 28 ? `${t.slice(0, 28)}…` : t)}” como</small>${(o.gravar.campos || []).map((c) => `<button type="button" data-cv="gravar-sel" data-campo="${c}">${esc(CAMPO_ROT[c])}</button>`).join('')}`;
      selMenu.hidden = false;
      const w = selMenu.offsetWidth;
      selMenu.style.left = `${Math.max(6, Math.min(window.innerWidth - w - 6, r.left + r.width / 2 - w / 2))}px`;
      selMenu.style.top = `${Math.min(window.innerHeight - selMenu.offsetHeight - 6, r.bottom + 6)}px`;
    }
    msgs.addEventListener('mouseup', () => setTimeout(selAbrir, 0));
    msgs.addEventListener('touchend', () => setTimeout(selAbrir, 300));
    document.addEventListener('mousedown', (ev) => { if (!selMenu.hidden && !selMenu.contains(ev.target)) selMenu.hidden = true; });
    function desenharMsgs() {
      const its = itensMsgs();
      let dia = '';
      let html = its.map((x) => {
        const sep = diaRot(x.em) !== dia ? `<div class="cvp-dia"><span>${esc((dia = diaRot(x.em)))}</span></div>` : '';
        if (x.tipo === 'sis') return `${sep}<div class="cvp-b sis">${esc(x.txt)} · ${esc(NG.fmtHora(x.em))}</div>`;
        const md = x.midia ? htmlMidia(x.midia, x.txt) : null;
        const corpo = md ? `${md.html}${md.txt ? `<span class="cvp-t">${fmtWa(md.txt)}</span>` : ''}` : `<span class="cvp-t">${fmtWa(x.txt)}</span>`;
        return `${sep}<div class="cvp-b ${x.tipo}${md ? ' com-midia' : ''}${x.erro ? ' falhou' : ''}${x.tick === '🕓' ? ' pend' : ''}">${x.quem ? `<small class="cvp-quem">${esc(x.quem)}</small>` : ''}${corpo}
          <span class="cvp-h">${esc(NG.fmtHora(x.em))}${x.tick ? ` <i class="cvp-tick${x.tick === '✓✓l' ? ' lida' : ''}" title="${TIQUE_TIT[x.tick] || 'não saiu'}">${x.tick === '✓✓l' ? '✓✓' : x.tick}</i>` : ''}</span>
          ${x.tipo === 'cli' && x.cw && podeSugerir ? `<button type="button" class="cvp-citar" data-cv="citar" data-cw="${x.cw}" data-txt="${esc(String(x.txt || '📎 mídia').slice(0, 140))}" title="Responder citando esta mensagem" aria-label="Responder citando">↩</button>` : ''}
          ${x.tipo === 'cli' ? chipsGravar(md ? md.txt + ' ' + (x.midia || []).map((m) => m && m.transcricao || '').join(' ') : x.txt) : ''}
          ${x.cita ? `<span class="cvp-cita-no">${esc(x.cita)}</span>` : ''}
          ${x.erro ? `<span class="cvp-erro">${esc(x.erro)}${x.reenviar ? ` · <button type="button" class="link" data-cv="reenviar" data-txt="${esc(x.reenviar)}"${x.local ? ` data-local="${esc(x.local)}"` : ''}>Reenviar</button>` : ''}</span>` : ''}</div>`;
      }).join('') || '<div class="cvp-b sis">Sem mensagens ainda</div>';
      html = anuncioHtml() + html;
      if (st.sig.msgs === html) return;
      // Áudio tocando: não redesenha (cortaria o áudio). Redesenha quando ele pausar ou acabar.
      if ([...msgs.querySelectorAll('audio')].some((a) => !a.paused && !a.ended)) { st.adiar = true; return; }
      st.adiar = false;
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
      secao.classList.toggle('sopro', st.sopro);
      const modo = st.nota ? 'nota' : st.sopro ? 'sopro' : 'resp';
      el.querySelectorAll('[data-cv="modo"]').forEach((b) => b.classList.toggle('on', b.dataset.m === modo));
      const usaTpl = !st.nota && !st.sopro && !jn.aberta;
      // 0299: o banco recusa o sopro com dono, fora da janela e em Não contatar — a tela desliga antes e diz por quê (regra de ouro 3)
      const semSopro = !st.sopro ? '' : st.d.c.nao_contatar ? 'O cliente pediu para não ser contatado.'
        : dn.v !== 'mari' ? 'A conversa está com o time: responda direto (soprar é para quando a Mari atende).'
        : !jn.aberta ? 'Janela de 24 h fechada: a Mari não pode falar texto livre. Use Responder com um template.' : '';
      ta.placeholder = st.nota ? 'Escrever nota privada (só o time vê)…' : st.sopro ? (semSopro || `🌬️ Soprar: ${NG.primeiroNome(nome)} recebe como fala da Mari…`) : st.tpl ? 'Template escolhido — sai o texto aprovado' : usaTpl ? 'Janela de 24 h fechada: escolha um template em Respostas rápidas' : `Mensagem para ${NG.primeiroNome(nome)}`;
      ta.readOnly = !!st.tpl || (usaTpl && !st.tpl) || !!semSopro;
      emoBt.disabled = ta.readOnly;
      if (ta.readOnly && !emoEl.hidden) emoFechar();
      btEnviar.textContent = st.nota ? 'Salvar nota' : st.sopro ? 'Soprar' : 'Enviar';
      btEnviar.disabled = (!!st.d.c.nao_contatar && !st.nota) || !!semSopro;
      const opRap = `<option value="">Respostas rápidas…</option>${usaTpl ? '' : st.d.rapidas.map((r, i) => `<option value="r:${i}">${esc(r.rot)}</option>`).join('')}
        ${!st.nota && !st.sopro && st.d.tpls.length ? `<optgroup label="Templates aprovados">${st.d.tpls.map((t) => `<option value="t:${esc(t.nome)}">${esc(t.nome.replace(/^nio_/, '').replace(/_/g, ' '))}</option>`).join('')}</optgroup>` : ''}`;
      if (st.sig.rap !== opRap && document.activeElement !== selRap) { st.sig.rap = opRap; selRap.innerHTML = opRap; }
      const op = o.oportunidade && !st.nota && !st.sopro;
      const aj = st.d.c.nao_contatar ? 'O cliente pediu para não ser contatado.'
        : st.nota ? 'Nota privada: só o time vê.'
        : st.sopro ? (semSopro || '🌬️ Soprar: sai como fala da Mari · ela segue dona e com o contexto · ninguém assume')
        : op ? `🔥 Oportunidade · ${o.oportunidade.assumir ? 'você assume a conversa (a Mari cala)' : 'a Mari segue a conversa depois (sem dono)'} · nunca desconto nem data de instalação`
        : st.tpl ? 'Template escolhido · Esc cancela'
        : usaTpl ? 'Janela de 24 h fechada (regra do WhatsApp): só template aprovado.'
        : dn.v === 'eu' ? 'Você é o dono · a Mari está calada.' : 'Enviar assume a conversa (a Mari cala).';
      ajudaEl.textContent = `${aj} · Enter envia · Shift+Enter pula linha`;
      // ✨ Sugerir resposta: some na nota privada; desabilitado (com o motivo) em não contatar e janela fechada (regra de ouro 3)
      sugBt.hidden = !podeSugerir || st.nota;
      if (podeSugerir) {
        const motivo = st.d.c.nao_contatar ? 'O cliente pediu para não ser contatado.'
          : usaTpl ? 'Janela de 24 h fechada: só template aprovado (Respostas rápidas › Templates).' : '';
        sugBt.disabled = !!motivo || !!(st.sug && st.sug.carregando);
        sugBt.title = motivo || 'Lê a conversa e propõe 2 respostas para você conferir, editar e enviar. A IA nunca envia sozinha.';
        if (st.nota && st.sug && !st.sug.carregando) sugFechar(true);
        desenharSug();
      }
      // 12/11 (Ricardo): na tela cheia, ícone ao lado da caixa — robô = a Mari atende · pessoa = nós (o time).
      if (o.cheia) {
        const mari = dn.v === 'mari';
        const html = mari
          ? '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="8" width="14" height="11" rx="3"/><path d="M12 4v4M9.5 13h.01M14.5 13h.01M9.5 16.5h5"/></svg>'
          : '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></svg>';
        const tit = mari ? 'A Mari atende esta conversa (sem dono). Enviar assume a conversa: a Mari cala.' : `Conversa com o time (${dn.txt}) — a Mari está calada.`;
        if (st.sig.quem !== html + tit) { st.sig.quem = html + tit; quemEl.innerHTML = html; quemEl.title = tit; quemEl.setAttribute('aria-label', tit); }
        quemEl.className = `cvp-quem-ico ${mari ? 'mari' : 'time'}`;
        quemEl.hidden = false;
      }
    }

    // ---------- enviar (aparece na hora; a caixa esvazia e o cursor fica) ----------
    let nLocal = 0;
    // 20/11 (prompt "conversa sem Chatwoot", item 5 — o WhatsApp oficial não apaga mensagem enviada): texto do time com valor ou data
    // pede uma conferida antes de sair (uma linha, sem travar). Errou? Responda citando: "me corrigindo: …".
    const temValorOuData = (t) => /R\$\s*\d|\b\d{1,3}(?:[.,]\d{2})\b|\b\d{1,2}\/\d{1,2}(?:\/\d{2,4})?\b|\b\d{1,2}\s*(?:h|horas?)\b|(?:^|[^a-zà-ú])(?:segunda|terça|terca|quarta|quinta|sexta|sábado|sabado|domingo|amanhã|amanha)(?![a-zà-ú])/i.test(t);
    function enviar() {
      if (!st.d) return;
      if (st.anexo) { enviarMidia(); return; }
      const txt = ta.value.trim();
      if (txt && !st.nota && !st.tpl && temValorOuData(txt) && !window.confirm(`Conferir antes de enviar: esta mensagem tem valor ou data.\n\n${txt.slice(0, 300)}\n\nO WhatsApp não deixa apagar depois. Enviar assim?`)) { ta.focus(); return; }
      if (!st.tpl && !txt) { ta.focus(); return; }
      const item = { id: `l${++nLocal}`, texto: st.tpl ? txt || `[template ${st.tpl}]` : txt, nota: st.nota, sopro: st.sopro && !st.nota, tpl: st.nota || st.sopro ? null : st.tpl, em: new Date().toISOString(), estado: 'enviando',
        op: !st.nota && !st.sopro && o.oportunidade ? o.oportunidade : null };
      if (item.op) o.oportunidade = null;   // só a 1ª mensagem é a da oportunidade
      // ✨ a mensagem saiu de uma sugestão: amarra o envio a ela (medição: % que saiu de sugestão e quanto foi editada)
      if (st.sug && st.sug.escolhida && !item.nota && !item.tpl) { item.sug = { id: st.sug.id, escolhida: st.sug.escolhida }; sugFechar(false); }
      if (st.cita && !item.nota && !item.sopro && !item.tpl && !item.op) { item.cita = st.cita; st.cita = null; citaDesenhar(); }
      st.locais.push(item);
      ta.value = '';
      st.tpl = null;
      ajusta();
      ta.focus();
      st.descer = true;
      desenhar();
      st.fila = st.fila.then(() => enviarUm(item));
    }
    // ---------- 20/11: foto, documento e áudio do time (0333) — sobe no bucket (bo/…) e vai pela fila, como a resposta escrita ----------
    const LIM_ARQ = 16 * 1024 * 1024;
    const EXT_MIME = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'application/pdf': 'pdf', 'audio/ogg': 'ogg', 'audio/mp4': 'm4a',
      'application/msword': 'doc', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx', 'application/vnd.ms-excel': 'xls',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx', 'text/plain': 'txt' };
    const podeMidia = () => podeSugerir && !st.nota && !st.sopro;
    function anexoDesenhar() {
      const a = st.anexo, g = st.grav;
      anexoEl.hidden = !a && !g;
      if (g) {
        const seg = Math.floor((Date.now() - g.t0) / 1000);
        anexoEl.innerHTML = `<div class="cvp-grav"><span class="cvp-grav-ponto"></span><b>Gravando ${Math.floor(seg / 60)}:${String(seg % 60).padStart(2, '0')}</b><span class="cvp-sp"></span>
          <button type="button" class="btn btn-sm" data-cv="grav-x">Descartar</button><button type="button" class="btn btn-sm btn-acc" data-cv="grav-parar">■ Parar</button></div>`;
      } else if (a) {
        const prev = a.tipo === 'imagem' ? `<img src="${esc(a.url)}" alt="">` : a.tipo === 'audio' ? `<audio controls src="${esc(a.url)}"></audio>` : `<span class="cvp-doc">📄 <b>${esc(a.nome)}</b><small>${Math.ceil(a.file.size / 1024)} KB</small></span>`;
        anexoEl.innerHTML = `<div class="cvp-anx">${prev}<span class="cvp-anx-t">${a.tipo === 'audio' ? 'Áudio pronto: ouça e envie' : 'Escreva uma legenda (opcional) e envie'}</span><span class="cvp-sp"></span><button type="button" class="btn btn-sm" data-cv="anexo-x" aria-label="Tirar o anexo">✕</button></div>`;
      } else anexoEl.innerHTML = '';
      ajusta();
    }
    function anexoLimpar() { if (st.anexo && st.anexo.url) URL.revokeObjectURL(st.anexo.url); st.anexo = null; anexoDesenhar(); }
    function escolherArquivo(tipo, f) {
      if (!f) return;
      if (!podeMidia()) { NG.toast('Foto, documento e áudio só no modo Responder.', 'bad'); return; }
      if (f.size > LIM_ARQ) { NG.toast('Arquivo maior que 16 MB: o WhatsApp não aceita.', 'bad'); return; }
      const mime = f.type || (/\.pdf$/i.test(f.name) ? 'application/pdf' : '');
      if (!EXT_MIME[mime]) { NG.toast('Tipo de arquivo que o WhatsApp não aceita por aqui (use foto JPG/PNG, PDF, Word, Excel ou texto).', 'bad'); return; }
      anexoLimpar();
      st.anexo = { file: f, tipo, mime, nome: f.name || `arquivo.${EXT_MIME[mime]}`, url: URL.createObjectURL(f) };
      anexoDesenhar();
      ta.focus();
    }
    el.querySelectorAll('input[data-arq]').forEach((inp) => inp.addEventListener('change', () => { escolherArquivo(inp.dataset.arq, inp.files && inp.files[0]); inp.value = ''; }));
    // Gravar: OGG/Opus (Firefox) ou MP4/AAC (Chrome) — formatos que o WhatsApp aceita. WebM não vai (o WhatsApp recusa).
    const MIME_GRAV = () => (window.MediaRecorder ? ['audio/ogg;codecs=opus', 'audio/mp4;codecs=mp4a.40.2', 'audio/mp4'].find((m) => MediaRecorder.isTypeSupported(m)) : null);
    async function gravarIniciar() {
      if (!podeMidia()) { NG.toast('Áudio só no modo Responder.', 'bad'); return; }
      const mime = MIME_GRAV();
      if (!mime) { NG.toast('Este navegador grava num formato que o WhatsApp não aceita. Atualize o Chrome (ou use o Firefox).', 'bad'); return; }
      let stream;
      try { stream = await navigator.mediaDevices.getUserMedia({ audio: true }); } catch (e) { NG.toast('Sem acesso ao microfone: libere no cadeado da barra de endereço.', 'bad'); return; }
      anexoLimpar();
      const rec = new MediaRecorder(stream, { mimeType: mime });
      const partes = [];
      rec.ondataavailable = (ev) => { if (ev.data && ev.data.size) partes.push(ev.data); };
      rec.onstop = () => {
        stream.getTracks().forEach((t) => t.stop());
        const g = st.grav; st.grav = null; clearInterval(g && g.timer);
        if (!g || g.descartar || !partes.length) { anexoDesenhar(); return; }
        const base = mime.split(';')[0];
        const blob = new Blob(partes, { type: base });
        if (blob.size > LIM_ARQ) { NG.toast('Áudio longo demais (mais de 16 MB).', 'bad'); anexoDesenhar(); return; }
        st.anexo = { file: blob, tipo: 'audio', mime: base, nome: `audio.${EXT_MIME[base] || 'ogg'}`, url: URL.createObjectURL(blob) };
        anexoDesenhar();
      };
      st.grav = { rec, t0: Date.now(), timer: setInterval(anexoDesenhar, 500) };
      rec.start();
      anexoDesenhar();
    }
    function gravarParar(descartar) { const g = st.grav; if (!g) return; g.descartar = !!descartar; try { g.rec.stop(); } catch (e) { st.grav = null; anexoDesenhar(); } }
    async function enviarMidia() {
      const a = st.anexo;
      if (!a || !st.d) return;
      if (!podeMidia()) { NG.toast('Foto, documento e áudio só no modo Responder.', 'bad'); return; }
      const legenda = a.tipo === 'audio' ? '' : ta.value.trim();
      const item = { id: `l${++nLocal}`, texto: legenda, em: new Date().toISOString(), estado: 'enviando', midiaLocal: { tipo: a.tipo, local: a.url, nome: a.nome } };
      st.locais.push(item);
      st.anexo = null; ta.value = ''; anexoDesenhar(); st.descer = true; desenhar();
      st.fila = st.fila.then(async () => {
        const caminho = `bo/${o.conversaId}/${Date.now()}_${Math.random().toString(36).slice(2, 8)}.${EXT_MIME[a.mime] || 'bin'}`;
        const up = await NG.sb.storage.from('midia_conversas').upload(caminho, a.file, { contentType: a.mime, upsert: false });
        const r = up.error ? { error: up.error } : await NG.sb.rpc('backoffice_midia', { p_conversa: o.conversaId, p_caminho: caminho, p_tipo: a.tipo, p_mime: a.mime, p_nome: a.nome, p_legenda: legenda || null });
        if (!st.vivo) return;
        if (r.error) { item.estado = 'erro'; item.erro = NG.msgErro(r.error); NG.toast(item.erro, 'bad'); }
        else { item.acao_id = r.data && r.data.acao_id; if (r.data && r.data.assumiu) NG.toast('Conversa assumida: a Mari calou', 'ok'); if (o.aoMudar) o.aoMudar(r.data); }
        desenharMsgs();
        setTimeout(() => carregar(), 1500);
      });
    }
    const citaEl = el.querySelector('[data-cita]');
    function citaDesenhar() {
      citaEl.hidden = !st.cita;
      citaEl.innerHTML = st.cita ? `<div class="cvp-cita-bar"><span><small>Respondendo a</small>${esc(st.cita.txt)}</span><button type="button" class="btn btn-sm" data-cv="cita-x" aria-label="Não citar">✕</button></div>` : '';
    }
    async function enviarUm(item) {
      const { data, error } = item.cita
        ? await NG.sb.rpc('backoffice_responder_citando', { p_conversa: o.conversaId, p_texto: item.texto, p_cw_msg_id: item.cita.id })   // 0334
        : item.sopro
        ? await NG.sb.rpc('mari_soprar', { p_conversa: o.conversaId, p_texto: item.texto })   // 0299: 🌬️ Soprar (a porta confere)
        : item.op
        ? await NG.sb.rpc('oportunidade_enviar', { p_conversa: o.conversaId, p_texto: item.tpl ? '' : item.texto, p_assumir: !!item.op.assumir, p_template: item.tpl })
        : await NG.sb.rpc('backoffice_responder', { p_conversa: o.conversaId, p_texto: item.tpl ? '' : item.texto, p_nota: item.nota, p_template: item.tpl });
      if ((item.op || item.sopro) && !error) NG.toast(data && data.resumo ? data.resumo : 'Mensagem enviada', 'ok');
      if (!st.vivo) return;
      if (error) {
        if (item.op && !o.oportunidade) o.oportunidade = item.op;   // não saiu: o reenvio volta pela oportunidade
        item.estado = 'erro';
        item.erro = NG.msgErro(error);
        NG.toast(item.erro, 'bad');
      } else {
        item.acao_id = data.acao_id;
        if (item.sug && data.acao_id) {
          NG.sb.rpc('sugestao_resultado', { p_id: item.sug.id, p_escolhida: item.sug.escolhida, p_texto: item.texto, p_acao_id: data.acao_id })
            .then(({ error: e2 }) => { if (e2) console.warn('sugestao_resultado', e2.message); });
        }
        if (data.assumiu) NG.toast('Conversa assumida: a Mari calou', 'ok');
        if (o.aoMudar) o.aoMudar(data);
      }
      desenharMsgs();
      setTimeout(() => carregar(), 1200);
    }

    // ---------- ✨ Sugerir resposta (0297): só no clique — nada na abertura da conversa (regra 19) ----------
    async function sugerir() {
      if (!podeSugerir || !st.d || (st.sug && st.sug.carregando)) return;
      if (st.sug && st.sug.id && !st.sug.escolhida) sugRegistrar(st.sug.id, 0);   // pediu outra: a anterior foi dispensada
      const conv = o.conversaId;
      st.sug = { carregando: true };
      desenhar();
      let r = null, msg = '';
      try {
        const { data, error } = await NG.sb.functions.invoke('sugerir-resposta', { body: { conversa_id: conv } });
        if (error) {
          msg = error.message;
          try { const c = await error.context.json(); if (c && c.error) msg = c.error; } catch (_) { /* corpo não-JSON */ }
        } else r = data;
      } catch (e) { msg = e.message || String(e); }
      if (!st.vivo || o.conversaId !== conv) return;
      if (r && r.bloqueio) st.sug = { msg: r.mensagem || 'Sem sugestão agora.' };
      else if (r && Array.isArray(r.opcoes) && r.opcoes.length) st.sug = { id: r.sugestao_id, opcoes: r.opcoes, aviso: r.aviso || '', escolhida: 0 };
      else st.sug = { msg: msg || 'A IA não respondeu agora. Tente de novo ou use as Respostas rápidas.', erro: true };
      desenhar();
    }
    function sugRegistrar(id, escolhida) {
      if (!id) return;
      NG.sb.rpc('sugestao_resultado', { p_id: id, p_escolhida: escolhida }).then(({ error }) => { if (error) console.warn('sugestao_resultado', error.message); });
    }
    function sugEscolher(i) {
      const s = st.sug;
      const op = s && s.opcoes && s.opcoes[i - 1];
      if (!op) return;
      if (st.tpl) st.tpl = null;
      ta.readOnly = false;
      ta.value = op.texto;
      s.escolhida = i;
      s.base = op.texto;
      sugRegistrar(s.id, i);
      desenhar();
      ajusta();
      ta.focus();
      ta.setSelectionRange(ta.value.length, ta.value.length);
    }
    // dispensar = true: a pessoa fechou sem usar (registra "nenhuma"); false: só limpa (enviou, ou trocou de modo)
    function sugFechar(dispensar) {
      const s = st.sug;
      st.sug = null;
      if (dispensar && s && s.id && !s.escolhida) sugRegistrar(s.id, 0);
      if (dispensar && s && s.escolhida && ta.value === s.base) { ta.value = ''; ajusta(); }
      desenharSug();
    }
    function desenharSug() {
      const s = st.sug;
      let html = '';
      if (s && s.carregando) html = '<div class="cvp-sug-linha"><span class="cvp-sug-gira" aria-hidden="true">✨</span> lendo a conversa…</div>';
      else if (s && s.msg) html = `<div class="cvp-sug-linha${s.erro ? ' erro' : ''}">${esc(s.msg)}<button type="button" class="link" data-cv="sug-fechar" aria-label="Fechar">✕</button></div>`;
      else if (s && s.escolhida) {
        html = ta.value === s.base
          ? `<div class="cvp-sug-faixa">✨ sugerida pelo NIOGEN — confira antes de enviar${s.aviso ? ` · ${esc(s.aviso)}` : ''}<button type="button" class="link" data-cv="sug-fechar" aria-label="Descartar a sugestão">✕</button></div>`
          : '';
      } else if (s && s.opcoes) {
        html = `<div class="cvp-sug-cab"><b>✨ Sugestões</b> · escolha uma para editar na caixa${s.aviso ? ` · <span class="aviso">${esc(s.aviso)}</span>` : ''}
          <button type="button" class="link" data-cv="sug-fechar" title="Dispensar as duas">Dispensar ✕</button></div>
          <div class="cvp-sug-ops">${s.opcoes.map((op, i) => `<button type="button" class="cvp-sug-op" data-cv="sug-op" data-i="${i + 1}">
            <small>${esc(op.rotulo)}</small><span>${esc(op.texto)}</span></button>`).join('')}</div>`;
      }
      if (st.sig.sug !== html) { st.sig.sug = html; sugEl.innerHTML = html; }
      sugEl.hidden = !html;
      el.querySelector('.cvp-pe').classList.toggle('com-sug', !!html);   // ficha (cheia): o pé de altura fixa cresce enquanto há sugestão
    }

    async function conversaAcao(acao, valor) {
      const { data, error } = await NG.sb.rpc('backoffice_conversa', { p_conversa: o.conversaId, p_acao: acao, p_valor: valor });
      if (error) { NG.toast(NG.msgErro(error), 'bad'); st.sig.cab = st.sig.etq = null; await carregar(); return; }
      NG.toast((data && data.resumo) || 'Feito', 'ok');
      if (o.aoMudar) o.aoMudar(data);
      await carregar();
      setTimeout(() => carregar(), 3000);
    }

    // ---------- emojis (painel montado no 1º clique; insere onde está o cursor) ----------
    function emoDesenhar() {
      const rec = emoRecentes();
      const abas = rec.length ? [{ ico: '🕘', rot: 'Recentes', lista: rec }, ...EMO_ABAS] : EMO_ABAS;
      if (st.emoAba >= abas.length) st.emoAba = 0;
      const aba = abas[st.emoAba];
      emoEl.innerHTML = `<div class="cvp-emo-abas" role="tablist">${abas.map((a, i) => `<button type="button" role="tab" data-cv="emo-aba" data-i="${i}" class="${i === st.emoAba ? 'on' : ''}" aria-selected="${i === st.emoAba}" title="${esc(a.rot)}">${a.ico}</button>`).join('')}</div>
        <div class="cvp-emo-rot">${esc(aba.rot)}</div>
        <div class="cvp-emo-grade">${aba.lista.map((e) => `<button type="button" data-cv="emo-x" data-e="${esc(e)}" aria-label="${esc(e)}">${e}</button>`).join('')}</div>`;
    }
    function emoAbrir() {
      if (ta.readOnly) return;
      st.emoAba = 0;
      emoDesenhar();
      emoEl.hidden = false;
      emoBt.setAttribute('aria-expanded', 'true');
    }
    function emoFechar() { emoEl.hidden = true; emoBt.setAttribute('aria-expanded', 'false'); }
    function emoInserir(e) {
      if (ta.readOnly) return;
      const ini = ta.selectionStart ?? ta.value.length, fim = ta.selectionEnd ?? ini;
      ta.value = ta.value.slice(0, ini) + e + ta.value.slice(fim);
      const pos = ini + e.length;
      ta.focus({ preventScroll: true });
      ta.setSelectionRange(pos, pos);
      ajusta();
      emoGuardar(e);
    }
    emoEl.addEventListener('mousedown', (ev) => ev.preventDefault());   // não tira o foco/cursor da caixa
    const emoFora = (ev) => { if (!emoEl.hidden && !emoEl.contains(ev.target) && ev.target !== emoBt) emoFechar(); };
    const emoEsc = (ev) => { if (ev.key === 'Escape' && !emoEl.hidden) { ev.stopPropagation(); emoFechar(); ta.focus(); } };
    document.addEventListener('mousedown', emoFora);
    el.addEventListener('keydown', emoEsc, true);

    const caixaEl = el.querySelector('.cvp-caixa'), anexoEl = el.querySelector('[data-anexo]'), clipMenu = el.querySelector('[data-clipmenu]');
    const ajusta = () => {
      ta.style.height = 'auto'; ta.style.height = `${Math.min(ta.scrollHeight, o.cheia ? 66 : 150)}px`;
      if (caixaEl) caixaEl.classList.toggle('vazia', !ta.value.trim() && !st.anexo && !st.tpl && !st.nota);
    };
    ta.addEventListener('input', ajusta);
    ta.addEventListener('input', () => { if (st.sug && st.sug.escolhida) desenharSug(); });   // editou: a faixa "confira" sai
    // Enter envia; Shift+Enter pula linha. No meio de um acento (IME) não envia. Esc cancela o template.
    ta.addEventListener('keydown', (ev) => {
      if (ev.key === 'Enter' && !ev.shiftKey && !ev.isComposing && ev.keyCode !== 229) { ev.preventDefault(); ev.stopPropagation(); enviar(); return; }
      if (ev.key === 'Escape' && st.tpl) { ev.stopPropagation(); st.tpl = null; ta.value = ''; ajusta(); desenhar(); }
    });
    const aoParar = () => { if (st.adiar) desenharMsgs(); };
    msgs.addEventListener('pause', aoParar, true);
    msgs.addEventListener('ended', aoParar, true);
    msgs.addEventListener('scroll', () => { if (msgs.scrollHeight - msgs.scrollTop - msgs.clientHeight < 60) novas.hidden = true; });
    el.addEventListener('click', (ev) => {
      const b = ev.target.closest('[data-cv]');
      if (!b || b.tagName === 'SELECT') return;
      const a = b.dataset.cv;
      if (a === 'fechar' && o.aoFechar) { o.aoFechar(); return; }
      if (a === 'concluir' && o.aoConcluir) { o.aoConcluir(); return; }
      if (a === 'enviar') { enviar(); return; }
      if (a === 'citar') { if (!podeMidia()) { NG.toast('Responder citando só no modo Responder.', 'bad'); return; } st.cita = { id: Number(b.dataset.cw), txt: b.dataset.txt || '' }; citaDesenhar(); ta.focus(); return; }
      if (a === 'cita-x') { st.cita = null; citaDesenhar(); return; }
      if (a === 'gravar') { gravarCampo(b.dataset.campo, b.dataset.valor, b); return; }
      if (a === 'gravar-sel') {
        const campo = b.dataset.campo;
        let val = selTxt;
        if (campo === 'cpf' || campo === 'cep') val = val.replace(/\D/g, '');
        if (campo === 'email') val = val.toLowerCase();
        selMenu.hidden = true;
        window.getSelection().removeAllRanges();
        gravarCampo(campo, val, null);
        return;
      }
      if (a === 'clip') { const ab = clipMenu.hidden; clipMenu.hidden = !ab; b.setAttribute('aria-expanded', String(ab)); return; }
      if (a === 'clip-foto' || a === 'clip-doc') { clipMenu.hidden = true; const inp = el.querySelector(`input[data-arq="${a === 'clip-foto' ? 'imagem' : 'arquivo'}"]`); if (inp) inp.click(); return; }
      if (a === 'mic') { gravarIniciar(); return; }
      if (a === 'grav-parar') { gravarParar(false); return; }
      if (a === 'grav-x') { gravarParar(true); return; }
      if (a === 'anexo-x') { anexoLimpar(); return; }
      if (a === 'sugerir') { sugerir(); return; }
      if (a === 'sug-op') { sugEscolher(Number(b.dataset.i) || 0); return; }
      if (a === 'sug-fechar') { sugFechar(true); return; }
      if (a === 'devolver') { devolver(b.dataset.onde || 'cab'); return; }
      if (a === 'foto') { abrirFoto(b.dataset.url); return; }
      if (a === 'emoji') { if (emoEl.hidden) emoAbrir(); else emoFechar(); return; }
      if (a === 'emo-aba') { st.emoAba = Number(b.dataset.i) || 0; emoDesenhar(); return; }
      if (a === 'emo-x') { emoInserir(b.dataset.e); return; }
      if (a === 'descer') { msgs.scrollTop = msgs.scrollHeight; novas.hidden = true; return; }
      if (a === 'modo') { st.nota = b.dataset.m === 'nota'; st.sopro = b.dataset.m === 'sopro'; st.tpl = null; if (ta.readOnly) ta.value = ''; desenhar(); ta.focus(); return; }
      if (a === 'tirar') { conversaAcao('etiqueta_remove', b.dataset.tg); return; }
      if (a === 'dono-sw') {
        if (b.disabled || st.trocandoDono) return;
        const praTime = b.classList.contains('mari');
        st.trocandoDono = true;
        b.disabled = true;
        b.classList.toggle('mari', !praTime); b.classList.toggle('time', praTime);   // mexe na hora; o carregar confirma
        conversaAcao('atribuir', praTime ? 'time' : 'mari').finally(() => { st.trocandoDono = false; st.sig.cab = null; desenhar(); });
        return;
      }
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
      destruir() { if (st.sug && st.sug.id && !st.sug.escolhida) sugRegistrar(st.sug.id, 0); st.vivo = false; clearInterval(intervalo); clearTimeout(st.tArmado); document.removeEventListener('visibilitychange', aoVoltar); document.removeEventListener('mousedown', emoFora); el.remove(); },
      focar() { ta.focus(); },
      // 12/11: faixa da Mari (tela cheia). registro = a faixa ocupa a caixa (Registrar contato / cadência), sem mudar a altura.
      mari(html, registro) {
        if (st.sig.mari !== html) { st.sig.mari = html; mariEl.innerHTML = html; }
        mariEl.hidden = !html;
        el.querySelector('.cvp-pe').classList.toggle('com-reg', !!registro);
      },
      get id() { return o.conversaId; },
    };
  }

  window.NGConversa = { montar, textoTurno, capturas };
})();
