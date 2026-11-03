/* NIOGEN | docs/assets/app.js | 03/11/2026
 * Cliente Supabase, sessão, rótulos do funil, formatação e componentes comuns (toast, modais).
 * Depende de: config.js (window.NIOGEN_CONFIG) e supabase-js v2 (window.supabase), carregados antes.
 */
(function () {
  'use strict';

  // Limpa BOM, espaço e quebra de linha que um secret mal gravado deixa na chave (vira erro de header no fetch).
  const limpa = (s) => String(s || '').replace(/[^\x21-\x7E]/g, '');
  const cfg = { supabaseUrl: limpa((window.NIOGEN_CONFIG || {}).supabaseUrl), supabaseAnonKey: limpa((window.NIOGEN_CONFIG || {}).supabaseAnonKey) };
  if (!cfg.supabaseUrl || !cfg.supabaseAnonKey) {
    document.addEventListener('DOMContentLoaded', () => {
      document.body.innerHTML = '<div class="login"><div class="login-box"><strong>config.js ausente</strong>' +
        '<span class="painel-sub">Copie docs/config.example.js para docs/config.js e preencha a URL e a chave anon do Supabase Nio.</span></div></div>';
    });
    throw new Error('NIOGEN: config.js ausente');
  }

  const sb = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey, {
    auth: { persistSession: true, autoRefreshToken: true },
  });

  const TZ = 'America/Sao_Paulo';

  const STATUS = [
    { id: '0_qualificado', curto: '0 · Qualificado', col: '0 · Qualificado (Mari)', chip: 'info' },
    { id: '1_vendido', curto: '1 · Vendido', col: '1 · Vendido', chip: '' },
    { id: '2_aguardando_instalacao', curto: '2 · Aguardando', col: '2 · Aguardando instalação', chip: '' },
    { id: '3_instalado', curto: '3 · Instalado', col: '3 · Instalado', chip: '' },
    // Os ids são do banco e não mudam; só o texto ("em risco" / "ganha", decisão do Ricardo 03/11).
    { id: '4_ativo_provisorio', curto: '4 · Ativo', col: '4 · Ativo · comissão em risco', chip: 'ok', dica: 'emRisco' },
    { id: '5_comissao_firme', curto: '5 · Comissão ganha', col: '5 · Comissão ganha', chip: 'ok', dica: 'ganha' },
    { id: 'saida', curto: 'Saída', col: 'Saída · motivo obrigatório', chip: 'dim' },
  ];
  const STATUS_MAP = Object.fromEntries(STATUS.map((s) => [s.id, s]));

  const ORIGENS = {
    meta_ads: 'Meta Ads · Mari', fila_vero: 'Fila Vero', rua: 'Rua / PAP',
    indicacao: 'Indicação', site: 'Site', outro: 'Evento / outro',
  };
  const FORMAS = { boleto: 'Boleto', cartao: 'Cartão', dacc: 'DACC' };
  const SEGMENTOS = { PF: 'PF · Varejo', MEI: 'PJ · MEI', NMEI: 'PJ · NMEI' };
  const BIOMETRIA = { agendada: 'agendada', aprovada: 'aprovada', reprovada: 'reprovada' };
  const PERFIS = { admin: 'Admin', vendedor: 'Vendedor', backoffice: 'Backoffice' };

  const MOTIVOS_SAIDA = [
    'Sem cobertura', 'Já é cliente Nio', 'Concorrente', 'Preço', 'Sem contato (cadência esgotada)',
    'Desistiu', 'Reprovado na biometria', 'Fora da área', 'Interesse futuro (com data)',
  ];

  // ---------- formatação ----------
  const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const dt = (v) => (v ? new Date(v) : null);
  const parts = (d, opts) => new Intl.DateTimeFormat('pt-BR', { timeZone: TZ, ...opts }).format(d);
  const fmtData = (v) => (v ? parts(dt(v), { day: '2-digit', month: '2-digit' }) : '—');
  const fmtDataAno = (v) => (v ? parts(dt(v), { day: '2-digit', month: '2-digit', year: 'numeric' }) : '—');
  const fmtHora = (v) => (v ? parts(dt(v), { hour: '2-digit', minute: '2-digit' }) : '—');
  const fmtDataHora = (v) => (v ? `${fmtData(v)} ${fmtHora(v)}` : '—');
  const fmtDiaSemana = (v) => (v ? parts(dt(v), { weekday: 'short' }).replace('.', '') : '');
  const fmtMoeda = (v) => (v == null ? '—'
    : 'R$ ' + Number(v).toLocaleString('pt-BR', { minimumFractionDigits: Number(v) % 1 ? 2 : 0, maximumFractionDigits: 2 }));
  // Coluna date do banco (AAAA-MM-DD) → DD/MM/AAAA, sem passar por Date (evita virar o dia anterior no fuso).
  const fmtDiaISO = (v) => (v ? String(v).slice(0, 10).split('-').reverse().join('/') : '—');
  const fmtNum = (v) => (v == null ? '—' : Number(v).toLocaleString('pt-BR', { maximumFractionDigits: 0 }));
  const fmtHoras = (h) => {
    if (h == null) return '—';
    const t = Math.max(0, Math.round(Number(h) * 60));
    return `${Math.floor(t / 60)}h${String(t % 60).padStart(2, '0')}`;
  };
  // Data (AAAA-MM-DD) no fuso de São Paulo.
  const diaSP = (v) => parts(v ? dt(v) : new Date(), { year: 'numeric', month: '2-digit', day: '2-digit' }).split('/').reverse().join('-');
  const diasEntre = (a, b) => Math.floor((dt(b) - dt(a)) / 86400000);
  // Janela de instalação: o horário gravado indica o período (antes do meio-dia = manhã).
  const janela = (v) => (v ? (Number(parts(dt(v), { hour: '2-digit', hour12: false })) < 12 ? '8–12h' : '13–17h') : '');
  const primeiroNome = (nome) => {
    const p = String(nome || '').trim().split(/\s+/);
    return p.length > 1 ? `${p[0]} ${p[p.length - 1][0]}.` : p[0] || '—';
  };

  // ---------- validação ----------
  function cpfValido(cpf) {
    const s = cpf.replace(/\D/g, '');
    if (s.length !== 11 || /^(\d)\1+$/.test(s)) return false;
    let d = 0;
    for (let i = 0; i < 9; i++) d += Number(s[i]) * (10 - i);
    d = (d * 10) % 11 % 10;
    if (d !== Number(s[9])) return false;
    d = 0;
    for (let i = 0; i < 10; i++) d += Number(s[i]) * (11 - i);
    d = (d * 10) % 11 % 10;
    return d === Number(s[10]);
  }
  function cnpjValido(cnpj) {
    const s = cnpj.replace(/\D/g, '');
    if (s.length !== 14 || /^(\d)\1+$/.test(s)) return false;
    const calc = (len) => {
      const pesos = len === 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
      const soma = pesos.reduce((acc, p, i) => acc + Number(s[i]) * p, 0);
      const r = soma % 11;
      return r < 2 ? 0 : 11 - r;
    };
    return calc(12) === Number(s[12]) && calc(13) === Number(s[13]);
  }
  const documentoValido = (v) => {
    const n = String(v || '').replace(/\D/g, '');
    return n.length === 11 ? cpfValido(n) : n.length === 14 ? cnpjValido(n) : false;
  };
  const soDigitos = (v) => String(v || '').replace(/\D/g, '');

  // ---------- erros e toasts ----------
  function msgErro(e) {
    if (!e) return 'Erro desconhecido';
    const m = e.message || String(e);
    if (/duplicate key.*nio_pedido/i.test(m)) return 'Esse nº de pedido já está em outra venda.';
    if (/row-level security/i.test(m)) return 'Sem permissão para essa venda.';
    return m;
  }
  function toast(texto, tipo) {
    let box = document.querySelector('.toasts');
    if (!box) {
      box = document.createElement('div');
      box.className = 'toasts';
      box.setAttribute('role', 'status');
      box.setAttribute('aria-live', 'polite');
      document.body.appendChild(box);
    }
    const el = document.createElement('div');
    el.className = 'toast' + (tipo ? ' ' + tipo : '');
    el.textContent = texto;
    box.appendChild(el);
    setTimeout(() => el.remove(), tipo === 'bad' ? 7000 : 4000);
  }

  // ---------- comissão: em risco / ganha / M-10 ----------
  // Único lugar dos textos de explicação (Funil, Venda, Painel, Vendas e Tabela usam daqui).
  const TEXTOS_COMISSAO = {
    emRisco: (ganhaEm) => 'A Nio já pagou ou vai pagar, mas ainda pode estornar: 100% se o cliente cancelar em menos de 180 dias da ativação '
      + 'ou cancelar e reativar em até 30 dias; a diferença se houver downgrade em até 180 dias.'
      + (ganhaEm ? ` Vira 'ganha' em ${ganhaEm}.` : ''),
    ganha: 'Passou dos 180 dias da ativação sem cancelamento nem downgrade. Não pode mais ser estornada.',
    m10: 'Pago no 11º mês se o cliente chegar ao 10º mês ativo, sem fatura com mais de 15 dias de atraso e sem downgrade. Não entra na comissão em risco.',
    m10Nao: (motivo) => `Não elegível ao bônus M-10: ${motivo}.`,
  };
  const textoComissao = (chave, ganhaEm) => {
    const t = TEXTOS_COMISSAO[chave];
    return typeof t === 'function' ? t(ganhaEm) : t;
  };
  // Rótulo com explicação: title= no desktop; o ⓘ abre o mesmo texto ao tocar (celular).
  function dicaTxt(texto) {
    const t = esc(texto);
    return `<button type="button" class="dica" data-dica="${t}" title="${t}" aria-label="O que é isso?">ⓘ</button>`;
  }
  function dica(chave, ganhaEm) { return dicaTxt(textoComissao(chave, ganhaEm)); }
  function rotuloTxt(texto, explicacao) {
    return `<span class="com-rot" title="${esc(explicacao)}">${esc(texto)}</span>${dicaTxt(explicacao)}`;
  }
  function rotulo(texto, chave, ganhaEm) {
    return `<span class="com-rot" title="${esc(textoComissao(chave, ganhaEm))}">${esc(texto)}</span>${dica(chave, ganhaEm)}`;
  }
  // Selos da venda (status 1–5): comissão em risco × ganha e M-10 elegível × não elegível.
  // Atraso > 15 dias e downgrade ainda não chegam ao NIOGEN (FPD/extrato não importados): o "não elegível" só vê o que existe.
  const VENDIDA = ['1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme'];
  function selosComissao(v) {
    if (!v || !VENDIDA.includes(v.status)) return '';
    const selo = (txt, cls, texto) => `<span class="chip selo ${cls}" data-dica="${esc(texto)}" title="${esc(texto)}">${esc(txt)}</span>`;
    const ganha = v.status === '5_comissao_firme';
    const ganhaEm = v.firme_em ? fmtData(v.firme_em) : null;
    const s1 = ganha
      ? selo('Comissão ganha', 'ok', textoComissao('ganha'))
      : selo(ganhaEm ? `Comissão em risco · até ${ganhaEm}` : 'Comissão em risco', 'warn', textoComissao('emRisco', ganhaEm));
    let motivo = null;
    if (v.nio_venda_valida === false) motivo = 'a Nio marcou a venda como inválida';
    else if (!Number(v.bonus_m10_potencial)) motivo = 'o plano não tem bônus M-10 na política vigente';
    let quando = '';
    if (v.ativado_em || v.instalado_em) {
      const d = new Date(v.ativado_em || v.instalado_em);
      d.setMonth(d.getMonth() + 10);
      quando = ` 10º mês ativo em ${parts(d, { month: '2-digit', year: 'numeric' })}.`;
    }
    const s2 = motivo
      ? selo('M-10 não elegível', 'dim', textoComissao('m10Nao', motivo))
      : selo(`M-10 elegível · ${fmtMoeda(v.bonus_m10_potencial)}`, 'info', textoComissao('m10') + quando);
    return s1 + s2;
  }

  // ---------- DFV Nio (nível 1: consulta manual registrada na venda) ----------
  // Único lugar dos textos do DFV (venda de rua, Venda, Funil e Painel usam daqui).
  const DFV_OPCOES = {
    nao_consultado: 'Não consultado',
    viavel: 'Viável',
    viavel_predio: 'Viável (prédio — unidade confirma no APP)',
    sem_viabilidade: 'Sem viabilidade',
    nao_encontrado: 'Endereço não encontrado',
  };
  const TEXTOS_DFV = {
    regra: 'O APP NiO PAP dá a palavra final. Nunca dizer ao cliente "cobertura confirmada" com base no DFV: a rua o consultor confirma na visita.',
    trava: 'Para registrar a venda (0 → 1), o DFV tem que estar Viável ou Viável (prédio) e a consulta ter menos de 7 dias.',
    como: 'Usuário PARCEIRO · senhas com o Ricardo · filtre UF, município e CEP',
    opcoes: {
      nao_consultado: 'Ninguém consultou o DFV para este endereço ainda. Consulte antes de marcar a visita de biometria.',
      viavel: 'Casa com viabilidade "Viável" e HP livre ≥ 1: endereço atendido e com porta livre. Segue para a biometria.',
      viavel_predio: 'Prédio atendido com HP livre ≥ 1; a unidade só se confirma no APP. Segue para a biometria e anote o apto no pedido.',
      sem_viabilidade: 'A fachada existe, mas a viabilidade não é "Viável" (restrição técnica ou pendência). Não vender: saída "Sem cobertura" com interesse futuro em 90 dias.',
      nao_encontrado: 'A fachada não aparece no DFV: sem rede no endereço ou célula bloqueada. Não vender e não insistir no APP: saída "Sem cobertura".',
    },
    jaTemNio: 'Casa com HCS = 1 e HP livre = 0 quer dizer que o endereço já tem Nio: não vender (estorno 100 % + multa de recompra). Saída "Já é cliente Nio".',
    placar: 'Das vendas que entraram no mês, quantas tiveram o DFV consultado e deram viável. Toda qualificada deve ser consultada antes da visita de biometria.',
    faixa: 'Faixa de aprovação de crédito do bairro (últimos 2 meses). Não se fala disso com o cliente: serve para o Placar e o risco de FPD.',
  };
  const DFV_OK = ['viavel', 'viavel_predio'];
  function dfvValido(v) {
    return DFV_OK.includes(v.dfv_viabilidade) && !!v.dfv_consultado_em && (Date.now() - new Date(v.dfv_consultado_em)) < 7 * 86400000;
  }
  // Selo: verde viável · amarelo não consultado / vencido / dispensado · vermelho sem viabilidade ou não encontrado.
  function seloDfv(v) {
    if (!v || v.status === 'saida') return '';
    const selo = (txt, cls, texto) => `<span class="chip selo ${cls}" data-dica="${esc(texto)}" title="${esc(texto)}">${esc(txt)}</span>`;
    const quando = v.dfv_consultado_em ? fmtData(v.dfv_consultado_em) : '';
    if (DFV_OK.includes(v.dfv_viabilidade)) {
      return dfvValido(v)
        ? selo(`DFV viável ${quando}`, 'ok', `${TEXTOS_DFV.opcoes[v.dfv_viabilidade]} ${TEXTOS_DFV.regra}`)
        : selo(`DFV vencido (${quando})`, 'warn', `Consulta com mais de 7 dias. ${TEXTOS_DFV.trava}`);
    }
    if (v.dfv_viabilidade === 'sem_viabilidade' || v.dfv_viabilidade === 'nao_encontrado') {
      return selo(`DFV: ${v.dfv_viabilidade === 'sem_viabilidade' ? 'sem viabilidade' : 'não encontrado'}`, 'bad', TEXTOS_DFV.opcoes[v.dfv_viabilidade]);
    }
    if (v.dfv_dispensado) return selo('DFV dispensado (admin)', 'warn', `Admin dispensou a consulta: ${v.dfv_dispensa_motivo || '—'}`);
    return selo('DFV não consultado', 'warn', `${TEXTOS_DFV.opcoes.nao_consultado} ${TEXTOS_DFV.trava}`);
  }
  // Link e acesso do DFV vêm do banco (config_links, só para logado) — nunca do repo, que é público.
  let dfvCache;
  async function dadosDfv() {
    if (dfvCache === undefined) {
      const { data } = await sb.from('config_links').select('url, acesso').eq('chave', 'dfv_sudeste').maybeSingle();
      dfvCache = { url: (data && data.url) || null, acesso: (data && data.acesso) || null };
    }
    return dfvCache;
  }
  async function linkDfv() { return (await dadosDfv()).url; }
  // Bloco "Cobertura (DFV)": os mesmos campos na venda de rua e no detalhe da venda.
  function dfvCampos(v) {
    v = v || {};
    const opt = (lista, atual) => lista.map(([val, txt]) => `<option value="${val}" ${val === (atual ?? '') ? 'selected' : ''}>${esc(txt)}</option>`).join('');
    const todas = Object.entries(DFV_OPCOES).map(([k, t]) => `${t}: ${TEXTOS_DFV.opcoes[k]}`).join(' · ');
    return `
      <div class="dfv-topo">
        <a class="btn btn-sm dfv-link" data-dfv-link target="_blank" rel="noopener noreferrer" href="#">Abrir DFV Sudeste ↗</a>
        <span class="nota-campo" data-dfv-acesso>${esc(TEXTOS_DFV.como)}</span>
      </div>
      <div class="grade2">
        <label class="campo"><span>Viabilidade no DFV ${dicaTxt(todas)}</span>
          <select name="dfv_viabilidade">${opt(Object.entries(DFV_OPCOES), v.dfv_viabilidade || 'nao_consultado')}</select></label>
        <label class="campo"><span>Faixa de aprovação ${dicaTxt(TEXTOS_DFV.faixa)}</span>
          <select name="dfv_faixa_credito">${opt([['', '—'], ['<50', 'menor que 50 %'], ['50-70', '50 a 70 %'], ['>70', 'maior que 70 %'], ['nao_informado', 'não informado']], v.dfv_faixa_credito)}</select></label>
        <label class="campo">Classificação
          <select name="dfv_classificacao">${opt([['', '—'], ['ALTO', 'Alto'], ['MEDIO', 'Médio'], ['BAIXO', 'Baixo']], v.dfv_classificacao)}</select></label>
        <div class="junto dfv-hp">
          <label class="campo">HP livre<input type="number" min="0" name="dfv_hp_livre" value="${v.dfv_hp_livre ?? ''}"></label>
          <label class="campo">HCs<input type="number" min="0" name="dfv_hcs" value="${v.dfv_hcs ?? ''}"></label>
        </div>
      </div>
      <span class="nota-campo">${esc(TEXTOS_DFV.regra)} ${dicaTxt(TEXTOS_DFV.jaTemNio)}</span>`;
  }
  function dfvLer(root) {
    const val = (n) => { const el = root.querySelector(`[name="${n}"]`); return el ? el.value : ''; };
    const num = (n) => (val(n) === '' ? null : Number(val(n)));
    return {
      dfv_viabilidade: val('dfv_viabilidade') || 'nao_consultado',
      dfv_faixa_credito: val('dfv_faixa_credito') || null,
      dfv_classificacao: val('dfv_classificacao') || null,
      dfv_hp_livre: num('dfv_hp_livre'),
      dfv_hcs: num('dfv_hcs'),
    };
  }
  async function ligarLinkDfv(root) {
    const { url, acesso } = await dadosDfv();
    root.querySelectorAll('[data-dfv-link]').forEach((a) => {
      if (url) { a.href = url; return; }
      a.title = 'Link do DFV ainda não cadastrado no NIOGEN — peça ao Ricardo';
      a.addEventListener('click', (e) => { e.preventDefault(); toast(a.title, 'bad'); });
    });
    if (!acesso) return;
    // Senhas mascaradas até alguém tocar em "mostrar" (tela de celular na rua).
    root.querySelectorAll('[data-dfv-acesso]').forEach((el) => {
      const sen = (n) => `<code class="dfv-senha" data-senha="${esc(acesso[n] || '')}">••••</code>`;
      el.innerHTML = `Usuário <strong>${esc(acesso.usuario || '')}</strong> · Senha 1 ${sen('senha1')} · Senha 2 ${sen('senha2')} `
        + '<button type="button" class="btn btn-sm btn-ghost" data-mostrar-senha>mostrar</button>'
        + (acesso.passos ? `<span class="dfv-passos">${esc(acesso.passos)}</span>` : '');
      el.querySelector('[data-mostrar-senha]').addEventListener('click', (ev) => {
        const ver = ev.currentTarget.textContent === 'mostrar';
        el.querySelectorAll('[data-senha]').forEach((c) => { c.textContent = ver ? c.dataset.senha : '••••'; });
        ev.currentTarget.textContent = ver ? 'esconder' : 'mostrar';
      });
    });
  }

  document.addEventListener('click', (ev) => {
    const b = ev.target.closest('[data-dica]');
    const aberto = document.querySelector('.dica-pop');
    if (aberto) aberto.remove();
    if (!b || (aberto && aberto.dataset.de === b.dataset.dica)) return;
    ev.preventDefault();
    ev.stopPropagation();
    const pop = document.createElement('div');
    pop.className = 'dica-pop';
    pop.setAttribute('role', 'tooltip');
    pop.dataset.de = b.dataset.dica;
    pop.textContent = b.dataset.dica;
    document.body.appendChild(pop);
    const r = b.getBoundingClientRect();
    const larg = Math.min(300, window.innerWidth - 24);
    pop.style.width = `${larg}px`;
    pop.style.left = `${Math.max(12, Math.min(r.left + r.width / 2 - larg / 2, window.innerWidth - larg - 12)) + window.scrollX}px`;
    pop.style.top = `${r.bottom + 6 + window.scrollY}px`;
  }, true);

  // ---------- sessão ----------
  let usuarioAtual = null;
  async function exigirLogin() {
    const { data } = await sb.auth.getSession();
    if (!data.session) {
      location.replace('index.html');
      return new Promise(() => {});
    }
    const { data: u, error } = await sb.from('usuarios').select('*').eq('id', data.session.user.id).maybeSingle();
    if (error) {
      // Falha de rede/configuração não é "sem perfil": mostra o erro real e mantém a sessão.
      location.replace('index.html?erro=' + encodeURIComponent(msgErro(error)));
      return new Promise(() => {});
    }
    if (!u || !u.ativo) {
      await sb.auth.signOut();
      location.replace('index.html?erro=perfil');
      return new Promise(() => {});
    }
    usuarioAtual = { ...u, email: data.session.user.email };
    return usuarioAtual;
  }
  async function sair() {
    await sb.auth.signOut();
    location.replace('index.html');
  }

  // ---------- modais ----------
  // Cria um <dialog> com o HTML dado; resolve com FormData ao confirmar ou null ao cancelar.
  function modal(html, aoAbrir) {
    return new Promise((resolve) => {
      const d = document.createElement('dialog');
      d.className = 'modal';
      d.innerHTML = `<form method="dialog">${html}<div class="acoes"><button type="button" class="btn btn-ghost" data-cancelar>Cancelar</button><button type="submit" class="btn btn-acc" value="ok">Confirmar</button></div></form>`;
      document.body.appendChild(d);
      const form = d.querySelector('form');
      let resultado = null;
      form.addEventListener('submit', (ev) => {
        if (!form.reportValidity()) { ev.preventDefault(); return; }
        resultado = new FormData(form);
      });
      d.querySelector('[data-cancelar]').addEventListener('click', () => d.close());
      d.addEventListener('close', () => { d.remove(); resolve(resultado); });
      if (aoAbrir) aoAbrir(d);
      d.showModal();
    });
  }

  function amanhaISO() {
    const d = new Date(Date.now() + 86400000);
    return diaSP(d);
  }

  // Pede data + período; devolve ISO com fuso -03:00 (manhã 08:00, tarde 13:00) ou null.
  async function pedirAgendamento(titulo, venda) {
    const fd = await modal(`
      <h3>${esc(titulo)}</h3>
      <p>${esc(venda.cliente_nome)} · ${esc(venda.cidade || '')} · ${esc(venda.plano_nome || '')}</p>
      <label class="campo">Data da instalação<input type="date" name="data" required value="${amanhaISO()}"></label>
      <label class="campo">Período<select name="periodo"><option value="08:00">Manhã · 8–12h</option><option value="13:00">Tarde · 13–17h</option></select></label>
    `);
    if (!fd) return null;
    return `${fd.get('data')}T${fd.get('periodo')}:00-03:00`;
  }

  async function pedirPedidoBiometria(venda) {
    const fd = await modal(`
      <h3>Registrar venda</h3>
      <p>Para virar "Vendido" a Nio exige o nº do pedido do APP NiO PAP e a biometria aprovada.</p>
      <label class="campo">Nº do pedido (APP NiO PAP)<input type="text" name="pedido" value="${esc(venda.nio_pedido || '')}" autocomplete="off"></label>
      <label class="campo">Biometria<select name="biometria">
        <option value="">—</option>
        ${Object.keys(BIOMETRIA).map((b) => `<option value="${b}" ${venda.biometria_status === b ? 'selected' : ''}>${b}</option>`).join('')}
      </select></label>
    `);
    if (!fd) return null;
    const pedido = String(fd.get('pedido') || '').trim();
    const biometria = fd.get('biometria') || null;
    return {
      nio_pedido: pedido || null,
      biometria_status: biometria,
      biometria_em: biometria && biometria !== venda.biometria_status ? new Date().toISOString() : venda.biometria_em,
    };
  }

  async function pedirSaida(venda) {
    const fd = await modal(`
      <h3>Encerrar com motivo</h3>
      <p>${esc(venda.cliente_nome)}</p>
      <label class="campo">Motivo<select name="motivo" required><option value="">Escolher…</option>${MOTIVOS_SAIDA.map((m) => `<option>${esc(m)}</option>`).join('')}</select></label>
      <label class="campo" data-futuro hidden>Volta em<input type="date" name="futuro"></label>
    `, (d) => {
      const sel = d.querySelector('[name=motivo]');
      const fut = d.querySelector('[data-futuro]');
      sel.addEventListener('change', () => {
        const on = sel.value.startsWith('Interesse futuro');
        fut.hidden = !on;
        fut.querySelector('input').required = on;
      });
    });
    if (!fd) return null;
    const motivo = fd.get('motivo');
    return { motivo_saida: motivo, interesse_futuro_em: motivo.startsWith('Interesse futuro') ? fd.get('futuro') : null };
  }

  // Muda o status; os campos extras exigidos por cada destino são pedidos antes.
  // O banco é a autoridade: a mensagem do RAISE do trigger volta como toast.
  async function moverStatus(venda, destino) {
    if (destino === venda.status) return false;
    let campos = { status: destino };
    if (destino === '1_vendido' && venda.status === '0_qualificado') {
      const extra = await pedirPedidoBiometria(venda);
      if (!extra) return false;
      campos = { ...campos, ...extra };
    } else if (destino === '2_aguardando_instalacao') {
      const quando = await pedirAgendamento('Registrar agendamento', venda);
      if (!quando) return false;
      campos.instalacao_agendada_para = quando;
    } else if (destino === 'saida') {
      const extra = await pedirSaida(venda);
      if (!extra) return false;
      campos = { ...campos, ...extra };
    }
    const { error } = await sb.from('vendas').update(campos).eq('id', venda.id);
    if (error) { toast(msgErro(error), 'bad'); return false; }
    toast(`${primeiroNome(venda.cliente_nome)} → ${STATUS_MAP[destino].curto}`, 'ok');
    return true;
  }

  async function registrarAgendamento(venda, titulo) {
    const quando = await pedirAgendamento(titulo || 'Registrar agendamento', venda);
    if (!quando) return false;
    const campos = { instalacao_agendada_para: quando, nio_pendencia_cod: null, nio_pendencia_desc: null };
    if (venda.status === '1_vendido') campos.status = '2_aguardando_instalacao';
    const { error } = await sb.from('vendas').update(campos).eq('id', venda.id);
    if (error) { toast(msgErro(error), 'bad'); return false; }
    toast(`Instalação de ${primeiroNome(venda.cliente_nome)} agendada`, 'ok');
    return true;
  }

  // ---------- dados comuns ----------
  async function carregarUsuarios() {
    const { data } = await sb.from('usuarios').select('id, nome, perfil').eq('ativo', true).order('nome');
    return data || [];
  }
  function preencherSelect(sel, valores, rotuloTodos) {
    sel.innerHTML = `<option value="">${esc(rotuloTodos)}</option>` +
      valores.map(([v, r]) => `<option value="${esc(v)}">${esc(r)}</option>`).join('');
  }

  // ---------- service worker ----------
  if ('serviceWorker' in navigator && location.protocol === 'https:') {
    navigator.serviceWorker.register('sw.js').catch(() => {});
  }

  window.NG = {
    sb, TZ, STATUS, STATUS_MAP, ORIGENS, FORMAS, SEGMENTOS, BIOMETRIA, PERFIS, MOTIVOS_SAIDA,
    esc, fmtData, fmtDataAno, fmtHora, fmtDataHora, fmtDiaSemana, fmtMoeda, fmtDiaISO, fmtNum, fmtHoras, diaSP, diasEntre, janela, primeiroNome,
    documentoValido, soDigitos, msgErro, toast, TEXTOS_COMISSAO, textoComissao, dica, dicaTxt, rotulo, rotuloTxt, selosComissao,
    DFV_OPCOES, TEXTOS_DFV, dfvValido, seloDfv, linkDfv, dfvCampos, dfvLer, ligarLinkDfv, exigirLogin, sair, modal,
    pedirAgendamento, moverStatus, registrarAgendamento, pedirSaida, pedirPedidoBiometria,
    carregarUsuarios, preencherSelect,
    get usuario() { return usuarioAtual; },
  };
})();
