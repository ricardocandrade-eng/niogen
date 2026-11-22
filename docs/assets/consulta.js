/* NIOGEN | docs/assets/consulta.js | 21/11/2026 — Consulta central (pedido do Ricardo, 21/11: "consulta de viabilidade, crédito,
 * OS e digitalização numa tela única e de fácil acesso, em qualquer tela … que possa ser minimizada e voltar").
 * Painel sobre a tela: busca do cliente (nome, telefone, CPF ou L-número) e quatro abas — Viabilidade · Crédito · OS · GED360.
 * Carregado só ao abrir (assets/sidebar.js → botão "Consulta | Guia" no pé do menu e ⌕ na barra do celular): nada pesa na
 * abertura das telas (regra 19).
 *
 * SÓ LÊ (regra 20): não grava situação, status nem etapa do lead; nenhum botão daqui muda nada. Abrindo um cliente, cada aba
 * mostra o que já está GRAVADO (sem clicar). "Consultar de novo" usa os MESMOS caminhos das outras telas, sem caminho novo
 * para o portal (regra 5):
 *   · Viabilidade → NG.viabIniciar + NG.creditoStatus (edge credito-consulta, portal até a Etapa 2) e NG.dfvAoVivo
 *     (edge dfv-consulta) — como cobertura.html; a consulta é anotada por operador_consulta_registrar, igual à Cobertura.
 *   · Crédito    → NG.creditoIniciar + NG.creditoStatus (titular autorizou) — como cobertura.html. Não grava no lead.
 *   · OS         → NG.osConsultar (Consulta OS do portal, só "Filtros"/"Filtrar") — como o degrau da ficha e o ⟳ de Operações.
 *     A leitura que mudou já volta gravada pela função do banco que existe (os_leituras), não por esta tela.
 *   · GED360     → edge credito-consulta {acao:'bio'} — como o degrau Biometria da ficha (robô do n8n lê o Relatório Detalhado).
 * Nunca: Abrir OS, link de pagamento, agendar, "Salvar interesse", registrar resultado no lead (lead_registrar_consulta).
 *
 * Minimizar e restaurar: o estado (modo, busca, aba, cliente e as consultas feitas agora, com a hora) fica em sessionStorage
 * (niogen.consulta, em try/catch) — sobrevive à troca de página na mesma aba e some ao fechar a aba. CPF, e-mail e telefone
 * NUNCA vão para o storage: são relidos do banco ao restaurar. Consulta de viabilidade/crédito em andamento continua depois
 * de trocar de página (o job_id fica guardado e o painel volta a acompanhar).
 */
