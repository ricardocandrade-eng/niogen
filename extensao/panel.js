/* NIOGEN | extensao/panel.js | 06/11/2026 — Claude Code (prompt 28) · rev. 08/11/2026 (rolagem + conversas da Mari)
 * rev. 08/11: (1) "Preencher esta etapa" rola o painel até a etapa seguinte quando a etapa fechou; (2) orelha "Conversas da Mari":
 * consulta o portal a partir de uma conversa ainda sem venda (mari_conversas, RLS admin/backoffice) e orelha "Conversa" com a
 * negociação (mari_turnos = o que passou pelo Chatwoot). Só leitura no banco; nada novo é gravado.
 * Painel lateral "NIOGEN no Portal". Fala com o Supabase Nio por REST com a anon key + o login do usuário do NIOGEN (o RLS vale).
 * NUNCA service role. Dado de cliente só em memória (variável S) enquanto o painel está aberto; sessão (só tokens) em chrome.storage.local por até 30 dias (0.4.0).
 * rev. 10/11 (0111, 0.4.1): o nº do pedido só existe na OS (OS = pedido). O painel não pede mais número: "Aprovado" no crédito
 *   (etapa 3) leva a venda para Biometria no NIOGEN (etiqueta + aviso do link), com "Já avisei" e a conferência de recompra.
 * rev. 09/11 (0082): "Gravar no NIOGEN" chama backoffice_momento('pedido') — etiqueta, nota e aviso ao cliente saem sozinhos.
 * rev. 09/11 (0087, 0.3.1): venda = OS aberta (etapa 7) — o painel pede o nº do pedido E o nº da OS.
 * rev. 09/11 (0092, 0.3.3): na etapa 2 o resultado da viabilidade e na etapa 3 o do crédito vão para o NIOGEN com um toque
 *   (backoffice_momento 'viabilidade' / 'credito'); "Já avisei o cliente" no Gravar pedido (sem o aviso automático).
 * rev. 09/11 (0089, 0.3.2): ordem nova — o painel grava SÓ o nº do pedido (etapa 3). A OS se abre depois da biometria validada,
 * já com o dia e o período, pela ficha do NIOGEN ("Gravar OS e agendamento") — é isso que faz a venda contar.
 * rev. 10/11 (0105, 0.4.0): no Histórico de Pedidos, botão "Atualizar status no NIOGEN" — o content.js lê os 7 status (lista branca
 *   de cliques) e o painel manda o lote em UMA chamada portal_status_registrar(p_lote).
 * Este arquivo não usa console.* e não grava dado de cliente em storage (em storage.local só a sessão). Quem escreve no portal é o content.js.
 */
