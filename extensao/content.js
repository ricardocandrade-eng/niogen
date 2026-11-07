/* NIOGEN | extensao/content.js | 06/11/2026 — Claude Code (prompt 28)
 * Roda DENTRO da página do portal PAP aberta pelo humano. Só lê o DOM e escreve valores nos campos.
 *
 * REGRAS (CLAUDE.md regra 5, exceção de 06/11 21h19) — não negociáveis:
 *  1. NUNCA clica em botão do portal (Avançar, Buscar, Continuar, Salvar interesse, Seguir fora da área, biometria, checkout, Abrir OS).
 *     Os únicos "cliques" permitidos estão em cliqueSeguro(): escolher um <li>/[role=option] de lista suspensa e marcar
 *     checkbox/radio (Sem número, Sem complemento…). Qualquer outra coisa lança erro.
 *  2. Não toca em login, token, localStorage/sessionStorage/cookie do portal, nem na rede (nada de fetch/XHR aqui).
 *  3. Etapas 5, 6 e 7: só DESTACA (contorno); nunca preenche crédito, oferta, pagamento, banco/agência/conta.
 *  4. Dado de cliente existe só na mensagem de preenchimento e nas variáveis locais da chamada: não é guardado, nem logado
 *     (este arquivo não usa console.*).
 */