(function () {
  'use strict';
  if (window.NGConsulta) return;

  const KEY = 'niogen.consulta';
  const ABAS = [['viab', 'Viabilidade'], ['cred', 'Crédito'], ['os', 'OS'], ['bio', 'GED360']];
  const esc = (s) => NG.esc(s);
  const bo = () => ['admin', 'backoffice'].includes((NG.usuario || {}).perfil);
  const pausa = (ms) => new Promise((r) => setTimeout(r, ms));
  const dh = (iso) => (iso ? NG.fmtDataHora(iso) : '');
  const haQuanto = (iso) => {
    if (!iso) return '';
    const m = Math.round((Date.now() - new Date(iso)) / 60000);
    if (m < 1) return 'agora';
    if (m < 60) return `há ${m} min`;
    if (m < 48 * 60) return `há ${Math.round(m / 60)} h`;
    return `há ${Math.round(m / 1440)} dias`;
  };

  // ---------------------------------------------------------------- estado (sessionStorage, nunca com CPF/e-mail/telefone)
  // end: endereço DIGITADO (dados novos, ou outro endereço do cliente) — só CEP/nº/complemento; CPF nunca vai para o storage.
  const novoEst = () => ({ modo: 'fechado', q: '', aba: 'viab', cli: null, lista: null, novos: {}, end: null });
  let est = (() => { try { const e = JSON.parse(sessionStorage.getItem(KEY) || 'null'); return e && e.modo ? { ...novoEst(), ...e } : novoEst(); } catch (e) { return novoEst(); } })();
  // Busca por CPF ou telefone (8+ dígitos) não vai para o storage: volta com a caixa vazia, mas com o cliente aberto.
  const qGuardavel = (q) => (NG.soDigitos(q || '').length >= 8 ? '' : (q || ''));
  const gravar = () => { try { sessionStorage.setItem(KEY, JSON.stringify({ ...est, q: qGuardavel(est.q) })); } catch (e) { /* sem storage: o painel funciona, só não volta depois de trocar de página */ } };

  let dados = null;          // o que está gravado no banco para o cliente aberto (relido a cada abertura; não vai para o storage)
  let pessoal = {};          // CPF/e-mail/celular para o formulário do crédito (só em memória)
  let rodando = {};          // aba → true enquanto consulta
  let raiz = null, painel = null, pilula = null;

  // ---------------------------------------------------------------- rótulos
  const VIAB = { viavel: ['Viável', 'ok'], viavel_predio: ['Viável (prédio)', 'ok'], sem_viabilidade: ['Sem viabilidade', 'bad'], nao_encontrado: ['Endereço não encontrado', 'warn'],
    posse: ['Endereço já tem Nio (posse)', 'warn'], indisponivel: ['Portal não respondeu', 'warn'], complemento_fora_lista: ['Unidade fora da lista do portal', 'warn'],
    rua_divergente: ['O portal consultou outra rua', 'warn'], escolher: ['Escolher a unidade', 'warn'], erro: ['Erro na consulta', 'warn'] };
  const CRED = { aprovado_todas: ['Aprovado — todas as formas', 'ok'], aprovado_cartao: ['Aprovado — só cartão', 'ok'], aprovado_parcial: ['Aprovado (parcial)', 'ok'],
    aprovado: ['Aprovado', 'ok'], so_cartao: ['Aprovado só no cartão', 'ok'], negado: ['Negado', 'bad'], pendente: ['Pendente (24 h)', 'warn'],
    pedido_em_andamento: ['Já tem pedido em andamento', 'bad'], nao_classificado: ['Não classificado', 'warn'], sem_viabilidade: ['Endereço sem viabilidade', 'warn'],
    rua_divergente: ['O portal consultou outra rua', 'warn'], complemento_fora_lista: ['Unidade fora da lista do portal', 'warn'], email_invalido: ['E-mail recusado pelo portal', 'warn'],
    contato_repetido: ['Celular recusado pelo portal', 'warn'], erro_receita: ['Erro da Receita', 'warn'], erro: ['Erro na consulta', 'warn'] };
  const CRED_TXT = { negado: 'A Nio não aprovou o crédito deste CPF. Não abra pedido.', pendente: 'A Nio deixou a análise pendente. Consulte de novo mais tarde (o portal costuma pedir 24 h).',
    pedido_em_andamento: 'O cliente já tem pedido Nova Fibra em andamento. Veja a aba OS antes de falar com ele.',
    sem_viabilidade: 'O endereço do cliente não tem viabilidade no portal — use "Com o endereço padrão" para medir só o crédito do CPF.',
    complemento_fora_lista: 'A unidade não está na lista do portal — use "Com o endereço padrão" para medir só o crédito do CPF.',
    rua_divergente: 'O portal resolveu outra rua (CEP com mais de uma rua) e parou antes de consultar. Abra na Cobertura e escolha a rua do cliente.',
    email_invalido: 'A Nio não aceitou este e-mail. Confira o domínio com o cliente (ex.: "@uol.com.br"), corrija e consulte de novo.',
    contato_repetido: 'A Nio não aceitou este celular (já aparece em pedidos demais). Use outro número do próprio cliente.',
    erro_receita: 'A consulta à Receita falhou. Tente de novo em alguns minutos.', erro: 'A consulta não terminou. Tente de novo em alguns minutos.' };
  const FORMA = { BOLETO: 'Boleto', CREDITO: 'Cartão de crédito', DACC: 'Débito automático', boleto: 'Boleto', cartao: 'Cartão', dacc: 'Débito automático' };
  const BIO_RES = { APROVADO: 'Aprovada', APROVADA: 'Aprovada', CONCLUIDO: 'Concluída', 'CONCLUÍDO': 'Concluída' };
  const rot = (mapa, k) => mapa[k] || [k || '—', ''];
  const dfvTxt = (k) => (!k ? '' : ((NG.DFV_ROTULO || {})[k] || [String(k).replace(/_/g, ' ')])[0]);
  const chip = ([t, c]) => `<span class="chip ${c || 'dim'}">${esc(t)}</span>`;
  const lin = (k, v) => (v ? `<div class="cc-l"><span>${esc(k)}</span><b>${v}</b></div>` : '');
  const linT = (k, v) => lin(k, v ? esc(v) : '');

  // ---------------------------------------------------------------- estilo (injetado aqui: o painel não pesa no app.css)
  function estilo() {
    if (document.getElementById('cc-estilo')) return;
    const s = document.createElement('style');
    s.id = 'cc-estilo';
    s.textContent = `
.cc-painel { position: fixed; top: 12px; right: 12px; bottom: 12px; width: min(460px, calc(100vw - 24px)); z-index: 55; display: flex; flex-direction: column; background: var(--surface); color: var(--text); border: 1px solid var(--border-strong); border-radius: 14px; box-shadow: 0 18px 48px rgba(0,0,0,.55); font-family: var(--sans); }
.cc-painel[hidden], .cc-pilula[hidden] { display: none !important; }
.cc-cab { display: flex; align-items: center; gap: 6px; padding: 10px 10px 8px 14px; border-bottom: 1px solid var(--border); }
.cc-cab h3 { margin: 0; font-size: 14px; flex: 1; letter-spacing: .2px; }
.cc-cab h3 small { color: var(--muted); font: 500 10px var(--dm); letter-spacing: 1px; text-transform: uppercase; margin-left: 6px; }
.cc-ic { width: 32px; height: 32px; border-radius: 8px; border: 1px solid var(--border); background: var(--surface-2); color: var(--text); cursor: pointer; font-size: 15px; line-height: 1; }
.cc-ic:hover { border-color: var(--border-strong); }
.cc-busca { padding: 10px 14px; border-bottom: 1px solid var(--border); display: flex; flex-direction: column; gap: 6px; }
.cc-busca input { width: 100%; box-sizing: border-box; height: 38px; padding: 0 12px; border-radius: 9px; border: 1px solid var(--border-strong); background: var(--bg); color: var(--text); font: 14px var(--sans); }
.cc-busca input:focus { outline: 2px solid var(--accent); outline-offset: -1px; }
.cc-dica { font-size: 11px; color: var(--muted); }
.cc-lista { display: flex; flex-direction: column; gap: 4px; padding: 8px 14px; overflow-y: auto; }
.cc-res { text-align: left; display: flex; flex-direction: column; gap: 2px; padding: 8px 10px; border-radius: 9px; border: 1px solid var(--border); background: var(--surface-2); color: var(--text); cursor: pointer; font: 13px var(--sans); }
.cc-res:hover, .cc-res:focus { border-color: var(--accent); outline: none; }
.cc-res span { color: var(--muted); font-size: 11px; }
.cc-cli { padding: 10px 14px; border-bottom: 1px solid var(--border); display: flex; flex-wrap: wrap; align-items: center; gap: 6px; }
.cc-cli b { font-size: 14px; }
.cc-cli .mono { font: 600 11px var(--dm); color: var(--accent); }
.cc-cli .cc-acoes { margin-left: auto; display: flex; gap: 6px; }
.cc-abas { display: flex; gap: 2px; padding: 0 10px; border-bottom: 1px solid var(--border); overflow-x: auto; }
.cc-aba { flex: 1 0 auto; padding: 9px 10px; border: 0; border-bottom: 2px solid transparent; background: none; color: var(--muted); font: 600 12px var(--sans); cursor: pointer; white-space: nowrap; }
.cc-aba[aria-selected="true"] { color: var(--text); border-bottom-color: var(--accent); }
.cc-aba i { font-style: normal; display: inline-block; width: 7px; height: 7px; border-radius: 50%; margin-left: 5px; vertical-align: 1px; background: var(--muted); }
.cc-aba i.ok { background: var(--accent); } .cc-aba i.warn { background: var(--warn-dot); } .cc-aba i.bad { background: var(--bad-dot); }
.cc-corpo { flex: 1; overflow-y: auto; padding: 12px 14px 16px; display: flex; flex-direction: column; gap: 10px; }
.cc-q { border: 1px solid var(--border); border-radius: 10px; padding: 10px 12px; display: flex; flex-direction: column; gap: 6px; background: var(--surface-dim); }
.cc-q.agora { border-color: var(--accent); background: rgba(50,224,0,.05); }
.cc-q h4 { margin: 0; font: 600 10px var(--dm); letter-spacing: 1px; text-transform: uppercase; color: var(--muted); }
.cc-l { display: flex; justify-content: space-between; gap: 10px; font-size: 13px; }
.cc-l span { color: var(--muted); } .cc-l b { text-align: right; font-weight: 600; }
.cc-aviso { font-size: 12px; padding: 8px 10px; border-radius: 8px; background: var(--surface-2); color: var(--muted); }
.cc-aviso.ok { background: var(--ok-bg); color: var(--ok-fg); } .cc-aviso.warn { background: var(--warn-bg); color: var(--warn-fg); } .cc-aviso.bad { background: var(--bad-bg); color: var(--bad-fg); }
.cc-lendo { font-size: 12px; color: var(--info-fg); background: var(--info-bg); padding: 8px 10px; border-radius: 8px; }
.cc-botoes { display: flex; flex-wrap: wrap; gap: 6px; }
.cc-form { display: grid; grid-template-columns: 1fr 1fr; gap: 6px; }
.cc-form label { display: flex; flex-direction: column; gap: 3px; font-size: 11px; color: var(--muted); }
.cc-form label.inteira { grid-column: 1 / -1; }
.cc-form label.ck { flex-direction: row; align-items: center; gap: 8px; font-size: 12px; color: var(--text); }
.cc-form input[type=text], .cc-form input[type=email], .cc-form input[type=tel] { height: 34px; padding: 0 9px; border-radius: 8px; border: 1px solid var(--border-strong); background: var(--bg); color: var(--text); font: 13px var(--sans); min-width: 0; }
.cc-passo { display: flex; flex-direction: column; gap: 5px; padding: 8px 0; border-top: 1px dashed var(--border); }
.cc-passo:first-of-type { border-top: 0; padding-top: 2px; }
.cc-passo-cab { display: flex; align-items: center; gap: 8px; }
.cc-passo-cab small { color: var(--muted); font-size: 11px; flex: 1; }
.cc-num { width: 20px; height: 20px; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center; font: 700 11px var(--dm); background: var(--surface-2); color: var(--muted); }
.cc-num.ok { background: var(--ok-bg); color: var(--ok-fg); } .cc-num.warn { background: var(--warn-bg); color: var(--warn-fg); } .cc-num.bad { background: var(--bad-bg); color: var(--bad-fg); } .cc-num.info { background: var(--info-bg); color: var(--info-fg); }
.cc-viz .chips { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 4px; }
.cc-viz .chip { cursor: pointer; border: 0; font: 600 11px var(--sans); }
.cc-novo { border-style: dashed; border-color: var(--accent); }
.cc-novo-bt { align-self: flex-start; margin-top: 6px; }
.cc-pe { padding: 8px 14px; border-top: 1px solid var(--border); font-size: 11px; color: var(--muted); }
.cc-pilula { position: fixed; left: 248px; bottom: 18px; z-index: 27; max-width: min(440px, calc(100vw - 340px)); display: inline-flex; align-items: center; gap: 8px; height: 44px; padding: 0 14px 0 12px; border-radius: 22px; border: 1px solid var(--accent); background: var(--surface); color: var(--text); font: 600 13px var(--sans); cursor: pointer; box-shadow: 0 8px 24px rgba(0,0,0,.45); }
.cc-pilula > span { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.cc-pilula small { color: var(--muted); font-weight: 500; }
.cc-pilula .cc-x { margin-left: 4px; color: var(--muted); font-size: 14px; padding: 4px; }
@media (max-width: 760px) {
  .cc-painel { top: auto; left: 0; right: 0; bottom: 0; width: auto; height: 88vh; height: 88dvh; border-radius: 16px 16px 0 0; z-index: 62; padding-bottom: env(safe-area-inset-bottom); }
  .cc-pilula { left: 12px; bottom: calc(134px + env(safe-area-inset-bottom)); max-width: calc(100vw - 24px); }
  body.mv-thread .cc-pilula { display: none !important; }
  .cc-form { grid-template-columns: 1fr; }
}`;
    document.head.appendChild(s);
  }

  // ---------------------------------------------------------------- montagem
  function montar() {
    if (raiz) return;
    estilo();
    raiz = document.createElement('div');
    raiz.id = 'cc-raiz';
    raiz.innerHTML = `
      <section class="cc-painel" role="dialog" aria-modal="false" aria-label="Consulta central" hidden>
        <div class="cc-cab"><h3>Consulta central<small>só leitura</small></h3>
          <button type="button" class="cc-ic" data-cc="min" title="Minimizar (a consulta fica guardada, mesmo trocando de tela)" aria-label="Minimizar">–</button>
          <button type="button" class="cc-ic" data-cc="fechar" title="Fechar e limpar" aria-label="Fechar">✕</button></div>
        <form class="cc-busca" data-cc-form autocomplete="off">
          <input type="search" name="q" placeholder="Nome, telefone, CPF ou L-número" aria-label="Buscar cliente" enterkeyhint="search">
          <span class="cc-dica">Ex.: Maria Silva · 32 98888-7777 · 123.456.789-09 · L-142 — ou um CEP / CPF novo, sem cliente</span>
        </form>
        <div data-cc-meio style="display:flex;flex-direction:column;flex:1;min-height:0"></div>
        <div class="cc-pe">Mostra o que está gravado. "Consultar de novo" lê na Nio pelos mesmos robôs da Cobertura e da ficha — nada aqui muda a situação do lead.</div>
      </section>
      <button type="button" class="cc-pilula" data-cc="restaurar" hidden></button>`;
    document.body.appendChild(raiz);
    painel = raiz.querySelector('.cc-painel');
    pilula = raiz.querySelector('.cc-pilula');
    const inp = painel.querySelector('input[name=q]');
    inp.value = est.q || '';
    let tm = null;
    inp.addEventListener('input', () => { clearTimeout(tm); tm = setTimeout(() => buscar(inp.value), 350); });
    painel.querySelector('[data-cc-form]').addEventListener('submit', (ev) => { ev.preventDefault(); clearTimeout(tm); buscar(inp.value, true); });
    raiz.addEventListener('click', clique);
    document.addEventListener('keydown', (ev) => { if (ev.key === 'Escape' && est.modo === 'aberto' && painel.contains(document.activeElement)) minimizar(); });
  }

  function pintarModo() {
    montar();
    painel.hidden = est.modo !== 'aberto';
    pilula.hidden = est.modo !== 'minimizado';
    if (est.modo === 'minimizado') pintarPilula();
  }
  function pintarPilula() {
    if (!pilula) return;
    const c = est.cli;
    const ocup = Object.keys(rodando).some((k) => rodando[k]) || Object.values(est.novos || {}).some((n) => n && n.job);
    const u = ultimoResultado();
    pilula.innerHTML = `<span aria-hidden="true">${ocup ? '⏳' : '⌕'}</span><span>${c ? `<b>${esc(c.avulso ? 'Dados novos' : NG.primeiroNome(c.nome || 'Cliente'))}</b>${u ? ` · ${esc(u)}` : ''}` : 'Consulta central'}</span><span class="cc-x" data-cc="fechar" title="Fechar e limpar" aria-label="Fechar a consulta">✕</span>`;
    pilula.title = 'Voltar à Consulta central';
  }
  // A frase curta da pílula: a consulta mais recente feita agora; senão, a gravada da aba aberta.
  function ultimoResultado() {
    const n = est.novos || {};
    const rec = ABAS.map(([k]) => [k, n[k]]).filter(([, x]) => x && x.em && x.txt).sort((a, b) => new Date(b[1].em) - new Date(a[1].em))[0];
    if (rec) return `${ABAS.find(([k]) => k === rec[0])[1]}: ${rec[1].txt} · ${NG.fmtHora(new Date(rec[1].em))}`;
    return est.resumo || '';
  }

  function abrir() { est.modo = 'aberto'; gravar(); pintarModo(); pintarMeio(); setTimeout(() => { const i = painel.querySelector(est.cli ? '.cc-aba[aria-selected=true]' : 'input[name=q]'); if (i) i.focus({ preventScroll: true }); }, 30); if (est.cli && !dados) carregar(); }
  function minimizar() { est.modo = 'minimizado'; gravar(); pintarModo(); }
  function fechar() { est = novoEst(); dados = null; pessoal = {}; rodando = {}; try { sessionStorage.removeItem(KEY); } catch (e) { /* */ } if (painel) { painel.querySelector('input[name=q]').value = ''; } pintarModo(); }
  function alternar() { if (est.modo === 'aberto') minimizar(); else abrir(); }

  // ---------------------------------------------------------------- busca (só leitura: v_leads + conversa/venda pelo L-número ou CPF)
  let buscaN = 0;
  async function buscar(texto, forcar) {
    const t = String(texto || '').trim();
    est.q = t; gravar();
    const minha = ++buscaN;
    const dig = NG.soDigitos(t);
    const soNum = t && /^[\d\s().+\-/]+$/.test(t);
    const mL = t.match(/^\s*L\s*-?\s*(\d{1,9})\s*$/i);
    if (!mL && !(soNum && dig.length >= 8) && t.length < 3) { if (!est.cli) { est.lista = null; gravar(); pintarMeio(); } return; }
    if (!forcar && est.cli && !mL && !soNum && t.length < 3) return;
    pintarMeio('<div class="cc-lendo">Buscando…</div>');
    const COLS = 'lead_id, conversa_id, venda_id, nome, cidade, etapa_nome, status_nome, saida_nome, ultima_em';
    let q = NG.sb.from('v_leads').select(COLS).order('ultima_em', { ascending: false, nullsFirst: false }).limit(8);
    try {
      let filtro = null;
      if (mL || (soNum && dig.length === 11 && NG.documentoValido(dig))) {
        const [rc, rv] = mL
          ? await Promise.all([NG.sb.from('mari_conversas').select('id').eq('lead_numero', Number(mL[1])).limit(5), NG.sb.from('vendas').select('id').eq('lead_numero', Number(mL[1])).limit(5)])
          : await Promise.all([NG.sb.from('mari_conversas').select('id').eq('dados->>cpf', dig).limit(5), NG.sb.from('vendas').select('id').eq('cliente_cpf_cnpj', dig).limit(5)]);
        const cs = ((rc && rc.data) || []).map((x) => x.id), vs = ((rv && rv.data) || []).map((x) => x.id);
        const partes = [cs.length && `conversa_id.in.(${cs.join(',')})`, vs.length && `venda_id.in.(${vs.join(',')})`].filter(Boolean);
        if (!mL && dig.length === 11) partes.push(`telefone.ilike.*${dig.slice(-8)}`);   // 11 dígitos pode ser celular com DDD
        if (!partes.length) { if (minha === buscaN) { est.lista = []; gravar(); pintarMeio(); } return; }
        filtro = partes.join(',');
        q = q.or(filtro);
      } else if (soNum) {
        q = q.ilike('telefone', `%${dig.slice(-8)}`);
      } else {
        q = q.ilike('nome', `%${t.replace(/[%_,()]/g, ' ').trim()}%`);
      }
      const r = await q;
      if (minha !== buscaN) return;
      if (r.error) throw r.error;
      est.lista = (r.data || []).map((x) => ({ conversa_id: x.conversa_id, venda_id: x.venda_id, nome: x.nome, cidade: x.cidade, etapa: x.saida_nome || x.status_nome || x.etapa_nome, em: x.ultima_em }));
      // Achou um só pelo L-número ou CPF: abre direto.
      if (est.lista.length === 1 && (mL || filtro)) { escolher(est.lista[0]); return; }
      est.cli = null; dados = null;
      gravar(); pintarMeio();
    } catch (err) {
      if (minha === buscaN) pintarMeio(`<div class="cc-aviso bad">A busca falhou: ${esc(NG.msgErro(err))}</div>`);
    }
  }

  function escolher(x) {
    est.cli = { conversa_id: x.conversa_id || null, venda_id: x.venda_id || null, nome: x.nome || 'Cliente' };
    est.novos = {}; est.resumo = ''; est.end = null; dados = null; pessoal = {};
    gravar(); pintarMeio(); carregar();
  }
  // 22/11 (Ricardo: "queria que ela servisse também para fazer consultas com dados novos"): consulta SEM cliente no NIOGEN —
  // viabilidade de qualquer endereço e crédito de qualquer CPF (titular autorizou), pelos mesmos robôs. OS e GED360 seguem só
  // para cliente com venda/conversa (regra 5: a Consulta OS lê só OS de venda registrada no NIOGEN).
  const vazio = () => ({ conv: null, venda: null, lead: null, os: null, ms: 0 });
  function avulso(pre) {
    pre = pre || {};
    est.cli = { avulso: true, nome: 'Dados novos' };
    est.novos = {}; est.resumo = ''; est.end = pre.end || null; est.aba = pre.aba || 'viab'; est.osNum = ''; est.osData = '';
    dados = vazio(); pessoal = { cpf: pre.cpf || '' };
    gravar(); pintarMeio();
    setTimeout(() => { const i = painel.querySelector(est.aba === 'cred' ? '[data-cc-cred] [name=celular]' : '[data-cc-end] [name=cep]'); if (i) i.focus(); }, 30);
  }

  // ---------------------------------------------------------------- o que está gravado (1 rodada paralela, ≤ 5 chamadas)
  const COLS_C = 'id, lead_numero, venda_id, telefone, cidade, cep, numero, complemento, nome_contato, cpf:dados->>cpf, email:dados->>email, dnome:dados->>nome, nio_viab_resultado, nio_viab_velocidade, nio_viab_em, nio_viab_endereco_portal, cobertura_decisao, cobertura_em, dfv_resultado, credito_resultado, credito_em, credito_origem, credito_formas, credito_endereco';
  const COLS_V = 'id, lead_numero, cliente_nome, cliente_cpf_cnpj, cliente_email, cep, numero, complemento, nio_viab_resultado, nio_viab_velocidade, nio_viab_em, nio_viab_endereco_portal, dfv_viabilidade, dfv_resultado, dfv_consultado_em, credito_resultado, credito_em, credito_origem, biometria_status, biometria_em, biometria_link_enviado_em, biometria_validada_em, nio_os, nio_os_em';
  async function carregar() {
    const c = est.cli;
    if (!c) return;
    if (c.avulso) { dados = vazio(); pintarMeio(); if (est.modo === 'minimizado') pintarPilula(); return; }
    const t0 = performance.now();
    const um = (p) => Promise.resolve(p).then((r) => (r && !r.error ? r.data : null), () => null);
    let [conv, venda, lead, os] = await Promise.all([
      c.conversa_id ? um(NG.sb.from('mari_conversas').select(COLS_C).eq('id', c.conversa_id).maybeSingle()) : null,
      c.venda_id ? um(NG.sb.from('vendas').select(COLS_V).eq('id', c.venda_id).maybeSingle()) : null,
      um(NG.sb.from('v_leads').select('etapa_nome, status_nome, saida_nome, vez, cidade').or([c.conversa_id && `conversa_id.eq.${c.conversa_id}`, c.venda_id && `venda_id.eq.${c.venda_id}`].filter(Boolean).join(',')).limit(1)),
      c.venda_id ? um(NG.sb.from('v_os_andamento').select('estado_nome, status_ordem, agendamento_data, janela, pendencia, motivo_cancelamento, mudou_em, referencia_em, acao, excecao').eq('venda_id', c.venda_id).order('mudou_em', { ascending: false }).limit(1)) : null,
    ]);
    // A conversa já virou venda (e a busca não sabia): uma rodada a mais, só aqui.
    if (!venda && conv && conv.venda_id) {
      c.venda_id = conv.venda_id; gravar();
      [venda, os] = await Promise.all([um(NG.sb.from('vendas').select(COLS_V).eq('id', c.venda_id).maybeSingle()),
        um(NG.sb.from('v_os_andamento').select('estado_nome, status_ordem, agendamento_data, janela, pendencia, motivo_cancelamento, mudou_em, referencia_em, acao, excecao').eq('venda_id', c.venda_id).order('mudou_em', { ascending: false }).limit(1))]);
    }
    if (est.cli !== c) return;
    dados = { conv, venda, lead: (lead || [])[0] || null, os: (os || [])[0] || null, ms: Math.round(performance.now() - t0) };
    const tel = NG.soDigitos((conv && conv.telefone) || '');
    pessoal = { cpf: NG.soDigitos((venda && venda.cliente_cpf_cnpj) || (conv && conv.cpf) || ''), email: (venda && venda.cliente_email) || (conv && conv.email) || '',
      celular: tel.length > 11 && tel.startsWith('55') ? tel.slice(2) : tel };
    c.lead_numero = (conv && conv.lead_numero) || (venda && venda.lead_numero) || c.lead_numero || null;
    c.nome = (venda && venda.cliente_nome) || (conv && (conv.dnome || conv.nome_contato)) || c.nome;
    est.resumo = resumoGravado();
    gravar();
    console.info(`[consulta] gravado lido em ${dados.ms} ms`);
    pintarMeio();
    if (est.modo === 'minimizado') pintarPilula();
  }
  const fonte = () => (dados && (dados.venda || dados.conv)) || {};
  function enderecoGravado() {
    const f = (dados && dados.venda && NG.soDigitos(dados.venda.cep).length === 8) ? dados.venda : (dados && dados.conv) || {};
    return { cep: NG.soDigitos(f.cep || ''), numero: String(f.numero || '').trim(), complemento: String(f.complemento || '').trim() };
  }
  // O endereço das consultas: o digitado (dados novos ou outro endereço), senão o gravado do cliente.
  function endereco() {
    const d = est.end;
    if (d && NG.soDigitos(d.cep).length === 8) return { cep: NG.soDigitos(d.cep), numero: String(d.numero || '').trim(), complemento: String(d.complemento || '').trim() };
    return enderecoGravado();
  }
  const mesmoEnd = (a, b) => a.cep === b.cep && a.numero.toLowerCase() === b.numero.toLowerCase() && a.complemento.toLowerCase() === b.complemento.toLowerCase();
  const endTexto = (e) => (e.cep.length === 8 ? `CEP ${NG.fmtCep(e.cep)}${e.numero ? ` · nº ${e.numero}` : ''}${e.complemento ? ` · ${e.complemento}` : ''}` : '');
  function resumoGravado() {
    const f = fonte();
    if (f.nio_viab_resultado) return `Viab.: ${rot(VIAB, f.nio_viab_resultado)[0]}`;
    if (f.credito_resultado) return `Crédito: ${rot(CRED, f.credito_resultado)[0]}`;
    return '';
  }

  // ---------------------------------------------------------------- desenho
  function pintarMeio(html) {
    if (!painel) return;
    const meio = painel.querySelector('[data-cc-meio]');
    if (html) { meio.innerHTML = `<div class="cc-lista">${html}</div>`; return; }
    if (!est.cli) {
      const l = est.lista;
      const dig = NG.soDigitos(est.q || '');
      const soNum = /^[\d\s().\-/]+$/.test(String(est.q || '').trim());
      const atalhos = [
        soNum && dig.length === 8 ? `<button type="button" class="cc-res cc-novo" data-cc="avulso-cep"><b>⌖ Consultar a viabilidade do CEP ${esc(NG.fmtCep(dig))}</b><span>sem cliente — endereço novo</span></button>` : '',
        soNum && dig.length === 11 && NG.documentoValido(dig) && bo() ? '<button type="button" class="cc-res cc-novo" data-cc="avulso-cpf"><b>◇ Consultar este CPF (crédito, OS ou GED360)</b><span>sem cliente no NIOGEN</span></button>' : '',
      ].join('');
      meio.innerHTML = `<div class="cc-lista">${atalhos}${l == null ? '<div class="cc-aviso">Digite o nome, o telefone, o CPF ou o L-número do cliente.</div>'
        : !l.length ? (atalhos ? '' : '<div class="cc-aviso warn">Nenhum cliente encontrado. Confira a grafia ou tente pelo telefone.</div>')
          : l.map((x, k) => `<button type="button" class="cc-res" data-cc-res="${k}"><b>${esc(x.nome || 'Sem nome')}</b><span>${esc([x.etapa, x.cidade, x.em ? haQuanto(x.em) : ''].filter(Boolean).join(' · '))}</span></button>`).join('')}
        <button type="button" class="btn btn-sm cc-novo-bt" data-cc="avulso" title="Viabilidade de qualquer endereço e crédito de qualquer CPF, sem cliente no NIOGEN">＋ Consultar dados novos (sem cliente)</button></div>`;
      return;
    }
    const c = est.cli, L = (dados && dados.lead) || {};
    const cor = { viab: corViab(), cred: corCred(), os: corOs(), bio: corBio() };
    meio.innerHTML = `
      <div class="cc-cli"><b>${esc(c.nome || 'Cliente')}</b>${c.lead_numero ? `<span class="mono">L-${esc(c.lead_numero)}</span>` : ''}
        ${c.avulso ? '<span class="chip info">sem cliente no NIOGEN</span>' : L.saida_nome || L.status_nome || L.etapa_nome ? `<span class="chip dim">${esc(L.saida_nome || L.status_nome || L.etapa_nome)}</span>` : ''}
        <span class="cc-acoes">${c.avulso ? '' : '<button type="button" class="btn btn-sm" data-cc="ficha" title="Abre a ficha deste cliente (a consulta fica minimizada)">Ficha</button>'}
        <button type="button" class="btn btn-sm btn-ghost" data-cc="trocar" title="Buscar outro cliente">Trocar</button></span></div>
      <div class="cc-abas" role="tablist">${ABAS.map(([k, n]) => `<button type="button" class="cc-aba" role="tab" data-cc-aba="${k}" aria-selected="${est.aba === k}">${n}<i class="${cor[k] || ''}"></i></button>`).join('')}</div>
      <div class="cc-corpo" role="tabpanel">${dados ? corpo(est.aba) : '<div class="cc-lendo">Lendo o que está gravado…</div>'}</div>`;
  }
  const corViab = () => { const n = (est.novos.viab || {}); const k = n.res || fonte().nio_viab_resultado; return k ? rot(VIAB, k)[1] : ''; };
  const corCred = () => { const n = (est.novos.cred || {}); const k = n.res || fonte().credito_resultado; return k ? rot(CRED, k)[1] : ''; };
  const corOs = () => { const n = est.novos.os; if (n) return n.cls; const o = dados && dados.os; return o ? (o.excecao ? 'bad' : 'ok') : ''; };
  const corBio = () => { const v = (dados && dados.venda) || {}; return v.biometria_status === 'validada' ? 'ok' : v.biometria_status === 'com_risco' ? 'bad' : v.biometria_status === 'pendente' ? 'warn' : ''; };

  function corpo(aba) {
    if (aba === 'viab') return corpoViab();
    if (aba === 'cred') return corpoCred();
    if (aba === 'os') return corpoOs();
    return corpoBio();
  }
  const soBo = '<div class="cc-aviso">Consultar na Nio daqui é só para admin e backoffice.</div>';
  const quadroAgora = (n, html) => (n && n.em ? `<div class="cc-q agora"><h4>Consultado agora · ${esc(dh(n.em))} (${esc(haQuanto(n.em))})</h4>${html}</div>` : '');

  // ----- Viabilidade
  // 22/11 (Ricardo: "O retorno da viabilidade deve mostrar o resultado tanto do DFV como do Portal" — "consultar a tela Cobertura"):
  // os dois passos da Cobertura, com os mesmos rótulos: 1 · Portal (endereço real, decide) e 2 · DFV (fachadas próximas, resgata).
  const PORTAL_ROT = (p) => ({ viavel: ['Viável', 'ok'], sem_viabilidade: p.cadastro ? ['Viabilidade parcial', 'warn'] : ['Sem viabilidade', 'bad'],
    rua_divergente: ['Outra rua', 'warn'], complemento_fora_lista: p.escolher ? ['Escolha a unidade', 'info'] : ['Unidade fora da lista', 'warn'],
    nao_encontrado: ['Endereço não encontrado', 'warn'], posse: ['Endereço já tem Nio', 'warn'] }[p.res] || (p.erro ? ['Não decidiu', 'warn'] : [p.res || '—', 'warn']));
  const DFV_MATCH = {
    exato: ['Fachada viável', 'ok', 'a fachada está na base de viáveis do painel'],
    sem_numero: ['Rua viável', 'ok', 'informe o número para conferir a fachada'],
    nao_encontrado: ['Elegível · 200 m', 'info', 'número fora da lista, mas há fachadas viáveis no CEP — confira os 200 m no mapa'],
    vazio: ['Nenhuma viável', 'bad', 'nenhuma fachada viável no CEP — confira o CEP (e o da rua vizinha) no portal'],
  };
  const passoV = (num, nome, sub, rotulo, linhas) => `<div class="cc-passo"><div class="cc-passo-cab"><span class="cc-num ${rotulo[1] || ''}">${num}</span>
      <b>${esc(nome)}</b><small>${esc(sub)}</small>${chip(rotulo)}</div>${linhas}</div>`;
  function resultadoViab(n) {
    const p = n.portal || { res: n.res, vel: n.vel, endPortal: n.endPortal, erro: n.erro };
    const pr = PORTAL_ROT(p);
    const quando = n.em ? NG.fmtHora(new Date(n.em)) : '';
    const p1 = passoV(1, 'Portal', 'endereço real · decide', pr,
      `${p.erro ? `<div class="cc-aviso warn">${esc(p.erro)}</div>` : ''}
       ${linT('Velocidade', p.vel ? `até ${p.vel}` : '')}${linT('Endereço no portal', p.endPortal)}
       ${lin('Consultado', esc(`${quando}${p.cache ? ' (cache)' : ''}`))}
       ${p.cadastro ? '<div class="cc-aviso warn">O portal pediu o <b>cadastro do endereço</b> (tratamento especial) — peça à Nio pelo formulário da Cobertura.</div>' : ''}
       ${p.escolher ? '<div class="cc-aviso warn">O portal pediu para escolher a unidade/rua. Abra na Cobertura e toque na do cliente — nunca em outra para a consulta passar.</div>' : ''}`);
    const d = n.dfvInfo;
    let p2;
    if (!d) p2 = passoV(2, 'DFV', 'fachadas próximas', ['Indisponível', 'warn'], '<div class="cc-aviso">O painel DFV não respondeu — confira no mapa da Cobertura.</div>');
    else if (d.fonte === 'base_congelada') {
      p2 = passoV(2, 'DFV', `base congelada${d.base ? ` (${d.base})` : ''}`, [d.rot, d.cor], `<div class="cc-aviso warn">Painel ao vivo fora — foto antiga. Confira no mapa da Cobertura.</div>
        ${linT('Bairro', d.onde)}${linT('HP livre', d.hp)}${linT('HCs (já com Nio)', d.hcs)}`);
    } else {
      const viz = (d.viz || []).map((x) => `<button type="button" class="chip ok" data-cc-num="${esc(x.n)}" title="Consultar este número">${esc(x.n)}${x.c ? ` · ${esc(x.c)}` : ''}${x.d ? ` · ±${x.d}` : ''}</button>`).join('');
      p2 = passoV(2, 'DFV', 'fachadas próximas', [d.rot, d.cor], `<span class="cc-dica">${esc(d.txt)}</span>
        ${d.nota200 ? `<div class="cc-aviso"><b>Regra dos 200 m:</b> ${esc(d.nota200)}</div>` : ''}
        ${linT('Rua', d.rua)}${linT('Bairro', d.bairro)}${linT('HP livre', d.hp)}${linT('HCs (já com Nio)', d.hcs)}
        ${linT('Célula', d.celula)}${linT('Faixa de crédito do bairro', d.faixa)}${linT('Classificação', d.classe)}
        ${d.unidades > 1 ? linT('Unidades viáveis nesta fachada', String(d.unidades)) : ''}
        ${viz ? `<div class="cc-viz"><span class="cc-dica">Viáveis no CEP: ${esc(String(d.total || (d.viz || []).length))} — as mais perto na numeração (toque para consultar):</span><div class="chips">${viz}</div></div>` : ''}`);
    }
    const dec = n.decisao ? `<div class="cc-aviso ${n.decisao.cor}"><b>${esc(n.decisao.rot)}.</b> ${(n.decisao.passos || []).map(esc).join(' ')}</div>` : '';
    return p1 + p2 + dec;
  }
  // Resumo do DFV que fica guardado (só dados da fachada/rua — nada do cliente).
  function resumoDfv(r, e) {
    if (!r) return null;
    if (r.fonte === 'base_congelada') {
      const x = r.rpc || {};
      const [rotu, cor] = (NG.DFV_ROTULO || {})[x.resultado] || [x.resultado || '—', 'warn'];
      return { fonte: 'base_congelada', rot: rotu, cor, base: r.particao ? NG.fmtDiaISO(r.particao).slice(0, 5) : '', onde: x.bairro || '',
        hp: x.hp_livre != null ? NG.fmtNum(x.hp_livre) : '', hcs: x.hc_tot != null ? NG.fmtNum(x.hc_tot) : '' };
    }
    const chave = r.match === 'nao_encontrado' && !r.total_fachadas_no_cep ? 'vazio' : r.match;
    const [rotu, cor, txt] = DFV_MATCH[chave] || [r.match || '—', 'warn', ''];
    const f = r.fachada || {}, regra = r.regra_200m || {};
    const alvo = parseInt(String((e && e.numero) || '').replace(/\D/g, ''), 10);
    const comp = (x) => [x.complemento, x.complemento2, x.complemento3].filter(Boolean).join(' · ');
    const viz = r.match === 'exato' ? [] : (r.fachadas_no_cep || []).map((x) => {
      const nn = parseInt(String(x.numero || '').replace(/\D/g, ''), 10);
      return { n: String(x.numero || ''), c: comp(x), d: Number.isFinite(alvo) && Number.isFinite(nn) ? Math.abs(nn - alvo) : null };
    }).filter((x) => x.n).sort((a, b) => (a.d ?? 1e9) - (b.d ?? 1e9)).slice(0, 12);
    return { fonte: 'ao_vivo', rot: rotu, cor, txt, rua: r.logradouro || '', bairro: r.bairro || '',
      hp: f.hp_livre != null ? NG.fmtNum(f.hp_livre) : '', hcs: f.hcs != null ? NG.fmtNum(f.hcs) : '', celula: r.celula || '',
      faixa: r.faixa_credito_bairro || '', classe: r.classificacao ? String(r.classificacao).toLowerCase() : '',
      nota200: regra.status && regra.status !== 'dentro' ? (regra.nota || '') : '', unidades: (r.unidades || []).length,
      viz, total: r.total_fachadas_no_cep || 0 };
  }
  function corpoViab() {
    const f = fonte(), c = (dados && dados.conv) || {}, e = endereco(), eg = enderecoGravado(), n = est.novos.viab;
    const endTxt = endTexto(eg);
    const outro = !est.cli.avulso && e.cep.length === 8 && !mesmoEnd(e, eg);
    const g = est.cli.avulso ? '' : `<div class="cc-q"><h4>Gravado no NIOGEN${f.nio_viab_em ? ` · ${esc(dh(f.nio_viab_em))}` : ''}</h4>
      ${lin('Endereço', endTxt ? esc(endTxt) : '<span class="muted">sem CEP — o lead ainda não deu o endereço</span>')}
      ${lin('Portal (oficial)', f.nio_viab_resultado ? `${chip(rot(VIAB, f.nio_viab_resultado))}${f.nio_viab_velocidade ? ` <span class="muted">${esc(f.nio_viab_velocidade)}</span>` : ''}` : '<span class="muted">não consultado</span>')}
      ${linT('Endereço no portal', f.nio_viab_endereco_portal)}
      ${linT('DFV (mapa da Nio)', dfvTxt((dados.venda && dados.venda.dfv_viabilidade) || f.dfv_resultado))}
      ${c.cobertura_decisao ? linT('Decisão da cobertura', `${String(c.cobertura_decisao).replace(/_/g, ' ')}${c.cobertura_em ? ` · ${dh(c.cobertura_em)}` : ''}`) : ''}</div>`;
    let agora = '';
    if (n && n.em) agora = quadroAgora(n, resultadoViab(n));
    const lendo = rodando.viab ? `<div class="cc-lendo">${esc(est.novos.viabFila || 'Consultando o portal… leva uns 20 segundos. Pode minimizar ou trocar de tela.')}</div>
      ${est.novos.viabDfv ? `<div class="cc-q agora"><h4>DFV já respondeu · o portal ainda está lendo</h4>${resultadoViab({ em: new Date().toISOString(), portal: { res: null, erro: '' }, dfvInfo: est.novos.viabDfv }).replace(/^[\s\S]*?(<div class="cc-passo"><div class="cc-passo-cab"><span class="cc-num[^"]*">2)/, '$1')}</div>` : ''}` : '';
    const form = `<form class="cc-q cc-form" data-cc-end autocomplete="off"><h4 style="grid-column:1/-1">${est.cli.avulso ? 'Endereço para consultar' : 'Consultar este endereço (pode trocar por outro)'}</h4>
        <label>CEP<input type="text" name="cep" inputmode="numeric" value="${esc(e.cep.length === 8 ? NG.fmtCep(e.cep) : e.cep)}" placeholder="00000-000"></label>
        <label>Número<input type="text" name="numero" value="${esc(e.numero)}" placeholder="ex.: 361 ou SN"></label>
        <label class="inteira">Complemento<input type="text" name="complemento" value="${esc(e.complemento)}" placeholder="ex.: APTO 101, CASA A, FUNDOS"></label>
        ${outro ? '<span class="cc-dica" style="grid-column:1/-1">Endereço diferente do gravado: o resultado fica só aqui — o cadastro do cliente não muda.</span>' : ''}
        <div class="cc-botoes" style="grid-column:1/-1">
          <button type="submit" class="btn btn-acc btn-sm"${rodando.viab ? ' disabled' : ''} title="Lê no portal da Nio (até a Etapa 2, sem CPF) e no DFV">⟳ ${n && n.em ? 'Consultar de novo' : 'Consultar'}</button>
          ${outro ? '<button type="button" class="btn btn-sm btn-ghost" data-cc="endgravado">Voltar ao gravado</button>' : ''}
          <button type="button" class="btn btn-sm" data-cc="cobertura" title="Abre a tela Cobertura com este endereço (mapa, unidades e formulário da Nio)">Abrir na Cobertura ↗</button></div></form>`;
    return `${lendo}${agora}${form}${g}`;
  }
  // Lê o endereço do formulário da aba; se mudou (ou é consulta sem cliente), vira est.end.
  function lerFormEnd() {
    const fm = painel && painel.querySelector('[data-cc-end]');
    if (!fm) return endereco();
    const E = fm.elements;
    const e = { cep: NG.soDigitos(E.cep.value), numero: E.numero.value.trim(), complemento: E.complemento.value.trim().toUpperCase() };
    const eg = enderecoGravado();
    est.end = (est.cli && est.cli.avulso) || !mesmoEnd(e, eg) ? e : null;
    gravar();
    return e;
  }
  async function consultarViab() {
    if (rodando.viab) return;
    const e = lerFormEnd();
    if (e.cep.length !== 8) { NG.toast('Informe o CEP com 8 dígitos.', 'bad'); const i = painel.querySelector('[data-cc-end] [name=cep]'); if (i) i.focus(); return; }
    rodando.viab = true;
    est.novos.viab = { em: null, job: null };
    pintarTudo();
    const t0 = performance.now();
    const dfvP = NG.dfvAoVivo(e).then((r) => r, () => null);
    dfvP.then((r) => { if (rodando.viab) { est.novos.viabDfv = resumoDfv(r, e); pintarTudo(); } });   // DFV na hora (≈1 s), como na Cobertura
    try {
      const s0 = await NG.viabIniciar({ ...e, opcao: '' });
      est.novos.viab.job = s0 && s0.job_id; est.novos.viab.desde = new Date().toISOString(); gravar();
      const s = await acompanhar('viab', s0, 3 * 60 * 1000, 2000);
      const r = await dfvP;
      fecharViab(s, r, e, performance.now() - t0);
    } catch (err) {
      const r = await dfvP;
      const erro = err.naoInstalado ? 'operador do portal não instalado' : NG.msgErro(err);
      est.novos.viab = { em: new Date().toISOString(), erro, txt: 'erro', portal: { erro }, dfvInfo: resumoDfv(r, e) };
      rodando.viab = false; gravar(); pintarTudo();
    }
  }
  function fecharViab(s, r, e, ms) {
    const ver = r ? NG.dfvVeredito(r) : null;
    const res = s.resultado || (s.estado === 'erro' ? 'erro' : null);
    const escolher = !['viavel', 'viavel_predio'].includes(res) && (!!(s.opcoes && s.opcoes.lista && s.opcoes.lista.length) || ['rua_divergente', 'complemento_fora_lista'].includes(res));
    let decisao = null;
    if (res === 'sem_viabilidade') { const d = NG.semViabDecisao(ver, { cadastro: !!s.cadastro_endereco }); decisao = { cor: d.cor, rot: d.rot, passos: d.passos }; }
    const eUsado = e || endereco();
    est.novos.viab = { em: s.consultado_em || new Date().toISOString(), res, vel: s.velocidade || '', endPortal: (s.endereco && s.endereco.resolvido) || '', dfv: ver, decisao, escolher,
      erro: res === 'erro' ? (s.motivo || 'erro no operador') : '', txt: rot(VIAB, res)[0],
      portal: { res, vel: s.velocidade || '', endPortal: (s.endereco && s.endereco.resolvido) || '', cache: !!s.cache, cadastro: !!s.cadastro_endereco, escolher,
        erro: res === 'erro' ? (s.motivo || 'erro no operador') : '' },
      dfvInfo: resumoDfv(r, eUsado) };
    rodando.viab = false;
    gravar(); pintarTudo();
    if (e) {
      // Mesma anotação da Cobertura (log de consulta, não muda o lead).
      try { NG.sb.rpc('operador_consulta_registrar', { p_tipo: 'viabilidade', p_dados: { ...e, resultado: res, ms: ms ? Math.round(ms) : null, detalhe: { velocidade: s.velocidade, cache: !!s.cache, motivo: s.motivo, dfv: ver, tela: 'consulta_central' } } }).then(() => {}, () => {}); } catch (_) { /* */ }
      if (r) try { NG.sb.rpc('operador_consulta_registrar', { p_tipo: 'dfv', p_dados: { ...e, resultado: ver, detalhe: { fonte: r.fonte || 'ao_vivo', match: r.match, fachadas_cep: r.total_fachadas_no_cep, tela: 'consulta_central' } } }).then(() => {}, () => {}); } catch (_) { /* */ }
    }
  }

  // ----- Crédito
  function corpoCred() {
    const f = fonte(), c = (dados && dados.conv) || {}, n = est.novos.cred;
    const formas = (c.credito_formas || []).map((x) => FORMA[x] || x);
    const g = `<div class="cc-q"><h4>Gravado no NIOGEN${f.credito_em ? ` · ${esc(dh(f.credito_em))}` : ''}</h4>
      ${lin('Resultado', f.credito_resultado ? chip(rot(CRED, f.credito_resultado)) : '<span class="muted">não consultado</span>')}
      ${linT('Formas liberadas', formas.join(', '))}
      ${linT('Quem consultou', f.credito_origem ? ({ mari: 'a Mari', tela: 'o time (tela)', extensao: 'a extensão' }[f.credito_origem] || f.credito_origem) : '')}
      ${c.credito_endereco ? linT('Endereço usado', c.credito_endereco === 'padrao' ? 'padrão (só o crédito do CPF)' : c.credito_endereco === 'cliente' ? 'do cliente' : String(c.credito_endereco)) : ''}</div>`;
    let agora = '';
    if (n && n.em) {
      const fl = (n.formas || []).map((x) => FORMA[x] || x);
      agora = quadroAgora(n, `${lin('Resultado', n.res ? chip(rot(CRED, n.res)) : '')}${linT('Formas liberadas', fl.join(', '))}
        ${linT('Endereço usado', n.padrao ? 'padrão (só o crédito do CPF)' : 'do cliente')}
        ${n.erro ? `<div class="cc-aviso bad">${esc(n.erro)}</div>` : CRED_TXT[n.res] ? `<div class="cc-aviso ${rot(CRED, n.res)[1]}">${esc(CRED_TXT[n.res])}</div>` : ''}
        ${n.popup ? `<div class="cc-aviso">O portal respondeu: “${esc(n.popup)}”</div>` : ''}`);
    }
    const lendo = rodando.cred ? `<div class="cc-lendo">${esc(est.novos.credFila || 'Consultando o crédito no portal… leva de 30 s a 2 min. Pode minimizar ou trocar de tela.')}</div>` : '';
    if (!bo()) return `${agora}${g}${soBo}`;
    const p = pessoal, e = endereco();
    const fmtCpf = (d) => (d.length === 11 ? `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6, 9)}-${d.slice(9)}` : d);
    return `${lendo}${agora}${g}
      <form class="cc-q cc-form" data-cc-cred autocomplete="off"><h4 style="grid-column:1/-1">Consultar de novo no portal</h4>
        <label>CPF do titular<input type="text" name="cpf" inputmode="numeric" value="${esc(fmtCpf(p.cpf || ''))}"></label>
        <label>Celular (DDD)<input type="tel" name="celular" inputmode="numeric" value="${esc(p.celular || '')}"></label>
        <label class="inteira">E-mail<input type="email" name="email" value="${esc(p.email || '')}"></label>
        <label class="ck inteira"><input type="checkbox" name="autorizado"> O titular autorizou a consulta de crédito</label>
        <div class="cc-botoes inteira" style="grid-column:1/-1">
          <span class="cc-dica" style="flex-basis:100%">${e.cep.length === 8 ? `Endereço: ${esc(endTexto(e))} (o da aba Viabilidade)` : 'Sem endereço: preencha na aba Viabilidade ou use o endereço padrão.'}</span>
          <button type="submit" class="btn btn-acc btn-sm"${rodando.cred ? ' disabled' : ''}${e.cep.length !== 8 ? ' title="Sem CEP: use o endereço padrão"' : ''}>⟳ Consultar crédito</button>
          <button type="button" class="btn btn-sm" data-cc="credpadrao"${rodando.cred ? ' disabled' : ''} title="Mede só o crédito do CPF, num endereço padrão (não diz nada da viabilidade do cliente)">Com o endereço padrão</button></div>
      </form>`;
  }
  async function consultarCred(padrao) {
    if (rodando.cred) return;
    const fm = painel.querySelector('[data-cc-cred]');
    if (!fm) return;
    const E = fm.elements;
    const d = { cpf: NG.soDigitos(E.cpf.value), autorizado: E.autorizado.checked, contato: { celular: NG.soDigitos(E.celular.value), email: E.email.value.trim() } };
    if (!d.autorizado) { NG.toast('Marque que o titular autorizou a consulta.', 'bad'); E.autorizado.focus(); return; }
    if (!NG.documentoValido(d.cpf) || d.cpf.length !== 11) { NG.toast('CPF inválido — confira os dígitos.', 'bad'); E.cpf.focus(); return; }
    if (![10, 11].includes(d.contato.celular.length)) { NG.toast('Informe o celular do cliente com DDD.', 'bad'); E.celular.focus(); return; }
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(d.contato.email)) { NG.toast('Informe o e-mail do cliente.', 'bad'); E.email.focus(); return; }
    const e = endereco();
    if (!padrao) {
      if (e.cep.length !== 8) { NG.toast('O lead não tem CEP: use "Com o endereço padrão".', 'bad'); return; }
      d.endereco = { ...e, opcao: '' };
    }
    pessoal = { cpf: d.cpf, celular: d.contato.celular, email: d.contato.email };
    rodando.cred = true;
    est.novos.cred = { em: null, job: null, padrao: !!padrao };
    pintarTudo();
    try {
      const s0 = await NG.creditoIniciar(d);
      est.novos.cred.job = s0 && s0.job_id; est.novos.cred.desde = new Date().toISOString(); gravar();
      const s = await acompanhar('cred', s0, 4 * 60 * 1000, 3000);
      fecharCred(s, !!padrao, padrao ? null : d.endereco);
    } catch (err) {
      est.novos.cred = { em: new Date().toISOString(), erro: err.naoInstalado ? 'Operador de crédito fora do ar — consulte direto no portal.' : `consulta de crédito indisponível: ${NG.msgErro(err)}`, txt: 'erro', padrao: !!padrao };
      rodando.cred = false; gravar(); pintarTudo();
    }
  }
  function fecharCred(s, padrao, end) {
    const popup = s.popup && (s.popup.texto || s.popup.titulo) ? [s.popup.titulo, s.popup.texto].filter(Boolean).join(' — ').replace(/\s+Ok\s*$/i, '') : '';
    est.novos.cred = { em: s.consultado_em || new Date().toISOString(), res: s.resultado, formas: s.formas_liberadas || [], padrao, popup: popup.slice(0, 240),
      erro: s.estado === 'erro' && !s.resultado ? (s.motivo || 'erro no operador') : '', txt: rot(CRED, s.resultado)[0] };
    rodando.cred = false;
    gravar(); pintarTudo();
    try { NG.sb.rpc('operador_consulta_registrar', { p_tipo: 'credito', p_dados: { ...(end || {}), resultado: s.resultado, ms: s.ms || null, cpf_mascara: s.cpf_mascara || null, detalhe: { formas: s.formas_liberadas || null, padrao, cache: !!s.cache, tela: 'consulta_central' } } }).then(() => {}, () => {}); } catch (_) { /* */ }
  }

  // Acompanha um job do operador (viabilidade ou crédito) até 'pronto'/'erro'. Volta a acompanhar depois de trocar de página.
  async function acompanhar(aba, s, limite, passo) {
    const fim = Date.now() + limite;
    while (s && !['pronto', 'erro'].includes(s.estado)) {
      if (Date.now() > fim) throw new Error('o portal demorou demais — tente de novo em alguns minutos');
      est.novos[`${aba}Fila`] = s.posicao_fila > 0 ? `Na fila do robô (${s.posicao_fila}º). Pode minimizar ou trocar de tela.` : '';
      if (est.modo === 'minimizado') pintarPilula();
      await pausa(passo);
      s = await NG.creditoStatus(s.job_id);
    }
    delete est.novos[`${aba}Fila`]; delete est.novos.viabDfv;
    return s || {};
  }
  async function retomarJobs() {
    for (const aba of ['viab', 'cred']) {
      const n = est.novos[aba];
      if (!n || !n.job || n.em) continue;
      if (Date.now() - new Date(n.desde || 0) > 5 * 60 * 1000) { delete est.novos[aba]; gravar(); continue; }
      rodando[aba] = true;
      pintarTudo();
      try {
        const s = await acompanhar(aba, { estado: 'fila', job_id: n.job }, 4 * 60 * 1000, aba === 'viab' ? 2000 : 3000);
        if (aba === 'viab') { const e = endereco(); const r = e.cep.length === 8 ? await NG.dfvAoVivo(e).catch(() => null) : null; fecharViab(s, r, null, null); } else fecharCred(s, !!n.padrao, null);
      } catch (err) {
        est.novos[aba] = { em: new Date().toISOString(), erro: NG.msgErro(err), txt: 'erro' };
        rodando[aba] = false; gravar(); pintarTudo();
      }
    }
  }

  // ----- OS
  function corpoOs() {
    const v = (dados && dados.venda) || null, o = (dados && dados.os) || null, n = est.novos.os;
    if (!v) return corpoOsDigitado();
    const dataBR = (iso) => { const m = String(iso || '').match(/^(\d{4})-(\d{2})-(\d{2})/); return m ? `${m[3]}/${m[2]}/${m[1]}` : ''; };
    const g = `<div class="cc-q"><h4>Última leitura guardada${o && o.mudou_em ? ` · ${esc(dh(o.mudou_em))}` : ''}</h4>
      ${linT('Nº da OS', v.nio_os)}${linT('Aberta em', v.nio_os_em ? dh(v.nio_os_em) : '')}
      ${o ? `${linT('Estado', o.estado_nome)}${linT('Status na Nio', o.status_ordem)}${linT('Agendamento', [dataBR(o.agendamento_data), o.janela].filter(Boolean).join(' · '))}
        ${linT('Pendência', o.pendencia)}${linT('Motivo do cancelamento', o.motivo_cancelamento)}${o.excecao && o.acao ? `<div class="cc-aviso bad"><b>O que fazer:</b> ${esc(o.acao)}</div>` : ''}`
        : `<div class="cc-aviso">${v.nio_os ? 'Nenhuma leitura da OS guardada ainda.' : 'Sem nº de OS na venda: a OS ainda não foi aberta no portal.'}</div>`}</div>`;
    const agora = n && n.em ? quadroAgora(n, `<div class="cc-aviso ${n.cls}">${esc(n.txt)}</div>${(n.linhas || []).map(([k, x]) => linT(k, x)).join('')}`) : '';
    const lendo = rodando.os ? '<div class="cc-lendo">Lendo a OS na Nio… leva uns 15 segundos. Pode minimizar: a leitura termina e fica gravada.</div>' : '';
    if (!bo()) return `${agora}${g}${soBo}`;
    return `${lendo}${agora}${g}<div class="cc-botoes"><button type="button" class="btn btn-acc btn-sm" data-cc="os"${rodando.os ? ' disabled' : ''} title="O robô lê o andamento na Consulta OS do portal (só filtra e lê)">⟳ Ler a OS na Nio agora</button></div>`;
  }
  // 22/11 (Ricardo: "Libera a OS e o GED360 com dados digitados"): sem venda no NIOGEN, a leitura vai com CPF/CNPJ e nº da OS
  // digitados (edge credito-consulta, acao 'os' sem venda_id). Só lê: nada é gravado. O nº da OS fica no storage; o CPF nunca.
  const fmtDoc = (d) => (d.length === 11 ? `${d.slice(0, 3)}.${d.slice(3, 6)}.${d.slice(6, 9)}-${d.slice(9)}` : d);
  function corpoOsDigitado() {
    const n = est.novos.os;
    const agora = n && n.em ? quadroAgora(n, `<div class="cc-aviso ${n.cls}">${esc(n.txt)}</div>${(n.linhas || []).map(([k, x]) => linT(k, x)).join('')}`) : '';
    const lendo = rodando.os ? '<div class="cc-lendo">Lendo a OS na Nio… leva uns 15 segundos. Pode minimizar.</div>' : '';
    if (!bo()) return `${agora}${soBo}`;
    return `${lendo}${agora}<form class="cc-q cc-form" data-cc-os autocomplete="off"><h4 style="grid-column:1/-1">${est.cli.avulso ? 'Ler uma OS na Nio' : 'Sem venda no NIOGEN — ler uma OS pelos dados'}</h4>
        <label>CPF ou CNPJ do titular<input type="text" name="cpf" inputmode="numeric" value="${esc(fmtDoc(pessoal.cpf || ''))}"></label>
        <label>Nº da OS (8 dígitos)<input type="text" name="os" inputmode="numeric" maxlength="10" value="${esc(est.osNum || '')}"></label>
        <label class="inteira">Pedido feito em (se tiver mais de 25 dias)<input type="date" name="criada" value="${esc(est.osData || '')}"></label>
        <span class="cc-dica" style="grid-column:1/-1">Só lê o andamento na Consulta OS do portal. Nada é gravado no NIOGEN.</span>
        <div class="cc-botoes" style="grid-column:1/-1"><button type="submit" class="btn btn-acc btn-sm"${rodando.os ? ' disabled' : ''}>⟳ Ler a OS na Nio</button></div></form>`;
  }
  async function consultarOsDigitado() {
    if (rodando.os) return;
    const fm = painel.querySelector('[data-cc-os]');
    if (!fm) return;
    const E = fm.elements;
    const doc = NG.soDigitos(E.cpf.value), num = NG.soDigitos(E.os.value), criada = E.criada.value || '';
    if (!(doc.length === 14 || (doc.length === 11 && NG.documentoValido(doc)))) { NG.toast('CPF ou CNPJ inválido — confira os dígitos.', 'bad'); E.cpf.focus(); return; }
    if (num.length !== 8) { NG.toast('O número da OS tem 8 dígitos.', 'bad'); E.os.focus(); return; }
    pessoal.cpf = doc; est.osNum = num; est.osData = criada;
    rodando.os = true; gravar(); pintarTudo();
    const fn = async (corpo) => {
      const { data, error } = await NG.sb.functions.invoke('credito-consulta', { body: corpo });
      if (error) { let m = error.message; try { const c = await error.context.json(); if (c && c.error) m = c.error; } catch (_) { /* */ } throw new Error(m); }
      return data;
    };
    try {
      let s2 = await fn({ acao: 'os', cpf: doc, os: num, criada_em: criada });
      const fim = Date.now() + 90 * 1000;
      while (s2 && !['pronto', 'erro'].includes(s2.estado)) {
        if (Date.now() > fim) throw new Error('O portal demorou demais. Tente de novo em 1 minuto.');
        await pausa(3000);
        s2 = await fn({ acao: 'os_status', job_id: s2.job_id, os: num });
      }
      const r = NG.osResumo(s2), l = s2.leitura || {};
      est.novos.os = { em: s2.consultado_em || new Date().toISOString(), txt: r.txt, cls: r.cls,
        linhas: s2.resultado === 'lida' ? [['Nº da OS', num], ['Status na Nio', l.status_ordem], ['Agendamento', l.agendamento], ['Situação do agendamento', l.status_agendamento], ['Pendência', l.pendencia], ['Caso aberto na Nio', l.caso], ['Motivo do cancelamento', l.motivo_cancelamento]].filter(([, x]) => x) : [] };
    } catch (err) {
      est.novos.os = { em: new Date().toISOString(), cls: 'bad', txt: NG.msgErro(err) };
    }
    rodando.os = false; gravar(); pintarTudo();
  }
  async function consultarOs() {
    const v = dados && dados.venda;
    if (!v || rodando.os) return;
    rodando.os = true; pintarTudo();
    try {
      const s = await NG.osConsultar(v.id);
      const r = NG.osResumo(s), l = s.leitura || {};
      est.novos.os = { em: s.consultado_em || new Date().toISOString(), txt: r.txt, cls: r.cls,
        linhas: s.resultado === 'lida' ? [['Status na Nio', l.status_ordem], ['Agendamento', l.agendamento], ['Situação do agendamento', l.status_agendamento], ['Pendência', l.pendencia], ['Caso aberto na Nio', l.caso], ['Motivo do cancelamento', l.motivo_cancelamento]].filter(([, x]) => x) : [] };
      est.novos.os.txt = r.txt;
    } catch (err) {
      est.novos.os = { em: new Date().toISOString(), cls: 'bad', txt: err.naoInstalado ? 'Operador fora do ar — consulte direto no portal.' : NG.msgErro(err) };
    }
    rodando.os = false; gravar();
    await carregar();   // a leitura que mudou já foi gravada pela função do banco: relê o guardado
    pintarTudo();
  }

  // ----- GED360 (biometria)
  function corpoBio() {
    const v = (dados && dados.venda) || null, n = est.novos.bio;
    const digitar = !v && (est.cli.avulso || !pessoal.cpf);   // 22/11: sem venda e sem CPF guardado → CPF digitado
    const g = v ? `<div class="cc-q"><h4>Gravado na venda${v.biometria_em ? ` · ${esc(dh(v.biometria_em))}` : ''}</h4>
        ${lin('Biometria', v.biometria_status ? chip([NG.BIOMETRIA[v.biometria_status] || v.biometria_status, corBio()]) : '<span class="muted">—</span>')}
        ${linT('Link da Nio enviado', v.biometria_link_enviado_em ? dh(v.biometria_link_enviado_em) : '')}${linT('Validada em', v.biometria_validada_em ? dh(v.biometria_validada_em) : '')}</div>`
      : digitar ? '' : '<div class="cc-aviso">Ainda sem venda no NIOGEN: a leitura no GED360 vai pelo CPF da conversa.</div>';
    const agora = n && n.em ? quadroAgora(n, `${n.erro ? `<div class="cc-aviso bad">${esc(n.erro)}</div>` : ''}${(n.lista || []).map((b) => `<div class="cc-q${b.casada ? '' : ''}"><h4>Protocolo ${esc(b.protocolo || '—')}${b.casada || n.digitado ? '' : ' · ainda não casado com a venda'}</h4>
        ${linT('Resultado no GED360', BIO_RES[String(b.resultado || '').toUpperCase()] || b.resultado || 'sem resultado ainda')}${linT('Enviada em', b.envio ? dh(b.envio) : '')}${linT('Conferida em', b.conf ? dh(b.conf) : '')}
        ${b.alerta ? `<div class="cc-aviso warn">${esc(b.alerta)}</div>` : ''}</div>`).join('')}
        ${!n.erro && !(n.lista || []).length ? '<div class="cc-aviso warn">O GED360 não tem biometria com este CPF (últimos 15 dias). Se o cliente diz que já fez, peça o print e confira o CPF.</div>' : ''}
        ${n.status ? `<div class="cc-aviso">Na venda: <b>${esc(NG.BIOMETRIA[n.status] || n.status)}</b>${n.mudou ? ' — mudou agora' : ''}</div>` : ''}`) : '';
    const lendo = rodando.bio ? '<div class="cc-lendo">Lendo no GED360… leva uns 10 segundos. Pode minimizar: a leitura termina e fica gravada.</div>' : '';
    if (!bo()) return `${agora}${g}${soBo}`;
    if (digitar) {
      return `${lendo}${agora}<form class="cc-q cc-form" data-cc-bio autocomplete="off"><h4 style="grid-column:1/-1">Ler a biometria no GED360 pelo CPF</h4>
        <label class="inteira">CPF ou CNPJ do titular<input type="text" name="cpf" inputmode="numeric" value="${esc(fmtDoc(pessoal.cpf || ''))}"></label>
        <span class="cc-dica" style="grid-column:1/-1">O robô lê o Relatório Detalhado do GED360 (últimos 15 dias) e mostra as biometrias deste CPF. Nada é gravado.</span>
        <div class="cc-botoes" style="grid-column:1/-1"><button type="submit" class="btn btn-acc btn-sm"${rodando.bio ? ' disabled' : ''}>⟳ Ler no GED360</button></div></form>`;
    }
    const pode = (v && v.id) || (est.cli.conversa_id && pessoal.cpf);
    return `${lendo}${agora}${g}<div class="cc-botoes"><button type="button" class="btn btn-acc btn-sm" data-cc="bio"${rodando.bio || !pode ? ' disabled' : ''} title="${pode ? 'O robô lê o Relatório Detalhado do GED360 (só leitura)' : 'Sem venda e sem CPF na conversa: não dá para procurar no GED360'}">⟳ Ler no GED360 agora</button></div>`;
  }
  async function consultarBio() {
    const v = dados && dados.venda;
    if (rodando.bio) return;
    let corpoReq = v ? { acao: 'bio', venda_id: v.id } : { acao: 'bio', conversa_id: est.cli.conversa_id };
    const fmBio = !v && painel.querySelector('[data-cc-bio]');
    if (fmBio) {
      const doc = NG.soDigitos(fmBio.elements.cpf.value);
      if (!(doc.length === 14 || (doc.length === 11 && NG.documentoValido(doc)))) { NG.toast('CPF ou CNPJ inválido — confira os dígitos.', 'bad'); fmBio.elements.cpf.focus(); return; }
      pessoal.cpf = doc;
      corpoReq = { acao: 'bio', cpf: doc };
    }
    rodando.bio = true; pintarTudo();
    const antes = v ? v.biometria_status : null;
    try {
      // O mesmo caminho do degrau Biometria da ficha (NG.bioModal): edge credito-consulta, acao 'bio'.
      const { data: r, error } = await NG.sb.functions.invoke('credito-consulta', { body: corpoReq });
      if (error) { let m = error.message; try { const c = await error.context.json(); if (c && c.error) m = c.error; } catch (_) { /* */ } throw new Error(m); }
      const st = (r.venda || {}).biometria_status || null;
      est.novos.bio = { em: new Date().toISOString(), erro: r.erro ? `${r.erro}${/simult/i.test(r.erro) ? ' — alguém está no GED360 com o login do robô: saia e tente em 1 minuto' : ''} · mostrando a última leitura guardada.` : '',
        lista: (r.biometrias || []).map((b) => ({ protocolo: b.protocolo, resultado: b.resultado, envio: b.data_envio, conf: b.data_conferencia, alerta: b.alerta, casada: b.casada })),
        digitado: !!fmBio, status: st, mudou: !!(st && antes && st !== antes), txt: st ? (NG.BIOMETRIA[st] || st) : ((r.biometrias || []).length ? 'lida' : 'sem biometria') };
    } catch (err) {
      est.novos.bio = { em: new Date().toISOString(), erro: NG.msgErro(err), txt: 'erro' };
    }
    rodando.bio = false; gravar();
    if (v) await carregar();
    pintarTudo();
  }

  function pintarTudo() { if (est.modo === 'aberto') pintarMeio(); else if (est.modo === 'minimizado') pintarPilula(); }

  // ---------------------------------------------------------------- cliques
  function clique(ev) {
    const res = ev.target.closest('[data-cc-res]');
    if (res) { escolher(est.lista[Number(res.dataset.ccRes)]); return; }
    const num = ev.target.closest('[data-cc-num]');
    if (num) { const fm = painel.querySelector('[data-cc-end]'); if (fm) { fm.elements.numero.value = num.dataset.ccNum; fm.elements.complemento.value = ''; consultarViab(); } return; }
    const aba = ev.target.closest('[data-cc-aba]');
    if (aba) { est.aba = aba.dataset.ccAba; gravar(); pintarMeio(); const b = painel.querySelector(`[data-cc-aba="${est.aba}"]`); if (b) b.focus(); return; }
    const b = ev.target.closest('[data-cc]');
    if (!b) return;
    const a = b.dataset.cc;
    if (a === 'fechar') { ev.stopPropagation(); fechar(); return; }
    if (a === 'restaurar') { abrir(); return; }
    if (a === 'min') { minimizar(); return; }
    if (a === 'avulso') { avulso(); return; }
    if (a === 'avulso-cep') { avulso({ end: { cep: NG.soDigitos(est.q), numero: '', complemento: '' } }); return; }
    if (a === 'avulso-cpf') { avulso({ cpf: NG.soDigitos(est.q), aba: 'cred' }); return; }
    if (a === 'endgravado') { est.end = null; gravar(); pintarMeio(); return; }
    if (a === 'trocar') { est.cli = null; dados = null; pessoal = {}; est.novos = {}; est.resumo = ''; est.end = null; gravar(); pintarMeio(); const i = painel.querySelector('input[name=q]'); i.focus(); i.select(); if (est.q) buscar(est.q, true); return; }
    if (a === 'ficha') { abrirFicha(); return; }
    if (a === 'cobertura') { abrirCobertura(); return; }
    if (a === 'viab') { consultarViab(); return; }
    if (a === 'credpadrao') { consultarCred(true); return; }
    if (a === 'os') { consultarOs(); return; }
    if (a === 'bio') consultarBio();
  }
  document.addEventListener('submit', (ev) => {
    if (!ev.target.matches) return;
    if (ev.target.matches('[data-cc-cred]')) { ev.preventDefault(); consultarCred(false); }
    else if (ev.target.matches('[data-cc-end]')) { ev.preventDefault(); consultarViab(); }
    else if (ev.target.matches('[data-cc-os]')) { ev.preventDefault(); consultarOsDigitado(); }
    else if (ev.target.matches('[data-cc-bio]')) { ev.preventDefault(); consultarBio(); }
  });

  // Cobertura com o endereço da aba (digitado ou gravado). Cliente sem endereço trocado: o atalho de sempre (leva o CPF junto).
  // Endereço novo: a mesma chave de uso único que a Cobertura já lê (niogen.cobertura.lead, 2 min) — nada na URL.
  function abrirCobertura() {
    const e = lerFormEnd();
    if (!est.cli.avulso && !est.end) { NG.consultarOperador({ vendaId: est.cli.venda_id, conversaId: est.cli.conversa_id }); return; }
    try { localStorage.setItem('niogen.cobertura.lead', JSON.stringify({ cep: e.cep, numero: e.numero, complemento: e.complemento, em: Date.now() })); } catch (_) { /* */ }
    const aba = window.open('cobertura.html#lead', '_blank');
    if (!aba) location.href = 'cobertura.html#lead';
  }
  function abrirFicha() {
    const c = est.cli;
    if (!c) return;
    const h = c.venda_id ? `#venda=${c.venda_id}` : `#conversa=${c.conversa_id}`;
    minimizar();
    if (window.NGFicha) location.hash = h;
    else location.href = `leads.html${h}`;
  }

  // ---------------------------------------------------------------- início: volta como estava (outra página da mesma aba)
  function iniciar() {
    montar();
    pintarModo();
    if (est.modo === 'aberto') { pintarMeio(); if (est.cli) carregar(); }
    else if (est.modo === 'minimizado' && est.cli) carregar();   // relê o gravado para a pílula e para abrir já pronto
    retomarJobs();
  }

  // 22/11 (Ricardo: "acrescenta o botão Consulta na Ficha do cliente"): a lupa da ficha abre a Consulta já neste cliente
  // (mesmo cliente já aberto: só mostra o painel, sem perder as consultas feitas agora).
  function abrirCliente(x) {
    const c = est.cli;
    const mesmo = c && !c.avulso && x && ((x.venda_id && c.venda_id === x.venda_id) || (x.conversa_id && c.conversa_id === x.conversa_id));
    if (mesmo || !x || !(x.venda_id || x.conversa_id)) { abrir(); return; }
    est.modo = 'aberto'; pintarModo(); escolher(x);
  }

  window.NGConsulta = { abrir, abrirCliente, minimizar, fechar, alternar, iniciar, estado: () => est.modo };
  iniciar();
})();
