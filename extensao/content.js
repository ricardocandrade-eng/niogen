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
 *     (o único console.* é o registro de clique recusado da 0.4, sem dado de cliente).
 *  5. (0.4.0, Ricardo 10/11 11h02) No Histórico de Pedidos: cliques SÓ na lista branca de cliqueFiltro() (Filtros, campos e opções do
 *     filtro, datas, Filtrar, próxima página) para LER a tabela. Detalhar, Carregar, Salvar, Atualizar Pedido, Novo Pedido, Funil e
 *     Tramitações: recusados no código.
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

  // Os nomes pelos quais um campo se apresenta. No portal real (conferido em 06/11 com o diagnóstico do Ricardo) o campo vem com
  // placeholder=" " e o texto visível é um <label> IRMÃO logo depois do input (<input name="cep"> + <label>Endereço ou CEP</label>);
  // só alguns têm placeholder de verdade ("Endereço de instalação"). Por isso: placeholder (se não for em branco), aria-label,
  // <label> associado, irmão de texto imediato e o pai quando ele só tem aquele campo.
  function nomesDoCampo(el) {
    const out = new Set();
    const add = (s) => { const n = normPh(s); if (n) out.add(n); };
    const ph = el.getAttribute('placeholder');
    if (ph && ph.trim()) add(ph);
    add(el.getAttribute('aria-label'));
    if (el.labels) for (const l of el.labels) add(l.textContent);
    for (const irmao of [el.nextElementSibling, el.previousElementSibling]) {
      if (irmao && !irmao.matches('input, textarea, select, button') && !irmao.querySelector('input, textarea, select, button')) {
        const t = irmao.textContent;
        if (t && t.length <= 60) add(t);
      }
    }
    const pai = el.parentElement;
    if (pai && pai.querySelectorAll('input, textarea').length === 1) {
      const t = pai.textContent;
      if (t && t.length <= 60) add(t);
    }
    return out;
  }

  function acharCampo(placeholders) {
    const alvos = placeholders.map(normPh);
    const campos = document.querySelectorAll('input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"]), textarea');
    for (const el of campos) {
      if (!visivel(el)) continue;
      const nomes = nomesDoCampo(el);
      if (alvos.some((a) => nomes.has(a))) return el;
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
    for (const el of document.querySelectorAll('input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"]), textarea')) {
      if (visivel(el)) nomesDoCampo(el).forEach((n) => phs.add(n));
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

  // ================================================================== 0.4.0 — Histórico de Pedidos (só leitura)
  // Exceção do Ricardo (10/11 11h02, regra 5): no Histórico a extensão pode clicar SÓ nos filtros — botão "Filtros", os campos e as
  // opções do painel de filtros, as datas, "Filtrar" e a paginação — para LER a tabela. Nunca Detalhar, Carregar pedido, Salvar,
  // Atualizar Pedido, Novo Pedido, Funil de Vendas, Histórico tramitações, nem nada fora do Histórico. Sem API, sem rede, sem token.
  // Conferido no portal real em 10/11 (Claude Code): filtros react-select no MuiDrawer (Tipo · Status Primário · Status Secundário ·
  // Pedidos [multi] · Segmento), período = 2 datas MUI (máximo 30 dias — "Período deve ser no máximo de 30 dias"), "Filtrar" fecha o
  // painel e a tabela MuiTable traz TIPO · STATUS · PEDIDO · DATA · PDV · VENDEDOR · CLIENTE · SEGMENTO · OFERTA · DETALHES.
  // Único console.* deste arquivo: o registro da recusa (sem dado de cliente).
  const HIST = /^\/administrativo\/historico\/?$/;
  const naHistorico = () => HIST.test(location.pathname);
  const STATUS_VENDA = ['Aguardando tratamento', 'Contato Agendado', 'Gross', 'Não Venda', 'Pedido Gerado', 'Sem contato com o cliente', 'Venda'];
  const PROIBIDOS = ['detalhar', 'carregar pedido', 'salvar', 'atualizar pedido', 'novo pedido', 'funil de vendas', 'historico tramitacoes'];
  const gaveta = () => document.querySelector('.MuiDrawer-paper');

  // A lista branca. Tudo o que a leitura do Histórico clica passa por aqui; o resto é recusado e registrado no console.
  function cliqueFiltro(el, oQue) {
    const recusa = (motivo) => {
      console.warn(`niogen: clique recusado (${oQue || '?'}) — ${motivo}`);
      throw new Error(`niogen: recusado — ${motivo}`);
    };
    if (!(el instanceof Element)) recusa('alvo inválido');
    if (!naHistorico()) recusa('fora do Histórico de Pedidos');
    const txt = norm(el.textContent);
    if (PROIBIDOS.some((p) => txt === p || txt.startsWith(p))) recusa(`"${el.textContent.trim().slice(0, 40)}" não está na lista branca`);
    const g = gaveta();
    const cls = String(el.getAttribute('class'));
    const permitido =
      (el.matches('button#drawer-filter') && /filtros/.test(txt))                                               // abrir o painel de Filtros
      || (g && g.contains(el) && /-control\b/.test(cls))                                                         // abrir um campo do filtro
      // escolher uma opção: o react-select abre o menu FORA do painel (portal no <body>) — vale com o painel de Filtros aberto e
      // só dentro de um menu do react-select (nunca célula de tabela, link ou botão)
      || (g && /-option\b/.test(cls) && !!el.closest('[class*="-menu"]') && !el.closest('table, nav, a, button'))
      || (g && g.contains(el) && el.tagName === 'BUTTON' && txt === 'filtrar')                                  // Filtrar
      || (el.tagName === 'BUTTON' && !!el.closest('.MuiTablePagination-root')
          && /next page|proxima/.test(norm(el.getAttribute('aria-label') || el.title)));                         // próxima página
    if (!permitido) recusa(`"${(el.textContent || el.getAttribute('aria-label') || el.tagName).trim().slice(0, 40)}" não está na lista branca`);
    if (/-control\b/.test(cls)) el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
    else el.click();
  }

  async function abrirFiltros() {
    if (gaveta() && gaveta().querySelector('label.titulo-status-filter')) return;
    const b = Array.from(document.querySelectorAll('button#drawer-filter')).find((x) => /filtros/.test(norm(x.textContent)));
    if (!b) throw new Error('não achei o botão "Filtros" do Histórico');
    cliqueFiltro(b, 'Filtros');
    for (let i = 0; i < 50 && !(gaveta() && gaveta().querySelector('label.titulo-status-filter')); i++) await espera(100);
    if (!gaveta()) throw new Error('o painel de Filtros não abriu');
    await espera(250);
  }
  const blocoFiltro = (nome) => {
    const l = Array.from(gaveta().querySelectorAll('label.titulo-status-filter')).find((x) => norm(x.textContent) === norm(nome));
    return l ? l.closest('.row').parentElement : null;
  };
  const valoresFiltro = (nome) => {
    const b = blocoFiltro(nome);
    return b ? Array.from(b.querySelectorAll('[class*="singleValue"], [class*="multiValue"]')).map((x) => x.textContent.trim()) : [];
  };
  async function opcoesFiltro(nome) {
    await abrirFiltros();
    const b = blocoFiltro(nome);
    if (!b) throw new Error(`campo "${nome}" não achado nos filtros`);
    cliqueFiltro(b.querySelector('[class*="-control"]'), nome);
    let os = [];
    for (let i = 0; i < 20; i++) { await espera(100); os = Array.from(document.querySelectorAll('[class*="-menu"] [class*="-option"]')); if (os.length) break; }
    return os;
  }
  async function fecharLista() { if (document.activeElement) document.activeElement.blur(); await espera(200); }
  async function escolherFiltro(nome, texto) {
    await abrirFiltros();
    if (valoresFiltro(nome).some((v) => norm(v) === norm(texto))) return true;
    const os = await opcoesFiltro(nome);
    const o = os.find((x) => norm(x.textContent) === norm(texto));
    if (!o) { await fecharLista(); return false; }
    cliqueFiltro(o, `${nome}: ${texto}`);
    for (let i = 0; i < 20 && !valoresFiltro(nome).some((v) => norm(v) === norm(texto)); i++) await espera(100);
    return valoresFiltro(nome).some((v) => norm(v) === norm(texto));
  }
  const fmtData = (d) => d.toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric' });
  async function periodo(dias) {
    await abrirFiltros();
    const datas = Array.from(gaveta().querySelectorAll('input')).filter((i) => /^\d{2}\/\d{2}\/\d{4}$/.test(i.value));
    if (datas.length < 2) throw new Error('não achei as duas datas do período');
    const hoje = new Date();
    const ini = fmtData(new Date(hoje.getTime() - dias * 86400000)), fim = fmtData(hoje);
    for (const [el, v] of [[datas[0], ini], [datas[1], fim]]) { if (el.value !== v) { setValor(el, v); await espera(200); el.blur(); await espera(150); } }
    return `${ini} a ${fim}`;
  }
  const toasts = () => Array.from(document.querySelectorAll('.Toastify__toast, [role="alert"]')).map((x) => x.innerText.trim()).filter(Boolean);
  const assinaturaTabela = () => {
    const t = document.querySelector('table.MuiTable-root');
    const pag = document.querySelector('.MuiTablePagination-root');
    return t ? `${t.querySelectorAll('tbody tr').length}|${pag ? pag.innerText : ''}|${(t.querySelector('tbody tr') || {}).innerText || ''}` : 'sem-tabela';
  };
  async function esperaEstavel(antes, maxMs) {
    // espera a tabela mudar (ou sumir) e ficar parada por 2 leituras seguidas; erro do portal (aviso vermelho) para tudo
    const t0 = Date.now(); let ult = null; let iguais = 0;
    await espera(1200);
    while (Date.now() - t0 < maxMs) {
      const tt = toasts().find((x) => /deve ser|erro|falha|inv[aá]lid|n[aã]o foi poss/i.test(x));
      if (tt) throw new Error(`o portal avisou: ${tt.replace(/\s+/g, ' ').slice(0, 120)}`);
      const a = assinaturaTabela();
      if (a === ult) { iguais += 1; if (iguais >= 2 && (a !== antes || Date.now() - t0 > 4000)) return; } else { ult = a; iguais = 0; }
      await espera(500);
    }
    throw new Error('o portal está lento (a tabela não respondeu em 20 s)');
  }
  function lerLinhas() {
    const t = document.querySelector('table.MuiTable-root');
    if (!t) return [];
    return Array.from(t.querySelectorAll('tbody tr')).map((tr) => Array.from(tr.children).map((td) => td.innerText.trim()))
      .filter((c) => c.length >= 9 && /\d{4,}/.test(c[2]))
      .map((c) => ({ tipo: c[0], status: c[1], pedido: c[2], data: c[3], pdv: c[4], vendedor: c[5], cliente: c[6], segmento: c[7], oferta: c[8] }));
  }
  async function lerTodasPaginas() {
    const out = lerLinhas();
    for (let p = 0; p < 50; p++) {
      const prox = document.querySelector('.MuiTablePagination-root button[aria-label="next page"], .MuiTablePagination-root button[title*="róxima"]');
      if (!prox || prox.disabled) break;
      const antes = assinaturaTabela();
      cliqueFiltro(prox, 'próxima página');
      await esperaEstavel(antes, 20000);
      out.push(...lerLinhas());
    }
    return out;
  }
  async function pesquisa(tipo, status, dias, progresso) {
    await abrirFiltros();
    if (!(await escolherFiltro('Tipo', tipo))) throw new Error(`não consegui escolher o Tipo "${tipo}"`);
    if (!(await escolherFiltro('Pedidos', 'Todos os Pedidos'))) throw new Error('não consegui escolher "Todos os Pedidos"');
    if (status && !(await escolherFiltro('Status Primário', status))) throw new Error(`não consegui escolher o status "${status}"`);
    const per = await periodo(dias);
    const filtrar = Array.from(gaveta().querySelectorAll('button')).find((b) => norm(b.textContent) === 'filtrar');
    if (!filtrar || filtrar.disabled) throw new Error('"Filtrar" desabilitado');
    const antes = assinaturaTabela();
    progresso(`${tipo}${status ? ` · ${status}` : ''}…`);
    cliqueFiltro(filtrar, 'Filtrar');
    await esperaEstavel(antes, 20000);
    const linhas = await lerTodasPaginas();
    return { linhas, periodo: per };
  }
  let lendo = false;
  async function lerHistorico(progresso) {
    if (!naHistorico()) throw new Error('Abra "Histórico de Pedidos" no portal antes.');
    if (lendo) throw new Error('A leitura já está rodando.');
    lendo = true;
    const vistos = new Map(); const feitas = []; let per = '';
    const DIAS = 30;   // o máximo que o portal aceita (conferido em 10/11)
    try {
      const roteiro = STATUS_VENDA.map((s) => ['Venda', s]);
      for (const tipo of ['Pré-Venda', 'Interesse']) {
        // só os status que a lista oferecer; se não oferecer nenhum, uma pesquisa sem status (o portal aceita para esses tipos)
        if (!(await escolherFiltro('Tipo', tipo))) continue;
        const os = (await opcoesFiltro('Status Primário')).map((x) => x.textContent.trim()).filter(Boolean);
        await fecharLista();
        if (os.length) os.forEach((s) => roteiro.push([tipo, s])); else roteiro.push([tipo, null]);
      }
      for (const [tipo, status] of roteiro) {
        let r;
        try { r = await pesquisa(tipo, status, DIAS, progresso); }
        catch (e) { return { ok: false, pedidos: Array.from(vistos.values()), feitas, periodo: per, parou_em: `${tipo}${status ? ' · ' + status : ''}`, erro: e.message }; }
        per = r.periodo;
        r.linhas.forEach((l) => vistos.set(l.pedido, l));
        feitas.push({ tipo, status, n: r.linhas.length });
        progresso(`${tipo}${status ? ` · ${status}` : ''}: ${r.linhas.length}`);
        await espera(2000);   // freio entre pesquisas
      }
      return { ok: true, pedidos: Array.from(vistos.values()), feitas, periodo: per };
    } finally { lendo = false; }
  }
  // Prova da lista branca (teste 3 do prompt): tenta clicar "Detalhar" pelo código e devolve a recusa. Não clica em nada.
  function testarListaBranca() {
    const alvo = Array.from(document.querySelectorAll('button, a, [role="button"], td, span')).find((x) => norm(x.textContent) === 'detalhar');
    if (!alvo) return { ok: false, msg: 'nenhum "Detalhar" na tela (faça uma pesquisa antes)' };
    try { cliqueFiltro(alvo, 'teste'); return { ok: false, msg: 'ERRO: o clique passou' }; } catch (e) { return { ok: true, msg: e.message }; }
  }

  // ------------------------------------------------------------------ conversa com o painel
  let ultimo = '';
  function empurraEstado(forca) {
    const estado = { tipo: 'estado', etapa: detectarEtapa(), avisos: detectarAvisos(), historico: naHistorico() };
    const chave = JSON.stringify([estado.etapa, estado.avisos.map((a) => a.codigo), estado.historico]);
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
    if (msg.tipo === 'historico_ler') {
      const prog = (texto) => { try { chrome.runtime.sendMessage({ tipo: 'historico_progresso', texto }, () => void chrome.runtime.lastError); } catch (e) { /* painel fechado */ } };
      lerHistorico(prog).then((r) => responde(r), (e) => responde({ ok: false, pedidos: [], feitas: [], erro: e.message, parou_em: 'início' }));
      return true;
    }
    if (msg.tipo === 'historico_teste_lista_branca') { responde(testarListaBranca()); return false; }
    if (msg.tipo === 'preencher') {
      limparDestaques();
      preencher(Array.isArray(msg.campos) ? msg.campos : []).then((resultados) => responde({ ok: true, resultados, etapa: detectarEtapa() }));
      return true;
    }
    return false;
  });
  empurraEstado(true);
})();