(() => {
  'use strict';
  if (window.__niogenNoPortal) return;
  window.__niogenNoPortal = true;

  // ------------------------------------------------------------------ utilitários
  const norm = (s) => String(s == null ? '' : s).normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/\s+/g, ' ').trim().toLowerCase();
  const normPh = (s) => norm(s).replace(/\s*\(obrigatorio\)\s*$/, '').replace(/\s*\*$/, '').trim();
  const digitos = (s) => String(s == null ? '' : s).replace(/\D/g, '');
  const espera = (ms) => new Promise((r) => setTimeout(r, ms));
  const visivel = (el) => !!el && (el.getClientRects().length > 0) && getComputedStyle(el).visibility !== 'hidden';

  // ------------------------------------------------------------------ a trava de cliques
  const BLOQUEADO = 'button, a[href], [role="button"], input[type="submit"], input[type="button"], input[type="reset"], summary';
  function cliqueSeguro(el) {
    if (!el || !(el instanceof Element)) throw new Error('niogen: alvo inválido');
    if (el.closest(BLOQUEADO)) throw new Error('niogen: recusado — clique em botão/link é do humano');
    const ehLista = el.tagName === 'LI' || el.getAttribute('role') === 'option' || el.getAttribute('role') === 'menuitem';
    const ehCaixa = el.tagName === 'INPUT' && (el.type === 'checkbox' || el.type === 'radio');
    if (!ehLista && !ehCaixa) throw new Error('niogen: recusado — só opção de lista e caixa de marcar');
    el.click();
  }
  // Abrir a lista do próprio campo: foco + clique no PRÓPRIO input de texto (não é botão).
  function abrirCampo(input) {
    if (!(input instanceof HTMLInputElement) || !['text', 'search', ''].includes(input.type) || input.closest(BLOQUEADO)) return;
    input.focus();
    input.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
    input.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true }));
    input.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
  }

  // ------------------------------------------------------------------ escrever em campo React (inputs sem id/name)
  function setValor(el, valor) {
    const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
    el.focus();
    setter.call(el, valor);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function acharCampo(placeholders) {
    const alvos = placeholders.map(normPh);
    const campos = document.querySelectorAll('input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"]), textarea');
    for (const el of campos) {
      if (!visivel(el)) continue;
      const ph = normPh(el.getAttribute('placeholder') || el.getAttribute('aria-label') || '');
      if (ph && alvos.includes(ph)) return el;
    }
    return null;
  }

  function acharOpcaoPorTexto(textos) {
    const alvos = textos.map(norm);
    const CAIXA = 'input[type="checkbox"], input[type="radio"]';
    // 1. caixa de marcar / rádio cujo RÓTULO (label que a envolve ou label[for]) tem exatamente o texto
    for (const inp of document.querySelectorAll(CAIXA)) {
      const rot = inp.closest('label') || (inp.id && document.querySelector(`label[for="${CSS.escape(inp.id)}"]`));
      if (rot && visivel(rot) && alvos.includes(norm(rot.textContent))) return inp;
    }
    // 2. texto solto ao lado de UMA caixa (irmão imediato ou pai que só tem aquele texto + a caixa) — nunca botão/link
    for (const el of document.querySelectorAll('label, span, p, div')) {
      if (!visivel(el) || el.closest(BLOQUEADO) || el.querySelector('*') || !alvos.includes(norm(el.textContent))) continue;
      const vizinho = [el.previousElementSibling, el.nextElementSibling].find((x) => x && x.matches && x.matches(CAIXA));
      if (vizinho) return vizinho;
      const pai = el.parentElement;
      if (pai && norm(pai.textContent) === norm(el.textContent)) {
        const caixas = pai.querySelectorAll(CAIXA);
        if (caixas.length === 1) return caixas[0];
      }
    }
    // 3. itens de lista
    for (const li of document.querySelectorAll('li, [role="option"]')) {
      if (visivel(li) && alvos.includes(norm(li.textContent))) return li;
    }
    return null;
  }

  // ------------------------------------------------------------------ lista suspensa: digitar, esperar a lista, escolher a opção
  function candidatosLista(input) {
    // <li> visíveis; os mais próximos do input primeiro (a lista nasce junto do campo)
    const todos = Array.from(document.querySelectorAll('li, [role="option"]')).filter((li) => visivel(li) && !li.closest('nav, header'));
    let raiz = input.parentElement;
    for (let i = 0; i < 4 && raiz; i++, raiz = raiz.parentElement) {
      const perto = todos.filter((li) => raiz.contains(li));
      if (perto.length) return perto;
    }
    return todos;
  }

  function escolher(lista, termos, exato) {
    const alvos = termos.map(norm);
    const pontua = (li) => {
      const t = norm(li.textContent);
      let melhor = 99;
      for (const a of alvos) {
        if (t === a) melhor = Math.min(melhor, 0);
        else if (!exato && (t.startsWith(a + ' ') || t.startsWith(a + '-') || t.startsWith(a + ' -'))) melhor = Math.min(melhor, 1);
        else if (!exato && t.includes(a)) melhor = Math.min(melhor, 2);
      }
      return melhor;
    };
    const pontuados = lista.map((li) => [li, pontua(li)]).filter(([, p]) => p < 99);
    if (!pontuados.length) return { estado: 'sem_opcao' };
    const m = Math.min(...pontuados.map(([, p]) => p));
    const melhores = pontuados.filter(([, p]) => p === m);
    if (melhores.length > 1 && m === 2) return { estado: 'ambiguo' };
    return { estado: 'ok', li: melhores[0][0] };
  }

  async function campoLista(el, c) {
    const termos = (c.match && c.match.length ? c.match : [c.busca]).filter(Boolean);
    if (!termos.length) return 'sem_valor';
    // já preenchido com a opção certa?
    const atual = norm(el.value);
    if (atual && termos.some((t) => atual === norm(t) || atual.includes(norm(t))) && c.jaFeito !== false) return 'ja';
    abrirCampo(el);
    setValor(el, c.busca);
    let r = { estado: 'sem_opcao' };
    for (let i = 0; i < 40; i++) {            // até 4 s para a lista aparecer
      await espera(100);
      r = escolher(candidatosLista(el), termos, !!c.exato);
      if (r.estado !== 'sem_opcao') break;
    }
    if (r.estado !== 'ok') return r.estado;
    cliqueSeguro(r.li);
    await espera(350);
    return 'ok';
  }

  // ------------------------------------------------------------------ preencher
  async function preencherUm(c) {
    if (c.modo === 'destacar') return destacar(c);
    if (c.modo === 'opcao') {
      const alvo = acharOpcaoPorTexto(c.textos || []);
      if (!alvo) return 'nao_achado';
      if (alvo.tagName === 'INPUT' && alvo.checked) return 'ja';
      cliqueSeguro(alvo);
      await espera(250);
      return 'ok';
    }
    if (c.valor == null || c.valor === '') return 'sem_valor';
    const el = acharCampo(c.ph || []);
    if (!el) return 'nao_achado';
    if (el.disabled || el.readOnly) return 'bloqueado';
    if (c.modo === 'lista') return campoLista(el, c);
    if (norm(el.value) === norm(c.valor) || (c.numerico && digitos(el.value) === digitos(c.valor))) return 'ja';
    setValor(el, String(c.valor));
    await espera(120);
    // máscara do portal pode reformatar; só reclama se o conteúdo mudou de verdade
    const ok = c.numerico ? digitos(el.value) === digitos(c.valor) : norm(el.value) === norm(c.valor);
    return ok ? 'ok' : 'nao_aceito';
  }

  async function preencher(campos) {
    const res = [];
    for (const c of campos) {
      try { res.push({ id: c.id, estado: await preencherUm(c) }); }
      catch (e) { res.push({ id: c.id, estado: 'recusado' }); }
    }
    return res;
  }

  // ------------------------------------------------------------------ destaque (etapa 5): só contorno, nunca clique
  const DEST = '__niogenDestaque';
  function limparDestaques() {
    document.querySelectorAll(`[${DEST}]`).forEach((el) => {
      el.style.outline = el.getAttribute(DEST) === '-' ? '' : el.getAttribute(DEST);
      el.style.outlineOffset = '';
      el.removeAttribute(DEST);
    });
  }
  function destacar(c) {
    const alvos = (c.textos || []).map(norm).filter(Boolean);
    if (!alvos.length) return 'sem_valor';
    const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let achado = null;
    while (w.nextNode()) {
      const t = norm(w.currentNode.nodeValue);
      if (t.length > 120 || !t) continue;
      if (alvos.some((a) => t === a || (c.contem !== false && t.includes(a)))) {
        const pai = w.currentNode.parentElement;
        if (pai && visivel(pai) && !pai.closest('script, style')) { achado = pai; break; }
      }
    }
    if (!achado) return 'nao_achado';
    let alvo = achado;
    for (let i = 0; i < 3 && alvo.parentElement && alvo.parentElement !== document.body && norm(alvo.parentElement.textContent).length < 260; i++) alvo = alvo.parentElement;
    if (!alvo.hasAttribute(DEST)) alvo.setAttribute(DEST, alvo.style.outline || '-');
    alvo.style.outline = '3px solid #32E000';
    alvo.style.outlineOffset = '3px';
    try { alvo.scrollIntoView({ block: 'center', behavior: 'smooth' }); } catch (e) { /* ignora */ }
    return 'destacado';
  }

  // ------------------------------------------------------------------ em que etapa do Novo Pedido estamos
  const POR_PLACEHOLDER = [
    [4, ['celular principal', 'confirme o celular principal', 'e-mail', 'confirme o e-mail']],
    [3, ['cpf', 'cpf/cnpj', 'data de nascimento', 'nome completo da mae', 'razao social']],
    [2, ['endereco ou cep', 'numero', 'referencia']],
    [1, ['informe a uf', 'insira o codigo ou nome do seu pdv', 'informe a matricula do vendedor']],
  ];
  function textosCurtos() {
    const seletor = 'h1, h2, h3, h4, h5, h6, legend, strong, b, [class*="itle" i], [class*="itulo" i], [class*="eader" i]';
    const out = new Set();
    for (const el of document.querySelectorAll(seletor)) {
      if (!visivel(el)) continue;
      const t = norm(el.textContent);
      if (t && t.length <= 70) out.add(t);
    }
    return out;
  }
  function detectarEtapa() {
    const phs = new Set();
    for (const el of document.querySelectorAll('input:not([type="hidden"]), textarea')) {
      if (visivel(el)) { const p = normPh(el.getAttribute('placeholder') || ''); if (p) phs.add(p); }
    }
    const textos = textosCurtos();
    const tem = (frag) => { for (const t of textos) if (t.includes(frag)) return true; return false; };
    if (tem('abrir os') || tem('agendamento da instalacao')) return 7;
    if (Array.from(textos).some((t) => t === 'resumo' || t === 'resumo do pedido' || t === 'resumo da compra')) return 6;
    if (tem('resumo da oferta') || tem('ofertas disponiveis') || tem('forma de pagamento')) return 5;
    for (const [n, lista] of POR_PLACEHOLDER) if (lista.some((p) => phs.has(p))) return n;
    if (tem('contato')) return 4;
    if (tem('cadastro do cliente')) return 3;
    if (tem('consulta de viabilidade')) return 2;
    if (tem('identificacao pdv') || tem('identificacao do pdv')) return 1;
    return null;
  }

  const AVISOS = [
    ['pedido_em_andamento', 'já existe outro pedido', 'O portal avisa que já existe outro pedido (Nova Fibra) em andamento para este cliente/endereço. Não siga: confira no portal (Histórico de pedidos) antes.'],
    ['celular_usado', 'celular ja utilizado anteriormente', 'O portal avisa "Celular já utilizado anteriormente". Confirme o número com o cliente; não force.'],
    ['fora_da_area', 'endereco fora da area', 'O portal avisa "Endereço fora da área". Não siga nem use "Seguir fora da área": tente variações de CEP, rua e número e fale com o Ricardo.'],
  ];
  function detectarAvisos() {
    const corpo = norm(document.body ? document.body.innerText : '');
    return AVISOS.filter(([, frag]) => corpo.includes(frag)).map(([codigo, , msg]) => ({ codigo, msg }));
  }

  // ------------------------------------------------------------------ conversa com o painel
  let ultimo = '';
  function empurraEstado(forca) {
    const estado = { tipo: 'estado', etapa: detectarEtapa(), avisos: detectarAvisos() };
    const chave = JSON.stringify([estado.etapa, estado.avisos.map((a) => a.codigo)]);
    if (!forca && chave === ultimo) return;
    ultimo = chave;
    try { chrome.runtime.sendMessage(estado, () => void chrome.runtime.lastError); } catch (e) { /* painel fechado */ }
  }
  let t = null;
  new MutationObserver(() => { clearTimeout(t); t = setTimeout(() => empurraEstado(false), 350); })
    .observe(document.documentElement, { childList: true, subtree: true, characterData: true });

  chrome.runtime.onMessage.addListener((msg, remetente, responde) => {
    if (!msg || typeof msg !== 'object') return false;
    if (msg.tipo === 'estado?') { empurraEstado(true); responde({ ok: true }); return false; }
    if (msg.tipo === 'limpar') { limparDestaques(); responde({ ok: true }); return false; }
    if (msg.tipo === 'preencher') {
      limparDestaques();
      preencher(Array.isArray(msg.campos) ? msg.campos : []).then((resultados) => responde({ ok: true, resultados, etapa: detectarEtapa() }));
      return true;
    }
    return false;
  });
  empurraEstado(true);
})();