'use strict';
(() => {
  const CFG = window.NIOGEN_CONFIG || {};
  const ETAPAS = ['Identificação PDV', 'Consulta de viabilidade', 'Cadastro do cliente', 'Contato', 'Pagamento e ofertas', 'Resumo', 'Abrir OS'];
  const PREENCHE = [1, 2, 3, 4];     // etapas que a extensão preenche; 5 só destaca; 6 e 7 só checklist
  // Decisão do Ricardo (06/11): TODO pedido sai com a matrícula TT837725 (Joysse), PDV 1069521 — não depende do vendedor da venda
  // nem de usuarios.matricula_pap, e não há escolha no painel.
  const MATRICULA_PAP = 'TT837725';
  const MATRICULA_NOME = 'Joysse';
  const CHECKLIST = ['Velocidade e o que vem incluso', 'Forma de pagamento', 'Valor mensal fixo até jan/2030', 'Regra da taxa de habilitação',
    'Regra de vencimento', 'Informações técnicas obrigatórias', 'Data da instalação', 'App Nio', 'Sumário/Regulamento'];
  const TXT_ESTADO = {
    ok: ['preenchido', 'ok'], ja: ['já estava assim', 'ok'], destacado: ['destacado no portal', 'ok'],
    nao_achado: ['o campo ainda não apareceu — avance você e preencha de novo', 'warn'],
    sem_valor: ['falta no NIOGEN', 'bad'], bloqueado: ['campo bloqueado pelo portal', 'warn'],
    nao_aceito: ['o portal não aceitou o valor — digite você', 'bad'], sem_opcao: ['não achei a opção na lista — escolha você', 'warn'],
    ambiguo: ['mais de uma opção parecida — escolha você', 'warn'], recusado: ['recusado pela trava de segurança', 'bad'],
  };

  // Conta "Nio Atendimento" do Chatwoot (a mesma do docs/assets/app.js) — só para o link "Abrir no Chatwoot".
  const CHATWOOT_NIO_ACCOUNT = '195428';
  // PDV de todo pedido (o mesmo que dados_portal devolve) — usado quando o ponto de partida é uma conversa, sem venda.
  const PDV = { uf: 'MG', codigo: '1069521', nome: 'DHARMA TELECOM LTDA' };
  const ETAPA_MARI = { abertura: 'abertura', endereco: 'endereço', elegibilidade: 'elegibilidade', planos: 'planos', coleta: 'coletando dados',
    resumo: 'resumo', handoff: 'handoff', retomada: 'retomada' };
  const COLS_CONV = 'id,telefone,nome_contato,status,etapa,cep,numero,complemento,endereco_cep,cidade,uf,plano_escolhido,forma_pagamento,'
    + 'visita_preferencia,instalacao_preferencia,dados,venda_id,chatwoot_conversation_id,chatwoot_status,handoff_motivo,updated_at,ultima_msg_lead_at,'
    + 'venda:vendas(status,nio_pedido)';

  const S = {
    sess: null, nome: '', perfil: '', fila: null, filaErro: '', carregando: false,
    venda: null, dados: null, etapaAuto: null, etapaManual: null, avisos: [], resultados: {},
    matricula: '', pedido: '', msg: null, tabId: null, ocupado: false,
    // rev. 08/11 — conversas da Mari
    aba: 'vendas', convs: null, convsErro: '', convsCarregando: false, busca: '',
    conversa: null,            // conversa aberta (ponto de partida sem venda) ou a conversa ligada à venda aberta
    turnos: null, turnosErro: '', turnosCarregando: false, orelha: 'portal',
    atualizando: false,        // botão "Atualizar" do topo (rev. 08/11 tarde)
    // 0.4.0 (10/11) — Histórico de Pedidos: status do portal → NIOGEN
    naHistorico: false, hist: null,   // hist = { rodando, progresso: [], resumo, detalhes, erro, parou_em }
  };

  // ------------------------------------------------------------------ DOM
  function h(tag, attrs, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (k === 'class') el.className = v;
      else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else if (v === true) el.setAttribute(k, '');
      else if (v !== false && v != null) el.setAttribute(k, v);
    }
    for (const kid of kids.flat(Infinity)) {
      if (kid == null || kid === false) continue;
      el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
    }
    return el;
  }
  const raiz = document.getElementById('raiz');

  // ------------------------------------------------------------------ Supabase (REST, sem biblioteca)
  async function lerErro(res) {
    let j = null;
    try { j = await res.json(); } catch (e) { /* sem corpo */ }
    const m = j && (j.message || j.msg || j.error_description || j.error);
    return new Error(m || `Erro ${res.status}`);
  }
  async function renovar() {
    if (!S.sess || !S.sess.refresh) return false;
    try {
      const res = await fetch(`${CFG.supabaseUrl}/auth/v1/token?grant_type=refresh_token`, {
        method: 'POST', headers: { apikey: CFG.supabaseAnonKey, 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh_token: S.sess.refresh }),
      });
      if (!res.ok) return false;
      await guardaSessao(await res.json());
      return true;
    } catch (e) { return null; }   // 0.4.0: sem rede não é sessão vencida — não desloga
  }
  // 0.4.0 (Ricardo, 10/11: "logar toda hora"): a sessão do NIOGEN fica em chrome.storage.local por até 30 dias contados do
  // login (antes era storage.session, que o Chrome apaga ao fechar). Só os tokens do Supabase + uid + data do login — nunca
  // dado de cliente. Passou de 30 dias, o painel pede o login de novo. "Sair" apaga na hora.
  const SESSAO_DIAS = 30;
  async function guardaSessao(j) {
    const desde = (S.sess && S.sess.desde) || Date.now();
    S.sess = { access: j.access_token, refresh: j.refresh_token, uid: (j.user && j.user.id) || (S.sess && S.sess.uid) || '', desde };
    await chrome.storage.local.set({ niogen_sess: S.sess });
  }
  async function lerSessaoGuardada() {
    const g = await chrome.storage.local.get('niogen_sess');
    let x = g && g.niogen_sess;
    if (!x) {   // migração da 0.3: a sessão antiga em storage.session vira a nova (conta 30 dias a partir de agora)
      const v = await chrome.storage.session.get('niogen_sess');
      x = v && v.niogen_sess ? { ...v.niogen_sess, desde: Date.now() } : null;
      try { await chrome.storage.session.remove('niogen_sess'); } catch (e) { /* ignora */ }
    }
    if (x && (!x.desde || Date.now() - x.desde > SESSAO_DIAS * 86400000)) return null;
    return x;
  }
  async function api(caminho, opcoes = {}, tentar = true) {
    const res = await fetch(CFG.supabaseUrl + caminho, {
      method: opcoes.method || 'GET',
      headers: {
        apikey: CFG.supabaseAnonKey, 'Content-Type': 'application/json',
        Authorization: `Bearer ${S.sess ? S.sess.access : CFG.supabaseAnonKey}`, ...(opcoes.headers || {}),
      },
      body: opcoes.body === undefined ? undefined : JSON.stringify(opcoes.body),
    });
    if (res.status === 401 && tentar && S.sess) {
      if (await renovar()) return api(caminho, opcoes, false);
      await sairLocal();
      throw new Error('Sessão expirada — entre de novo.');
    }
    if (!res.ok) throw await lerErro(res);
    if (res.status === 204) return null;
    const txt = await res.text();
    return txt ? JSON.parse(txt) : null;
  }
  const rpc = (nome, args) => api(`/rest/v1/rpc/${nome}`, { method: 'POST', body: args || {} });

  async function entrar(email, senha) {
    const res = await fetch(`${CFG.supabaseUrl}/auth/v1/token?grant_type=password`, {
      method: 'POST', headers: { apikey: CFG.supabaseAnonKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password: senha }),
    });
    if (!res.ok) {
      const e = await lerErro(res);
      throw new Error(/invalid/i.test(e.message) ? 'E-mail ou senha não conferem.' : e.message);
    }
    await guardaSessao(await res.json());
    await carregaPerfil();
  }
  async function carregaPerfil() {
    try {
      const r = await api(`/rest/v1/usuarios?select=nome,perfil&id=eq.${encodeURIComponent(S.sess.uid)}`);
      S.nome = (r && r[0] && r[0].nome) || ''; S.perfil = (r && r[0] && r[0].perfil) || '';
    } catch (e) { S.nome = ''; }
  }
  async function sairLocal() {
    S.sess = null; S.nome = ''; S.perfil = ''; S.fila = null; S.venda = null; S.dados = null;
    S.resultados = {}; S.msg = null; S.matricula = ''; S.pedido = ''; S.os = '';
    S.convs = null; S.conversa = null; S.turnos = null; S.busca = ''; S.aba = 'vendas'; S.orelha = 'portal';
    try { await chrome.storage.local.remove('niogen_sess'); await chrome.storage.session.remove('niogen_sess'); } catch (e) { /* ignora */ }
    try { await mandar({ tipo: 'limpar' }); } catch (e) { /* aba sem content script */ }
  }

  // ------------------------------------------------------------------ conversa com a aba do portal
  async function abaAtiva() {
    const [t] = await chrome.tabs.query({ active: true, currentWindow: true });
    S.tabId = t ? t.id : null;
    return S.tabId;
  }
  async function mandar(msg) {
    const id = S.tabId || await abaAtiva();
    if (id == null) throw new Error('Não achei a aba do portal.');
    try { return await chrome.tabs.sendMessage(id, msg); }
    catch (e) { throw new Error('A aba do portal ainda não carregou a extensão — recarregue a página do portal (F5) e tente de novo.'); }
  }
  chrome.runtime.onMessage.addListener((msg, sender) => {
    if (!msg || msg.tipo !== 'estado' || !sender.tab) return;
    if (S.tabId != null && sender.tab.id !== S.tabId) return;
    S.etapaAuto = msg.etapa || null; S.avisos = msg.avisos || []; S.naHistorico = !!msg.historico;
    desenha();
  });
  chrome.runtime.onMessage.addListener((msg, sender) => {
    if (!msg || msg.tipo !== 'historico_progresso' || !S.hist) return;
    S.hist.progresso = [...(S.hist.progresso || []).slice(-11), msg.texto];
    desenha();
  });
  chrome.tabs.onActivated.addListener(async () => { await abaAtiva(); try { await mandar({ tipo: 'estado?' }); } catch (e) { /* ok */ } });

  // ------------------------------------------------------------------ formatação
  const so = (s) => String(s == null ? '' : s).replace(/\D/g, '');
  const fmtCep = (c) => { const d = so(c); return d.length === 8 ? `${d.slice(0, 5)}-${d.slice(5)}` : (c || ''); };
  const fmtDoc = (d) => { const x = so(d); if (x.length === 11) return `${x.slice(0, 3)}.${x.slice(3, 6)}.${x.slice(6, 9)}-${x.slice(9)}`; return x.length === 14 ? `${x.slice(0, 2)}.${x.slice(2, 5)}.${x.slice(5, 8)}/${x.slice(8, 12)}-${x.slice(12)}` : (d || ''); };
  const celular = (t) => { let d = so(t); if ((d.length === 12 || d.length === 13) && d.startsWith('55')) d = d.slice(2); return d; };
  const fmtCel = (t) => { const d = celular(t); return d.length === 11 ? `(${d.slice(0, 2)}) ${d.slice(2, 7)}-${d.slice(7)}` : d.length === 10 ? `(${d.slice(0, 2)}) ${d.slice(2, 6)}-${d.slice(6)}` : (t || ''); };
  const fmtQuando = (iso) => { try { return new Date(iso).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }); } catch (e) { return ''; } };
  const ha = (iso) => {
    if (!iso) return '';
    const min = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000));
    if (min < 60) return `há ${min} min`;
    const hrs = Math.round(min / 60);
    return hrs < 48 ? `há ${hrs} h` : `há ${Math.round(hrs / 24)} dias`;
  };
  const semAcento = (s) => String(s == null ? '' : s).normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
  // mesmo filtro do mari.html: tira o bloco [HANDOFF] e os marcadores internos da Mari
  const limpa = (t) => String(t || '').replace(/\[HANDOFF\][\s\S]*?(\[\/HANDOFF\]|$)/gi, '').replace(/\[[A-Z_]{3,}(?::[^\]]*)?\]/g, '').trim();
  const nomeConversa = (c) => (c.dados && c.dados.nome) || c.nome_contato || fmtCel(c.telefone) || '—';
  const FORMAS = { boleto: ['Boleto', ['boleto', 'boleto bancario']], cartao: ['Cartão', ['cartao de credito', 'cartao', 'credito']], dacc: ['DACC (débito em conta)', ['debito em conta', 'debito automatico', 'dacc']] };

  // ------------------------------------------------------------------ o que cada etapa mostra e o que a extensão escreve
  const matriculaDaVenda = () => MATRICULA_PAP;
  const faltaDe = (d) => ({ falta: true, rot: d });

  // linhas de exibição: [rótulo, valor, obrigatório, só conferência]
  function linhasEtapa(n) {
    const d = S.dados; if (!d) return [];
    const v = d.viabilidade, c = d.cliente, k = d.contato, o = d.oferta;
    switch (n) {
      case 1: return [['UF', d.pdv.uf, true], ['PDV', `${d.pdv.codigo} - ${d.pdv.nome}`, true], ['Matrícula do vendedor', `${MATRICULA_PAP} · ${MATRICULA_NOME}`, true, true]];
      case 2: return [['CEP', fmtCep(v.cep), true], ['Número', v.numero || '', true], ['Complemento', v.complemento || '', false],
        ['Referência', v.referencia || '', true], ['Rua (conferir)', v.logradouro || '', false, true], ['Bairro (conferir)', v.bairro || '', false, true],
        ['Cidade (conferir)', [v.cidade, v.uf].filter(Boolean).join('/'), false, true]];
      case 3: return [[c.tipo, c.documento ? fmtDoc(c.documento) : '', true], ['Nome (o portal traz da Receita)', c.nome || '', true, true],
        ['Nascimento', '', false, true, 'não coletamos — se o portal pedir, pergunte ao cliente'], ['Nome da mãe', '', false, true, 'não coletamos — se o portal pedir, pergunte ao cliente']];
      case 4: return [['Celular', k.celular ? fmtCel(k.celular) : '', true], ['E-mail', k.email || '', true],
        ['Aceite WhatsApp', '', false, true, 'não registrado — marque você só se o cliente aceitou']];
      case 5: return [['Plano', o.plano || '', true], ['Fidelidade', 'Com fidelidade', false, true], ['Adicionais', (o.adicionais || []).map((a) => `${a.nome} × ${a.qtd}`).join(', ') || 'nenhum', false],
        ['Forma de pagamento', o.forma_pagamento ? FORMAS[o.forma_pagamento][0] : '', true]];
      case 6: case 7: return [['Período preferido', d.agendamento.preferencia || '', true]];
      default: return [];
    }
  }
  const faltasDaEtapa = (n) => linhasEtapa(n).filter(([, val, obrig]) => obrig && !val).length;

  // campos que o content.js escreve (n = 1..4) ou destaca (n = 5)
  function camposDaEtapa(n) {
    const d = S.dados; if (!d) return [];
    const v = d.viabilidade, c = d.cliente, k = d.contato, o = d.oferta;
    if (n === 1) {
      const mat = matriculaDaVenda();
      return [
        { id: 'uf', modo: 'lista', ph: ['Informe a UF'], busca: d.pdv.uf, match: [d.pdv.uf], exato: true, valor: d.pdv.uf },
        { id: 'pdv', modo: 'lista', ph: ['Insira o código ou nome do seu PDV'], busca: d.pdv.codigo, match: [d.pdv.codigo], valor: d.pdv.codigo },
        { id: 'mat', modo: 'lista', ph: ['Informe a matrícula do vendedor'], busca: mat, match: [mat], valor: mat },
      ];
    }
    if (n === 2) {
      const semNum = v.numero && /^(s\/?n|sem numero|sem número)$/i.test(String(v.numero).trim());
      const lista = [
        { id: 'cep', ph: ['Endereço ou CEP'], valor: fmtCep(v.cep), numerico: true },
        semNum ? { id: 'numero', modo: 'opcao', textos: ['Sem número'] } : { id: 'numero', ph: ['Número'], valor: v.numero || '' },
        { id: 'ref', ph: ['Referência'], valor: v.referencia || '' },
      ];
      if (v.complemento) {
        lista.push({ id: 'compl_op', modo: 'opcao', textos: ['Inserir complemento manual'] });
        lista.push({ id: 'compl', ph: ['Complemento 1'], valor: v.complemento });
      } else lista.push({ id: 'compl_op', modo: 'opcao', textos: ['Sem complemento'] });
      return lista;
    }
    if (n === 3) return [{ id: 'doc', ph: ['CPF', 'CPF/CNPJ', 'CNPJ'], valor: c.documento || '', numerico: true }];
    if (n === 4) {
      const cel = celular(k.celular);
      return [
        { id: 'cel', ph: ['Celular Principal'], valor: cel, numerico: true },
        { id: 'cel2', ph: ['Confirme o celular principal'], valor: cel, numerico: true },
        { id: 'email', ph: ['E-mail'], valor: k.email || '' },
        { id: 'email2', ph: ['Confirme o e-mail'], valor: k.email || '' },
      ];
    }
    if (n === 5) {
      const lista = [];
      if (o.plano) lista.push({ id: 'plano', modo: 'destacar', textos: [o.plano] });
      lista.push({ id: 'fid', modo: 'destacar', textos: ['Com fidelidade'], contem: false });
      (o.adicionais || []).forEach((a, i) => lista.push({ id: `ad${i}`, modo: 'destacar', textos: [a.nome] }));
      if (o.forma_pagamento) lista.push({ id: 'forma', modo: 'destacar', textos: FORMAS[o.forma_pagamento][1] });
      return lista;
    }
    return [];
  }
  const ROTULO_CAMPO = {
    uf: 'UF', pdv: 'PDV', mat: 'Matrícula', cep: 'CEP', numero: 'Número', ref: 'Referência', compl_op: 'Complemento (opção)', compl: 'Complemento',
    doc: 'CPF/CNPJ', cel: 'Celular', cel2: 'Confirme o celular', email: 'E-mail', email2: 'Confirme o e-mail', plano: 'Plano', fid: 'Fidelidade', forma: 'Forma de pagamento',
  };
  const rotuloCampo = (id) => ROTULO_CAMPO[id] || (id.startsWith('ad') ? 'Adicional' : id);

  // ------------------------------------------------------------------ ações
  let tAviso = null;
  function aviso(texto, tipo) {
    S.msg = texto ? { texto, tipo: tipo || 'ok' } : null;
    clearTimeout(tAviso);
    if (S.msg && S.msg.tipo !== 'bad') { const m = S.msg; tAviso = setTimeout(() => { if (S.msg === m) { S.msg = null; desenha(); } }, 9000); }
  }

  async function carregaFila() {
    S.carregando = true; S.filaErro = ''; desenha();
    try { S.fila = (await rpc('portal_prontas')) || []; }
    catch (e) { S.filaErro = e.message; S.fila = S.fila || []; }
    S.carregando = false; desenha();
  }
  // ---- conversas da Mari em andamento (rev. 08/11): abertas, Chatwoot não resolvido, sem pedido aberto e fora de Saída.
  const podeVerConversas = () => ['admin', 'backoffice'].includes(S.perfil);
  async function carregaConversas() {
    if (!podeVerConversas()) { S.convs = []; desenha(); return; }
    S.convsCarregando = true; S.convsErro = ''; desenha();
    try {
      const q = `/rest/v1/mari_conversas?select=${encodeURIComponent(COLS_CONV)}&status=in.(ativo,handoff_realizado)&canal=neq.teste`
        + '&or=(chatwoot_status.is.null,chatwoot_status.neq.resolved)&order=updated_at.desc&limit=80';
      const r = (await api(q)) || [];
      S.convs = r.filter((c) => !(c.venda && (c.venda.nio_pedido || c.venda.status === 'saida')));
    } catch (e) { S.convsErro = e.message; S.convs = S.convs || []; }
    S.convsCarregando = false; desenha();
  }
  async function carregaTurnos() {
    const c = S.conversa; if (!c) return;
    S.turnosCarregando = true; S.turnosErro = ''; desenha();
    try {
      const r = (await api(`/rest/v1/mari_turnos?select=id,papel,texto,created_at&conversa_id=eq.${encodeURIComponent(c.id)}`
        + '&papel=in.(lead,mari,humano)&order=created_at.desc,id.desc&limit=400')) || [];
      if (S.conversa && S.conversa.id === c.id) S.turnos = r.reverse();
    } catch (e) { S.turnosErro = e.message; }
    S.turnosCarregando = false; desenha();
  }
  // O bloco "Dados para o portal" montado a partir do que a Mari já coletou (mesmo formato do dados_portal).
  function dadosDaConversa(c, plano) {
    const d = c.dados || {}, ec = c.endereco_cep || {};
    const doc = so(d.cpf);
    const vazio = (x) => { const t = String(x == null ? '' : x).trim(); return t || null; };
    return {
      venda_id: c.venda_id || null, conversa_id: c.id, status: null, pedido: null,
      pdv: { ...PDV, matricula: MATRICULA_PAP, vendedor: MATRICULA_NOME },
      viabilidade: { cep: vazio(c.cep), numero: vazio(c.numero), complemento: vazio(c.complemento), referencia: vazio(d.referencia),
        logradouro: ec.logradouro || null, bairro: ec.bairro || null, cidade: c.cidade || ec.localidade || null, uf: c.uf || ec.uf || null },
      cliente: { tipo: doc.length === 14 ? 'CNPJ' : 'CPF', documento: doc || null, nome: d.nome || c.nome_contato || null },
      contato: { celular: so(d.telefone || c.telefone) || null, email: vazio(d.email) },
      oferta: { plano: plano || null, adicionais: [], forma_pagamento: c.forma_pagamento || null },
      agendamento: { preferencia: vazio(c.instalacao_preferencia || c.visita_preferencia) },
    };
  }
  // Botão "Atualizar" do topo: recarrega do NIOGEN o que está aberto (o cliente pode ter respondido e a Mari coletado mais dado).
  // Mantém a etapa escolhida, os resultados do preenchimento e o nº do pedido digitado.
  async function planoDaConversa(c) {
    if (!c.plano_escolhido) return null;
    const p = await api(`/rest/v1/config_planos?select=nome&codigo=eq.${encodeURIComponent(c.plano_escolhido)}`).catch(() => null);
    return (p && p[0] && p[0].nome) || c.plano_escolhido;
  }
  async function atualizarTudo() {
    if (S.atualizando) return;
    S.atualizando = true; desenha();
    try {
      if (S.dados) {
        const convId = S.conversa && S.conversa.id;
        let conv = null;
        if (convId && podeVerConversas()) {
          const r = await api(`/rest/v1/mari_conversas?select=${encodeURIComponent(COLS_CONV)}&id=eq.${encodeURIComponent(convId)}`);
          conv = (r && r[0]) || null;
        }
        if (S.venda) {
          const d = await rpc('dados_portal', { p_venda_id: S.venda.venda_id });
          if (!d) throw new Error('Não achei mais essa venda (ou você perdeu o acesso).');
          S.dados = d; S.venda = { ...S.venda, cliente_nome: (d.cliente && d.cliente.nome) || S.venda.cliente_nome };
          if (conv) S.conversa = conv;
        } else if (conv) {
          S.conversa = conv; S.dados = dadosDaConversa(conv, await planoDaConversa(conv));
        } else if (convId) {
          throw new Error('Essa conversa não está mais disponível.');
        }
        if (S.conversa && (S.orelha === 'conversa' || S.turnos != null)) await carregaTurnos();
        aviso('Dados atualizados.', 'ok');
      } else {
        await Promise.all([carregaFila(), carregaConversas()]);
        aviso('Listas atualizadas.', 'ok');
      }
    } catch (e) { aviso(e.message, 'bad'); }
    S.atualizando = false; desenha();
  }

  async function abreConversa(c, orelha) {
    S.ocupado = true; aviso(''); desenha();
    try {
      const plano = await planoDaConversa(c);
      S.venda = null; S.conversa = c; S.dados = dadosDaConversa(c, plano);
      S.resultados = {}; S.matricula = ''; S.pedido = ''; S.os = ''; S.etapaManual = null; S.orelha = orelha || 'portal'; S.turnos = null; S.turnosErro = '';
      window.scrollTo(0, 0);
      if (S.orelha === 'conversa') carregaTurnos();
      try { await mandar({ tipo: 'estado?' }); } catch (e) { /* aviso aparece ao preencher */ }
    } catch (e) { aviso(e.message, 'bad'); }
    S.ocupado = false; desenha();
  }
  async function abreVenda(item) {
    S.ocupado = true; aviso(''); desenha();
    try {
      const d = await rpc('dados_portal', { p_venda_id: item.venda_id });
      if (!d) throw new Error('Não achei essa venda (ou você não tem acesso).');
      S.venda = item; S.dados = d; S.resultados = {}; S.matricula = ''; S.pedido = ''; S.os = ''; S.etapaManual = null;
      // 0102 (trava B1): avisos de possível duplicado (⚠️ ↩️ 🏠 📱) da ficha única — com aviso, o Gravar pede a conferência.
      S.selos = []; S.conferiRecompra = false;
      try { const av = await rpc('ficha_avisos', { p_venda: item.venda_id }); S.selos = ((av && av.selos) || []).filter((x) => x.venda_id !== item.venda_id); } catch (e) { S.selos = []; }
      S.orelha = 'portal'; S.turnos = null; S.turnosErro = ''; S.conversa = null;
      // a conversa da Mari que gerou a venda (se houver e se o perfil enxerga) — alimenta a orelha "Conversa"
      if (podeVerConversas()) {
        const r = await api(`/rest/v1/mari_conversas?select=${encodeURIComponent(COLS_CONV)}&venda_id=eq.${encodeURIComponent(item.venda_id)}`
          + '&order=created_at.desc&limit=1').catch(() => null);
        S.conversa = (r && r[0]) || null;
      }
      window.scrollTo(0, 0);
      try { await mandar({ tipo: 'estado?' }); } catch (e) { /* aviso aparece ao preencher */ }
    } catch (e) { aviso(e.message, 'bad'); }
    S.ocupado = false; desenha();
  }
  async function voltar() {
    S.venda = null; S.dados = null; S.resultados = {}; S.matricula = ''; S.pedido = ''; S.os = ''; aviso('');
    S.conversa = null; S.turnos = null; S.orelha = 'portal';
    try { await mandar({ tipo: 'limpar' }); } catch (e) { /* ok */ }
    desenha();
    if (S.aba === 'conversas') carregaConversas(); else carregaFila();
  }
  function trocaOrelha(o) {
    S.orelha = o; desenha();
    if (o === 'conversa' && S.conversa && S.turnos == null && !S.turnosCarregando) carregaTurnos();
  }
  function trocaAba(a) {
    S.aba = a; desenha();
    if (a === 'conversas' && S.convs == null) carregaConversas();
  }
  // rev. 08/11 — rola o painel até o bloco da etapa (o cabeçalho fixo fica de fora pelo scroll-margin-top do CSS)
  function rolarPara(n, bloco) {
    const el = document.getElementById(`etapa-${n}`);   // desenha() já trocou o DOM (síncrono)
    if (el) el.scrollIntoView({ behavior: 'smooth', block: bloco || 'start' });
  }
  const etapaAtual = () => S.etapaManual || S.etapaAuto;

  async function preencherEtapa(n) {
    const campos = camposDaEtapa(n);
    let fechou = false;
    S.ocupado = true; aviso(''); desenha();
    try {
      const r = await mandar({ tipo: 'preencher', campos });
      const mapa = {}; (r.resultados || []).forEach((x) => { mapa[x.id] = x.estado; });
      S.resultados[n] = campos.map((c) => ({ id: c.id, estado: mapa[c.id] || 'nao_achado' }));
      const ok = S.resultados[n].filter((x) => ['ok', 'ja', 'destacado'].includes(x.estado)).length;
      // Etapa fechada (tudo escrito/destacado, ou o que falta é dado que não temos) → o painel desce para a próxima.
      // Se algum campo pede você (não apareceu ainda, opção ambígua, portal recusou), fica nesta etapa mostrando o resultado.
      fechou = n < 7 && S.resultados[n].every((x) => ['ok', 'ja', 'destacado', 'sem_valor'].includes(x.estado));
      if (ok && S.dados.venda_id) { api('/rest/v1/eventos_venda', { method: 'POST', headers: { Prefer: 'return=minimal' },
        body: { venda_id: S.dados.venda_id, tipo: n === 5 ? 'portal_extensao_destacado' : 'portal_extensao_preenchido', detalhe: { etapa: n, campos: ok } } }).catch(() => {}); }
      aviso(n === 5 ? 'Destaquei no portal o que a venda tem. Confira e clique você.' : 'Pronto — confira os campos no portal e clique você mesmo em Buscar/Avançar.', 'ok');
    } catch (e) { aviso(e.message, 'bad'); }
    S.ocupado = false; desenha();
    if (fechou) rolarPara(n + 1); else if (S.resultados[n]) rolarPara(n, 'nearest');
  }
  // 0092: registra no NIOGEN o que o portal respondeu (viabilidade na etapa 2, crédito na etapa 3) — o mesmo botão da ficha.
  // 0111 (Ricardo, 10/11): o nº do pedido só existe na OS. Crédito aprovado aqui = etapa Biometria no NIOGEN (etiqueta + aviso do link).
  const aprovou = (qual, resultado) => qual === 'credito' && ['aprovado', 'so_cartao'].includes(resultado);
  async function registra(qual, resultado) {
    if (!S.dados || !S.dados.venda_id) { aviso('Abra uma venda para registrar.', 'bad'); desenha(); return; }
    if (aprovou(qual, resultado) && (S.selos || []).length && !S.conferiRecompra) {
      aviso('Marque "Conferi: não é cliente nem endereço Nio" — há aviso de possível duplicado nesta venda.', 'bad'); desenha(); return;
    }
    S.ocupado = true; aviso(''); desenha();
    try {
      if (aprovou(qual, resultado) && (S.selos || []).length) {
        try { await rpc('venda_conferencia_recompra', { p_venda: S.dados.venda_id, p_selos: S.selos.map((x) => x.tipo), p_origem: 'extensao' }); } catch (e) { /* não segura a venda */ }
      }
      const r = await rpc('backoffice_momento', { p_venda: S.dados.venda_id, p_momento: qual, p_dados: { resultado, origem: 'extensao', sem_aviso: !!S.semAviso } });
      S.registro = { ...(S.registro || {}), [qual]: resultado };
      aviso(`${(r && r.resumo) || 'Registrado no NIOGEN'}${r && r.aviso ? ` · ${r.aviso}` : ''}`, r && r.aviso ? 'bad' : 'ok');
    } catch (e) { aviso(e.message, 'bad'); }
    S.ocupado = false; desenha();
  }
  async function concluiVenda() {
    S.fila = (S.fila || []).filter((x) => x.venda_id !== (S.venda || {}).venda_id);
    S.venda = null; S.dados = null; S.resultados = {}; S.pedido = ''; S.os = ''; S.matricula = ''; S.semAviso = false; S.registro = null;
    S.conversa = null; S.turnos = null; S.orelha = 'portal'; S.aba = 'vendas';
    try { await mandar({ tipo: 'limpar' }); } catch (e) { /* ok */ }
    aviso('');
    desenha();
  }
  async function gravaPedido() {   // legado (antes de 0111); sem botão desde 10/11
    const ped = S.pedido.trim();
    if (!ped) { aviso('Digite o número do pedido que o portal mostrou.', 'bad'); desenha(); return; }
    if ((S.selos || []).length && !S.conferiRecompra) {
      aviso('Marque "Conferi: não é cliente nem endereço Nio" — há aviso de possível duplicado nesta venda.', 'bad'); desenha(); return;
    }
    S.ocupado = true; aviso(''); desenha();
    try {
      if ((S.selos || []).length) {
        try { await rpc('venda_conferencia_recompra', { p_venda: S.dados.venda_id, p_selos: S.selos.map((x) => x.tipo), p_origem: 'extensao' }); } catch (e) { /* não segura a venda */ }
      }
      // 0082 (fluxo único do backoffice): o momento "pedido" grava o nº e, sozinho, põe a etiqueta biometria-pendente, deixa a
      // nota e avisa o cliente na conversa (janela de 24 h; sem teto de contatos desde 10/11).
      const r = await rpc('backoffice_momento', { p_venda: S.dados.venda_id, p_momento: 'pedido', p_dados: { pedido: ped, origem: 'extensao', sem_aviso: !!S.semAviso } });
      const nome = S.venda.cliente_nome;
      S.fila = (S.fila || []).filter((x) => x.venda_id !== S.venda.venda_id);
      S.venda = null; S.dados = null; S.resultados = {}; S.pedido = ''; S.os = ''; S.matricula = ''; S.semAviso = false; S.registro = null;
      S.conversa = null; S.turnos = null; S.orelha = 'portal'; S.aba = 'vendas';
      try { await mandar({ tipo: 'limpar' }); } catch (e) { /* ok */ }
      aviso(`Pedido gravado no NIOGEN (${nome}). ${(r && r.resumo) || ''}${r && r.aviso ? ` · ${r.aviso}` : ' · o cliente é avisado pelo sistema.'}`, r && r.aviso ? 'bad' : 'ok');
    } catch (e) {
      aviso(/duplicate|unique|23505/i.test(e.message) ? 'Esse número de pedido já está em outra venda do NIOGEN.' : e.message, 'bad');
    }
    S.ocupado = false; desenha();
  }

  // ------------------------------------------------------------------ telas
  function telaLogin() {
    const erro = h('div', { class: 'erro', id: 'login-erro' });
    const form = h('form', { class: 'card', onsubmit: async (ev) => {
      ev.preventDefault();
      const fd = new FormData(form);
      erro.textContent = ''; btn.disabled = true;
      try { await entrar(String(fd.get('email') || '').trim(), String(fd.get('senha') || '')); await abaAtiva(); try { await mandar({ tipo: 'estado?' }); } catch (e) { /* ok */ } desenha(); carregaFila(); carregaConversas(); }
      catch (e) { erro.textContent = e.message; btn.disabled = false; }
    } },
      h('h2', {}, 'Entrar com o seu login do NIOGEN'),
      h('label', { class: 'campo' }, 'E-mail', h('input', { type: 'email', name: 'email', autocomplete: 'username', required: true })),
      h('label', { class: 'campo' }, 'Senha', h('input', { type: 'password', name: 'senha', autocomplete: 'current-password', required: true })),
      erro);
    const btn = h('button', { class: 'btn btn-acc btn-bloco', type: 'submit' }, 'Entrar');
    form.append(btn);
    return [form, h('p', { class: 'sub' }, 'A extensão só escreve nos campos do Novo Pedido. Quem clica em Buscar, Avançar e em tudo mais é você.')];
  }

  function orelhas(lista, ativa, onTroca, cls) {
    return h('div', { class: `orelhas ${cls || ''}`, role: 'tablist' }, lista.map(([id, rot]) =>
      h('button', { class: `orelha${ativa === id ? ' ativa' : ''}`, type: 'button', role: 'tab', 'aria-selected': ativa === id ? 'true' : 'false',
        onclick: () => onTroca(id) }, rot)));
  }
  // ------------------------------------------------------------------ 0.4.0 — Histórico de Pedidos → NIOGEN (status do portal)
  // A leitura roda no content.js (só cliques da lista branca: filtros, Filtrar, paginação). Aqui: um lote, UMA chamada
  // portal_status_registrar(p_lote) e o resumo. Dado de cliente só em memória; nada em storage, nada em console.
  async function atualizarStatusPortal() {
    if (S.hist && S.hist.rodando) return;
    S.hist = { rodando: true, progresso: ['Começando… não mexa no portal até terminar (~1 min).'] };
    desenha();
    let r;
    try { r = await mandar({ tipo: 'historico_ler' }); }
    catch (e) { S.hist = { erro: e.message }; desenha(); return; }
    if (!r) { S.hist = { erro: 'O portal não respondeu. Recarregue a página do Histórico (F5) e tente de novo.' }; desenha(); return; }
    const pedidos = r.pedidos || [];
    try {
      const res = await rpc('portal_status_registrar', { p_lote: { pedidos, completa: !!r.ok, parou_em: r.ok ? null : (r.parou_em || null), periodo: r.periodo || null } });
      S.hist = { resumo: res.resumo, detalhes: (res.detalhes || []).filter((d) => d.alerta || d.feito || !d.venda),
        erro: r.ok ? null : `Parou em "${r.parou_em}": ${r.erro}. O que já tinha sido lido foi gravado.`, feitas: r.feitas || [], periodo: r.periodo };
    } catch (e) {
      S.hist = { erro: `A leitura terminou, mas o NIOGEN recusou o lote: ${e.message}` };
    }
    desenha();
  }
  async function testarListaBranca() {
    try { const r = await mandar({ tipo: 'historico_teste_lista_branca' }); aviso(r.ok ? `Lista branca OK — ${r.msg}` : r.msg, r.ok ? 'ok' : 'bad'); }
    catch (e) { aviso(e.message, 'bad'); }
    desenha();
  }
  function telaHistorico() {
    if (!S.naHistorico || !podeVerConversas()) return null;
    const H = S.hist || {};
    return h('div', { class: 'card' },
      h('h2', {}, 'Status do portal → NIOGEN'),
      h('span', { class: 'sub' }, 'Lê o Histórico de Pedidos (Venda: os 7 status; Pré-Venda e Interesse) dos últimos 30 dias e atualiza o andamento das vendas no NIOGEN. Só clica nos filtros, em Filtrar e na paginação.'),
      h('button', { class: 'btn btn-acc btn-bloco', type: 'button', onclick: atualizarStatusPortal, disabled: !!H.rodando },
        H.rodando ? 'Lendo o portal…' : 'Atualizar status no NIOGEN'),
      H.rodando && H.progresso ? h('ul', { class: 'lista sub' }, H.progresso.map((t) => h('li', {}, t))) : null,
      H.resumo ? h('div', { class: 'resultado ok' }, `✓ ${H.resumo}`) : null,
      H.periodo ? h('span', { class: 'sub' }, `Período lido: ${H.periodo}`) : null,
      H.erro ? h('div', { class: 'erro' }, H.erro) : null,
      H.detalhes && H.detalhes.length ? h('ul', { class: 'lista' }, H.detalhes.map((d) => h('li', {},
        h('b', {}, d.pedido), ` · ${d.status}`, d.feito ? ` · ${d.feito}` : '', !d.venda ? ' · sem venda no NIOGEN (casar na Minha vez)' : '',
        d.alerta ? h('div', { class: 'resultado bad' }, d.alerta) : null))) : null,
      h('button', { class: 'btn btn-sm', type: 'button', onclick: testarListaBranca, title: 'Tenta clicar "Detalhar" pelo código: tem que ser recusado' }, 'Testar a trava de cliques'));
  }

  function telaInicio() {
    const nV = S.fila ? ` (${S.fila.length})` : '', nC = S.convs && podeVerConversas() ? ` (${S.convs.length})` : '';
    return [orelhas([['vendas', `Prontas para o portal${nV}`], ['conversas', `Conversas da Mari${nC}`]], S.aba, trocaAba),
      S.aba === 'conversas' ? telaConversas() : telaFila()];
  }

  function telaConversas() {
    if (!podeVerConversas()) return h('p', { class: 'sub' }, 'As conversas da Mari aparecem só para admin e backoffice.');
    const b = semAcento(S.busca).trim(), bDig = so(S.busca);
    const lista = (S.convs || []).filter((c) => !b || semAcento([nomeConversa(c), c.cidade, c.endereco_cep && c.endereco_cep.bairro].join(' ')).includes(b)
      || (bDig.length >= 3 && so(c.telefone).includes(bDig)));
    const itens = lista.map((c) => {
      const d = c.dados || {}, ec = c.endereco_cep || {};
      const temEnd = !!(c.cep && c.numero), temDoc = !!so(d.cpf);
      return h('div', { class: 'item item-duplo' },
        h('button', { class: 'item-corpo', type: 'button', onclick: () => abreConversa(c) },
        h('b', {}, nomeConversa(c)),
        h('span', { class: 'meta' }, [ec.bairro, c.cidade].filter(Boolean).join(' · ') || 'sem endereço ainda'),
        h('span', { class: 'meta' }, `Mari: ${ETAPA_MARI[c.etapa] || c.etapa}${c.status === 'handoff_realizado' ? ' · com o time' : ''} · ${ha(c.ultima_msg_lead_at || c.updated_at)}`),
        h('span', {},
          h('span', { class: `chip ${temEnd ? 'ok' : 'bad'}` }, temEnd ? 'CEP e número' : 'sem CEP/número'), ' ',
          h('span', { class: `chip ${temDoc ? 'ok' : ''}` }, temDoc ? 'CPF' : 'sem CPF'), ' ',
          c.venda_id ? h('span', { class: 'chip acc' }, 'já é venda') : null)),
        h('button', { class: 'btn btn-sm item-ler', type: 'button', title: 'Ler a conversa do Chatwoot', onclick: () => abreConversa(c, 'conversa') }, '💬 Ler conversa'));
    });
    return [
      h('div', { class: 'card' },
        h('div', { style: 'display:flex;align-items:center;gap:8px' }, h('h2', { style: 'flex:1' }, 'Conversas em andamento'),
          h('button', { class: 'btn btn-sm', type: 'button', onclick: carregaConversas, disabled: S.convsCarregando }, S.convsCarregando ? 'Atualizando…' : 'Atualizar')),
        h('span', { class: 'sub' }, 'Para consultar o portal antes de a venda ser qualificada. A extensão usa o que a Mari já coletou; o que faltar, pergunte na conversa.'),
        h('input', { type: 'text', id: 'in-busca', placeholder: 'Buscar por nome, telefone, bairro ou cidade', autocomplete: 'off', value: S.busca,
          oninput: (ev) => { S.busca = ev.target.value; desenha(); } }),
        S.convsErro ? h('div', { class: 'erro' }, S.convsErro) : null),
      S.convs && !lista.length && !S.convsErro && !S.convsCarregando ? h('p', { class: 'sub' }, S.busca ? 'Nenhuma conversa com essa busca.' : 'Nenhuma conversa em andamento agora.') : null,
      h('div', { class: 'fila' }, itens),
    ];
  }

  function telaConversa() {
    const c = S.conversa;
    if (!c) return h('p', { class: 'sub' }, podeVerConversas() ? 'Esta venda não tem conversa da Mari ligada a ela.' : 'A conversa aparece só para admin e backoffice.');
    const cw = c.chatwoot_conversation_id
      ? h('a', { class: 'btn btn-sm', target: '_blank', rel: 'noopener', href: `https://app.chatwoot.com/app/accounts/${CHATWOOT_NIO_ACCOUNT}/conversations/${encodeURIComponent(c.chatwoot_conversation_id)}` }, 'Abrir no Chatwoot')
      : null;
    const quem = { lead: nomeConversa(c), mari: 'Mari', humano: 'Time' };
    const baloes = (S.turnos || []).map((t) => {
      const txt = limpa(t.texto);
      if (!txt) return null;
      return h('div', { class: `balao ${t.papel}` }, h('div', { class: 'b-quem' }, `${quem[t.papel] || t.papel} · ${fmtQuando(t.created_at)}`), h('div', { class: 'b-txt' }, txt));
    }).filter(Boolean);
    return h('section', { class: 'card' },
      h('div', { style: 'display:flex;align-items:center;gap:8px' }, h('h2', { style: 'flex:1' }, 'Negociação'),
        h('button', { class: 'btn btn-sm', type: 'button', onclick: carregaTurnos, disabled: S.turnosCarregando }, S.turnosCarregando ? 'Atualizando…' : 'Atualizar'), cw),
      h('span', { class: 'sub' }, `Mari: ${ETAPA_MARI[c.etapa] || c.etapa}${c.status === 'handoff_realizado' ? ' · com o time' : ''} · última mensagem do cliente ${ha(c.ultima_msg_lead_at) || '—'}. Só leitura — responda pelo Chatwoot.`),
      S.turnosErro ? h('div', { class: 'erro' }, S.turnosErro) : null,
      S.turnos == null && !S.turnosErro ? h('p', { class: 'sub' }, 'Carregando a conversa…')
        : h('div', { class: 'conversa', id: 'conv-box' }, baloes.length ? baloes : h('p', { class: 'sub' }, 'Sem mensagens.')));
  }

  function telaFila() {
    // A matrícula é sempre a TT837725: o "falta a matrícula do vendedor" que a RPC ainda devolve (0050) não vale.
    const faltasDe = (x) => (x.faltas || []).filter((f) => f !== 'a matrícula do vendedor');
    const itens = (S.fila || []).map((x) => h('button', { class: 'item', type: 'button', onclick: () => abreVenda(x) },
      h('b', {}, x.cliente_nome || '—'),
      h('span', { class: 'meta' }, [x.bairro, x.cidade].filter(Boolean).join(' · ') || 'sem endereço'),
      h('span', { class: 'meta' }, x.plano_nome || 'sem plano'),
      faltasDe(x).length ? h('span', { class: 'chip bad' }, `falta ${faltasDe(x).join(', ')}`) : h('span', { class: 'chip ok' }, 'dados completos')));
    return [
      h('div', { class: 'card' },
        h('div', { style: 'display:flex;align-items:center;gap:8px' }, h('h2', { style: 'flex:1' }, 'Prontas para o portal'),
          h('button', { class: 'btn btn-sm', type: 'button', onclick: carregaFila, disabled: S.carregando }, S.carregando ? 'Atualizando…' : 'Atualizar')),
        h('span', { class: 'sub' }, 'Vendas Qualificadas, ainda sem número de pedido. Escolha uma para ver os dados.'),
        S.filaErro ? h('div', { class: 'erro' }, S.filaErro) : null),
      S.fila && !S.fila.length && !S.filaErro ? h('p', { class: 'sub' }, 'Nenhuma venda pronta agora.') : null,
      h('div', { class: 'fila' }, itens),
    ];
  }

  function blocoEtapa(n) {
    const atual = etapaAtual() === n;
    const linhas = linhasEtapa(n);
    const falt = faltasDaEtapa(n);
    const res = {}; (S.resultados[n] || []).forEach((r) => { res[r.id] = r.estado; });
    const corpo = linhas.map(([rot, val, obrig, conf, nota]) => {
      const sem = !val && obrig;
      const vEl = val ? h('span', { class: `val${conf ? ' conf' : ''}` }, val) : sem ? h('span', { class: 'val falta' }, 'falta') : h('span', { class: 'val conf' }, nota || '—');
      return h('div', { class: 'linha' }, h('span', { class: 'rot' }, rot), h('span', {}, vEl), h('span'));
    });
    const resultados = (S.resultados[n] || []).map((r) => {
      const [t, cls] = TXT_ESTADO[r.estado] || [r.estado, 'warn'];
      return h('div', { class: `resultado ${cls}` }, `${rotuloCampo(r.id)}: ${t}`);
    });
    const podePreencher = PREENCHE.includes(n), podeDestacar = n === 5;
    const acao = podePreencher || podeDestacar
      ? h('button', { class: `btn ${atual ? 'btn-acc' : ''} btn-bloco`, type: 'button', disabled: S.ocupado, onclick: () => preencherEtapa(n) },
        podeDestacar ? 'Destacar no portal' : 'Preencher esta etapa') : null;
    const extraTxt = n === 2 ? 'Depois de preencher, clique você em Buscar e escolha "Endereço de instalação". Aí volte e preencha de novo para a referência e o complemento.'
      : n === 3 ? 'Depois de preencher, clique você em Buscar (o nome vem da Receita).'
      : n === 5 ? 'Crédito, oferta, forma de pagamento e dados bancários são com você: eu só destaco o que a venda tem. Banco, agência e conta, nunca.'
      : n === 6 || n === 7 ? 'Nada é preenchido aqui. Antes da biometria, o cliente precisa ter ouvido:' : '';
    return h('section', { class: 'card', id: `etapa-${n}` },
      h('div', { class: `etapa-tit${atual ? ' atual' : ''}` }, `Etapa ${n} · ${ETAPAS[n - 1]}${atual ? ' — aberta no portal' : ''}`,
        ' ', falt ? h('span', { class: 'chip bad' }, `${falt} ${falt === 1 ? 'falta' : 'faltam'}`) : null),
      corpo, extraTxt ? h('span', { class: 'sub' }, extraTxt) : null,
      n === 6 || n === 7 ? h('ul', { class: 'lista sub' }, CHECKLIST.map((x) => h('li', {}, x))) : null,
      acao, resultados, registroNiogen(n));
  }
  // 0092: botões "registrar no NIOGEN" das etapas 2 (viabilidade) e 3 (crédito). Só com venda aberta no painel.
  function registroNiogen(n) {
    if (!S.venda || !S.dados || !S.dados.venda_id || (n !== 2 && n !== 3)) return null;
    const feito = (S.registro || {})[n === 2 ? 'viabilidade' : 'credito'];
    const B = (qual, res, rot, forte) => h('button', { class: `btn ${forte ? 'btn-acc' : ''}`, type: 'button', disabled: S.ocupado, onclick: () => registra(qual, res) }, rot);
    const ROT = { viavel: 'Viável', sem_viabilidade: 'Sem viabilidade', nao_encontrado: 'Endereço não encontrado', aprovado: 'Aprovado', so_cartao: 'Só cartão', pendente: 'Pendente', negado: 'Negado' };
    return h('div', { class: 'registro' },
      h('span', { class: 'sub' }, n === 2 ? 'O portal respondeu a viabilidade? Registre no NIOGEN:' : 'O portal respondeu o crédito? Registre no NIOGEN:'),
      n === 2 ? h('div', { class: 'acoes' }, B('viabilidade', 'viavel', 'Viável', true), B('viabilidade', 'sem_viabilidade', 'Sem viabilidade'), B('viabilidade', 'nao_encontrado', 'Não encontrado'))
        : h('div', { class: 'acoes' }, B('credito', 'aprovado', 'Aprovado', true), B('credito', 'so_cartao', 'Só cartão'), B('credito', 'pendente', 'Pendente'), B('credito', 'negado', 'Negado')),
      n === 3 ? h('label', { class: 'check' }, h('input', { type: 'checkbox', checked: !!S.semAviso, onchange: (ev) => { S.semAviso = ev.target.checked; } }),
        ' Já avisei o cliente do link da biometria (o NIOGEN não manda o aviso)') : null,
      n === 3 && (S.selos || []).length ? h('div', { class: 'aviso bad' },
        h('span', {}, `${S.selos.map((x) => ({ duplicado: '⚠️', saida: '↩️', dfv: '🏠', telefone: '📱' })[x.tipo] || '⚠️').join(' ')} ${S.selos.map((x) => x.texto).join(' · ')}`),
        h('label', { class: 'check' }, h('input', { type: 'checkbox', checked: !!S.conferiRecompra, onchange: (ev) => { S.conferiRecompra = ev.target.checked; desenha(); } }),
          ' Conferi: não é cliente nem endereço Nio (recompra = multa R$ 500; já Nio = estorno 100 %)')) : null,
      n === 3 ? h('span', { class: 'sub' }, 'Aprovado: a venda vai para Biometria e o NIOGEN avisa o cliente do link sozinho. Não há nº de pedido aqui — ele só existe na OS.') : null,
      feito ? h('span', { class: 'sub ok' }, `✓ registrado: ${ROT[feito] || feito}`) : null);
  }

  function fimDoPedido() {
    if (S.venda) {
      // 0111: sem nº de pedido aqui (só existe na OS, gravada pela ficha depois da biometria validada).
      const cred = (S.registro || {}).credito;
      const ok = ['aprovado', 'so_cartao'].includes(cred);
      return h('section', { class: 'card' },
        h('h2', {}, ok ? 'Crédito aprovado → biometria' : 'Falta o crédito'),
        h('span', { class: 'sub' }, ok
          ? 'A Nio manda o link da biometria ao cliente e o NIOGEN já avisou. Com a biometria validada, abra a OS e grave o nº do pedido (= OS) na ficha do NIOGEN.'
          : 'Registre o resultado do crédito na etapa 3 acima — é ele que leva a venda para Biometria. O nº do pedido só existe na OS.'),
        h('button', { class: 'btn btn-bloco', type: 'button', disabled: S.ocupado, onclick: concluiVenda }, 'Concluir e fechar esta venda'));
    }
    const c = S.conversa;
    return h('section', { class: 'card' },
      h('h2', {}, 'Ainda não é venda'),
      c && c.venda_id
        ? [h('span', { class: 'sub' }, 'Esta conversa já virou venda no NIOGEN. Para gravar o número do pedido, abra a venda.'),
          h('button', { class: 'btn btn-bloco', type: 'button', disabled: S.ocupado, onclick: () => abreVenda({ venda_id: c.venda_id, cliente_nome: nomeConversa(c) }) }, 'Abrir a venda')]
        : h('span', { class: 'sub' }, 'Daqui dá para consultar a viabilidade e adiantar o pedido. O número do pedido só se grava depois que a venda existir no NIOGEN (Mari ou vendedor qualifica).'));
  }

  function telaVenda() {
    const d = S.dados, n = etapaAtual();
    const titulo = S.venda ? (S.venda.cliente_nome || '—') : nomeConversa(S.conversa || {});
    const cab = h('div', { class: 'card' },
      h('div', { style: 'display:flex;align-items:center;gap:8px' },
        h('div', { style: 'flex:1' }, h('h2', {}, titulo),
          h('span', { class: 'sub' }, [d.viabilidade.bairro, d.viabilidade.cidade].filter(Boolean).join(' · ')),
          !S.venda ? h('div', {}, h('span', { class: 'chip acc' }, 'Conversa da Mari · sem venda qualificada')) : null),
        h('button', { class: 'btn btn-sm', type: 'button', onclick: voltar }, S.aba === 'conversas' ? '← Conversas' : '← Vendas')),
      orelhas([['portal', 'Preencher no portal'], ['conversa', '💬 Conversa (Chatwoot)']], S.orelha, trocaOrelha, 'orelhas-sub'));
    if (S.orelha === 'conversa') return [cab, telaConversa()];
    const avisosPortal = S.avisos.map((a) => h('div', { class: 'aviso' }, h('b', {}, 'O portal avisou: '), a.msg));
    const regua = h('div', { class: 'regua' }, ETAPAS.map((_, i) => h('span', { class: n === i + 1 ? 'atual' : n && i + 1 < n ? 'feito' : '' })));
    const seletor = h('label', { class: 'campo' }, 'Etapa (automática; troque se eu errar)',
      h('select', { id: 'sel-etapa', onchange: (ev) => { S.etapaManual = ev.target.value ? Number(ev.target.value) : null; desenha(); } },
        h('option', { value: '' }, S.etapaAuto ? `Automática — etapa ${S.etapaAuto} · ${ETAPAS[S.etapaAuto - 1]}` : 'Automática — não identifiquei a etapa'),
        ETAPAS.map((nome, i) => h('option', { value: i + 1, selected: S.etapaManual === i + 1 }, `${i + 1} · ${nome}`))));
    const ordem = [1, 2, 3, 4, 5, 6, 7];
    cab.append(regua, seletor);
    return [
      cab,
      avisosPortal,
      !n ? h('div', { class: 'dica' }, 'Abra o Novo Pedido no portal (menu Novo Pedido) para eu identificar a etapa.') : null,
      ordem.map(blocoEtapa),
      fimDoPedido(),
    ];
  }

  function desenha() {
    const ativo = document.activeElement; const idAtivo = ativo && ativo.id; const ini = ativo && ativo.selectionStart; const fim = ativo && ativo.selectionEnd;
    const sair = document.getElementById('sair'), quem = document.getElementById('quem');
    sair.hidden = !S.sess; quem.hidden = !S.sess; quem.textContent = S.nome || '';
    const atu = document.getElementById('atualizar');
    atu.hidden = !S.sess; atu.disabled = S.atualizando || S.ocupado; atu.textContent = S.atualizando ? 'Atualizando…' : 'Atualizar';
    atu.onclick = atualizarTudo;
    sair.onclick = async () => { await sairLocal(); desenha(); };
    // a caixa da conversa guarda a posição (quem rolou para cima para ler não é jogado de volta ao fim a cada redesenho)
    const caixa = document.getElementById('conv-box');
    const posConv = caixa ? { top: caixa.scrollTop, noFim: caixa.scrollTop + caixa.clientHeight >= caixa.scrollHeight - 24 } : null;
    const partes = [];
    if (!S.sess) partes.push(telaLogin());
    else if (S.dados) partes.push(telaVenda());
    else {
      if (S.avisos.length) partes.push(S.avisos.map((a) => h('div', { class: 'aviso' }, h('b', {}, 'O portal avisou: '), a.msg)));
      partes.push(telaHistorico());
      partes.push(telaInicio());
    }
    // rev. 08/11: o recado vai num aviso fixo no rodapé — o painel rola até a próxima etapa e o recado continua à vista
    if (S.msg) partes.push(h('div', { class: `toast ${S.msg.tipo === 'bad' ? 'bad' : 'ok'}`, role: 'status' },
      h('span', { class: 'grow' }, S.msg.texto), h('button', { class: 'btn btn-sm', type: 'button', 'aria-label': 'Fechar', onclick: () => { aviso(''); desenha(); } }, '×')));
    raiz.replaceChildren(...partes.flat(Infinity).filter(Boolean));
    const nova = document.getElementById('conv-box');
    if (nova) nova.scrollTop = posConv && !posConv.noFim ? posConv.top : nova.scrollHeight;
    if (idAtivo) { const el = document.getElementById(idAtivo); if (el) { el.focus(); try { if (ini != null) el.setSelectionRange(ini, fim); } catch (e) { /* select/email */ } } }
  }

  // ------------------------------------------------------------------ início
  (async () => {
    try {
      const guardada = await lerSessaoGuardada();
      if (guardada) { S.sess = guardada; const rn = await renovar(); if (rn !== false) { await carregaPerfil(); } else { await sairLocal(); } }
    } catch (e) { S.sess = null; }
    await abaAtiva();
    desenha();
    if (S.sess) { try { await mandar({ tipo: 'estado?' }); } catch (e) { /* ok */ } carregaFila(); carregaConversas(); }
  })();
})();
