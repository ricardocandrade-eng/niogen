/* NIOGEN | extensao/travas.js | 12/11/2026 — Claude Code (docs/Prompt_extensao_ate_resumo_121126_0100.md)
 * As travas da condução "Conduzir até o Resumo" — FUNÇÕES PURAS (sem DOM, sem chrome.*), testadas em testar_travas.mjs.
 * Carregado antes do content.js (content script) e pelo panel.html; no node, o teste avalia este arquivo num contexto vazio.
 *
 * Regra 5 do CLAUDE.md (rev. 12/11/2026): o robô percorre as Etapas 1–5 e PARA no Resumo sem salvar. Só o humano clica no que
 * grava o pedido ou manda algo ao cliente (checkout, Abrir OS, biometria, link de pagamento, agendamento). Nunca: Salvar interesse,
 * oferta/pagamento diferente da venda, cartão, conta (DACC), "Seguir fora da área". Portado do portal/credito.py (operador).
 * Regra 15: textos das listas de trava e regras de rede ficam AQUI, fora do código de condução.
 */
(function (raiz) {
  'use strict';
  const norm = (s) => String(s == null ? '' : s).normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/\s+/g, ' ').trim().toLowerCase();
  // texto de botão sem setas, ícones e pontuação ("Avançar →" → "avancar")
  const textoBotao = (s) => norm(s).replace(/[^a-z0-9 ]+/g, ' ').replace(/\s+/g, ' ').trim();

  // ------------------------------------------------------------------ cliques
  // Lista negra: vale SEMPRE, em qualquer etapa, contra o texto normalizado do alvo (contém).
  const LISTA_NEGRA = ['salvar interesse', 'abrir os', 'enviar', 'enviar link', 'finalizar', 'confirmar', 'concluir pedido', 'checkout',
    'carregar', 'reenviar', 'seguir fora da area', 'consultar outro cpf', 'fechar pedido', 'gerar pedido', 'agendar'];
  // Lista branca de BOTÕES por etapa (texto exato, normalizado). Popup tem lista própria (abaixo).
  const BOTOES = {
    1: ['avancar'],
    2: ['buscar', 'avancar'],
    3: ['buscar', 'avancar'],
    4: ['avancar'],
    5: ['avancar', 'selecionar', 'escolher', 'selecionar oferta', 'escolher oferta'],
  };
  // Botões de POPUP que não mandam nada: Continuar do modal de viabilidade (Etapa 2, texto "disponível") e "Tentar novamente"
  // do erro da Receita (Etapa 3). Qualquer outro botão de popup = para e chama o humano.
  const POPUP = { 2: ['continuar'], 3: ['tentar novamente'] };
  // Que tipo de alvo cada etapa aceita além de botão: opção de lista (li/option) e caixa (radio/checkbox).
  const OPCAO = { 1: true, 2: true, 3: false, 4: false, 5: false };
  const CAIXA = { 1: false, 2: true, 3: false, 4: true, 5: true };
  // Popup que fala disso manda algo ao cliente (ou é dinheiro): nunca é a extensão que clica.
  const RE_POPUP_ENVIA = /biometria|link|enviar|envio|enviad|pagamento|cartao|cliente recebera|ao cliente/;

  function naListaNegra(texto) {
    const t = norm(texto);
    return LISTA_NEGRA.find((p) => t.includes(p)) || null;
  }
  const popupSeguro = (texto) => !RE_POPUP_ENVIA.test(norm(texto));

  /** Pode clicar? alvo = { tipo: 'botao' | 'opcao' | 'caixa', texto, etapa, popup?: { texto } }. Devolve { ok, motivo }. */
  function conferirClique(alvo) {
    const a = alvo || {};
    const etapa = Number(a.etapa) || 0;
    const negra = naListaNegra(a.texto);
    if (negra) return { ok: false, motivo: `lista negra: "${negra}"` };
    if (etapa < 1 || etapa > 5) return { ok: false, motivo: `etapa ${etapa || '?'}: a extensão não clica (Resumo e depois são do humano)` };
    if (a.tipo === 'opcao') return OPCAO[etapa] ? { ok: true } : { ok: false, motivo: `opção de lista não é esperada na etapa ${etapa}` };
    if (a.tipo === 'caixa') return CAIXA[etapa] ? { ok: true } : { ok: false, motivo: `caixa de marcar não é esperada na etapa ${etapa}` };
    if (a.tipo !== 'botao') return { ok: false, motivo: 'alvo desconhecido' };
    const t = textoBotao(a.texto);
    if (a.popup) {
      if (!(POPUP[etapa] || []).includes(t)) return { ok: false, motivo: `botão "${t}" de popup na etapa ${etapa} é do humano` };
      if (!popupSeguro(a.popup.texto)) return { ok: false, motivo: 'o popup fala em biometria, link, envio ou pagamento — o clique é do humano' };
      if (etapa === 2 && t === 'continuar' && !/disponi/.test(norm(a.popup.texto))) return { ok: false, motivo: 'Continuar só no modal de viabilidade "disponível"' };
      if (etapa === 2 && /indisponi/.test(norm(a.popup.texto))) return { ok: false, motivo: 'viabilidade indisponível' };
      return { ok: true };
    }
    return (BOTOES[etapa] || []).includes(t) ? { ok: true } : { ok: false, motivo: `"${t}" não está na lista branca da etapa ${etapa}` };
  }

  // ------------------------------------------------------------------ popups (portado de classificar_popup do credito.py)
  function classificarPopup(titulo, texto, etapa) {
    const t = norm(`${titulo || ''} ${texto || ''}`);
    if (/repeticoes de mesmo numero|telefone de contato informado|celular ja utilizado/.test(t)) return 'contato_repetido';
    if (/e-?mail invalido|preencha um e-?mail valido/.test(t)) return 'email_invalido';
    if (/pedido encontrado|ja existe outro pedido|em andamento/.test(t)) return 'pedido_em_andamento';
    if (/ops,? ?ocorreu um erro/.test(t) && etapa === 3) return 'receita_retry';
    if (/fora da area/.test(t)) return 'fora_da_area';
    if (/negad|nao aprovad|sem ofertas/.test(t)) return 'negado';
    if (/credito aprovado/.test(t)) {
      if (/todas as formas/.test(t)) return 'aprovado_todas';
      if (/elegivel (somente |apenas |so )?(para|no|ao) cartao|somente cartao|apenas cartao/.test(t)) return 'aprovado_cartao';
      return 'aprovado_parcial';
    }
    if (/pendente|24 ?h|aguard/.test(t)) return 'pendente';
    if (/nascimento|nome da mae/.test(t)) return 'dados_pessoais';
    return 'nao_classificado';
  }
  // motivo de parada (evento portal_extensao_conduzido) para cada classe de popup
  const MOTIVO_POPUP = { pedido_em_andamento: 'recompra', negado: 'credito', pendente: 'credito', contato_repetido: 'popup',
    email_invalido: 'popup', fora_da_area: 'popup', dados_pessoais: 'popup', nao_classificado: 'popup', receita_retry: 'popup' };

  // ------------------------------------------------------------------ endereço e complemento (portado do credito.py)
  const semAcento = (t) => String(t == null ? '' : t).normalize('NFD').replace(/[̀-ͯ]/g, '');
  const so = (s) => String(s == null ? '' : s).replace(/\D/g, '');
  const esc = (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  /** a opção traz o número como número: 52 casa "Rua X, 52", nunca "520". */
  const temNumero = (opcao, numero) => new RegExp(`(^|[\\s,º°nN.-])${esc(String(numero).trim())}(?!\\d)`).test(String(opcao || ''));
  const RE_BLOCO = /^\s*(?:bl(?:oco)?|torre|tr|ed(?:if[ií]cio)?)\.?\s*([a-z0-9]+)/i;
  const RE_SO_BLOCO = /^\s*(?:bl(?:oco)?|torre|tr|ed(?:if[ií]cio)?)\.?\s*[a-z0-9]+\s*$/i;
  const blocoDe = (t) => { const m = RE_BLOCO.exec(semAcento(t)); return m ? m[1].toLowerCase() : null; };
  const n2 = (t) => semAcento(t).toLowerCase().replace(/\W+/g, '');
  function escolherOpcao(opcoes, valor) {
    const v = n2(valor);
    if (!v) return null;
    const iguais = opcoes.filter((o) => n2(o) === v);
    if (iguais.length) return iguais[0];
    if (/^\d+$/.test(String(valor).trim())) { const num = opcoes.filter((o) => temNumero(o, String(valor).trim())); return num.length === 1 ? num[0] : null; }
    const contem = opcoes.filter((o) => n2(o).includes(v));
    return contem.length === 1 ? contem[0] : null;
  }
  function opcoesQueBatem(opcoes, valor) {
    const v = String(valor || '').trim();
    if (!v) return [];
    if (RE_SO_BLOCO.test(semAcento(v))) { const b = blocoDe(v); return opcoes.filter((o) => blocoDe(o) === b); }
    const b = blocoDe(v), nums = v.match(/\d+/g) || [];
    if (b && nums.length >= 2) return opcoes.filter((o) => blocoDe(o) === b && temNumero(o, nums[nums.length - 1]));
    if (!b && nums.length === 1) return opcoes.filter((o) => temNumero(o, nums[0]));
    return opcoes.filter((o) => n2(v) && n2(o).includes(n2(v)));
  }
  /** Unidade da lista fechada que É a do cliente — nunca troca por outra. { ok, alvo } ou { ok:false, situacao, motivo }. */
  function alvoComplemento(opcoes, valor) {
    let alvo = valor ? escolherOpcao(opcoes, valor) : null;
    const temBlocos = opcoes.some((o) => blocoDe(o));
    if (alvo && n2(alvo) !== n2(valor) && !blocoDe(valor) && temBlocos) alvo = null;
    const batem = valor && !alvo ? opcoesQueBatem(opcoes, valor) : [];
    const comBloco = !!blocoDe(valor) || !temBlocos;
    if (!alvo && batem.length === 1 && comBloco && !RE_SO_BLOCO.test(semAcento(valor))) alvo = batem[0];
    if (alvo) return { ok: true, alvo };
    const situacao = !valor ? 'escolher' : batem.length ? 'ambiguo' : 'nao_encontrado';
    const motivo = { escolher: 'o endereço tem unidades e o portal pede o complemento', ambiguo: `"${valor}" bate com ${batem.length} unidades — escolha a do cliente`,
      nao_encontrado: `complemento "${valor}" não está na lista do portal` }[situacao];
    return { ok: false, situacao, motivo };
  }
  /** endereço do CEP: o da lista com o número exato, ou o único. */
  function alvoEndereco(opcoes, numero) {
    const num = String(numero || '').trim();
    if (num && !/^(s\/?n|sem numero)$/i.test(norm(num))) {
      const com = opcoes.filter((o) => temNumero(o, num));
      if (com.length === 1) return { ok: true, alvo: com[0] };
      if (com.length > 1) return { ok: false, motivo: `${com.length} endereços com o número ${num} — escolha você` };
    }
    if (opcoes.length === 1) return { ok: true, alvo: opcoes[0] };
    return { ok: false, motivo: 'CEP com mais de um endereço e nenhum com o número da venda — escolha você' };
  }

  // ------------------------------------------------------------------ Etapa 5: forma de pagamento e oferta
  // valores do radio-group do portal (credito.py): BOLETO · CREDITO · DACC. DACC = conta corrente: o humano digita → para.
  function formaDaVenda(forma) {
    const f = norm(forma);
    if (f === 'boleto') return { ok: true, valor: 'BOLETO' };
    if (f === 'cartao' || f === 'credito' || f === 'cartao de credito') return { ok: true, valor: 'CREDITO' };
    if (f === 'dacc' || f.includes('debito')) return { ok: false, motivo: 'dacc', texto: 'Venda em DACC (débito em conta): banco, agência e conta são você que digita.' };
    return { ok: false, motivo: 'oferta', texto: `forma de pagamento "${forma || '—'}" da venda não reconhecida` };
  }
  // "R$ 1.234,56" → 1234.56
  const preco = (s) => { const m = /R\$\s*([\d.]+,\d{2})/.exec(String(s || '')); return m ? Number(m[1].replace(/\./g, '').replace(',', '.')) : null; };
  // velocidade em Mb ("1 Giga" → 1000, "700 Mega" → 700)
  function megas(s) {
    const t = norm(s);
    const g = /(\d+(?:[.,]\d+)?)\s*(giga|gbps|gb)\b/.exec(t); if (g) return Math.round(Number(g[1].replace(',', '.')) * 1000);
    const m = /(\d{2,4})\s*(mega|mbps|mb)\b/.exec(t); return m ? Number(m[1]) : null;
  }
  function lerOferta(texto) {
    const linhas = String(texto || '').split(/\r?\n/).map((x) => x.trim()).filter(Boolean);
    const t = norm(texto);
    return { nome: linhas[0] || '', megas: megas(texto), preco: preco(texto), fidelidade: /sem fidelidade/.test(t) ? false : /com fidelidade/.test(t) ? true : null };
  }
  /** Casa a oferta da venda entre os cartões da tela por nome, velocidade e R$/mês da config_planos.
   *  venda = { nomes: [...], megas, precos: [...] }. Exatamente uma → { ok, i }; nenhuma ou várias → para. */
  function casarOferta(cartoes, venda) {
    const nomes = (venda.nomes || []).map(textoBotao).filter(Boolean);
    const precos = (venda.precos || []).filter((x) => x != null).map(Number);
    const casa = (o) => {
      const nomeOk = nomes.some((n) => textoBotao(o.nome) === n || textoBotao(o.nome).includes(n) || n.includes(textoBotao(o.nome)));
      const velOk = !venda.megas || o.megas === Number(venda.megas);
      const precoOk = !precos.length || (o.preco != null && precos.some((p) => Math.abs(p - o.preco) < 0.005));
      return nomeOk && velOk && precoOk && o.megas != null && o.preco != null;
    };
    const idx = cartoes.map((o, i) => (casa(o) ? i : -1)).filter((i) => i >= 0);
    if (idx.length === 1) return { ok: true, i: idx[0] };
    return { ok: false, motivo: 'oferta', texto: idx.length ? `${idx.length} ofertas casam com a venda — escolha você` : 'nenhuma oferta da tela casa com o plano, a velocidade e o preço da venda' };
  }

  // ------------------------------------------------------------------ rede (declarativeNetRequest, regras de sessão por aba)
  // Mesmas rotas do credito.py (rede_bloqueada) + as do prompt. Só pedidos de API/documento; liberadas: consultas da
  // portabilidade (a tela da Etapa 5 quebra sem elas) e a LEITURA do carrinho (GET), se o Resumo precisar.
  const TIPOS = ['xmlhttprequest', 'main_frame', 'sub_frame', 'websocket', 'other', 'ping'];
  const BLOQUEIOS = [
    { id: 1, re: 'aberturaos' },
    { id: 2, re: 'checkout' },
    { id: 3, re: 'carrinho/.*enviar' },
    { id: 4, re: 'biometria' },
    { id: 5, re: '/pagamento/' },
    { id: 6, re: 'reenviolink' },
    { id: 7, re: 'dadosbancarios' },
    { id: 8, re: 'save_lead' },
    { id: 9, re: 'prevenda' },
    { id: 10, re: 'portabilidade' },
    { id: 11, re: 'interesse', posEtapa2: true },
  ];
  const LIBERADOS = [
    // Sem repetição contada ({n,m}): o Chrome (RE2) recusa regex que passe de 2 KB compilada — a 0.6.0 caiu nisso
    // ("Rule with id 7401 … exceeded the 2KB memory limit"). [^/?]* = um segmento só, então …/enviar continua barrado.
    { id: 101, re: 'portabilidadenovafibra/consulta[^/?]*(/[^/?]*)?(\\?.*)?$' },
    { id: 102, re: 'aberturaos/carrinho(/[^/?]*)?(\\?.*)?$', metodos: ['get'] },
  ];
  const ID_BASE = 7300;   // faixa das regras de sessão da condução (não colide com nada; a extensão não tem outras)
  function regrasRede(tabId, posEtapa2) {
    const cond = (r) => ({ regexFilter: r.re, isUrlFilterCaseSensitive: false, resourceTypes: TIPOS, tabIds: [tabId],
      ...(r.metodos ? { requestMethods: r.metodos } : {}) });
    return [
      ...BLOQUEIOS.filter((r) => !r.posEtapa2 || posEtapa2).map((r) => ({ id: ID_BASE + r.id, priority: 1, action: { type: 'block' }, condition: cond(r) })),
      ...LIBERADOS.map((r) => ({ id: ID_BASE + r.id, priority: 2, action: { type: 'allow' }, condition: cond(r) })),
    ];
  }
  const idsRegras = () => [...BLOQUEIOS, ...LIBERADOS].map((r) => ID_BASE + r.id);
  /** O que as regras fazem com uma URL (para o teste e o log): caminho barrado ou null. Liberado ganha do bloqueio (prioridade 2). */
  function redeBloqueada(url, metodo, posEtapa2) {
    const u = String(url || '').toLowerCase();
    const m = String(metodo || 'GET').toLowerCase();
    if (LIBERADOS.some((r) => new RegExp(r.re, 'i').test(u) && (!r.metodos || r.metodos.includes(m)))) return null;
    const b = BLOQUEIOS.find((r) => (!r.posEtapa2 || posEtapa2) && new RegExp(r.re, 'i').test(u));
    return b ? b.re : null;
  }

  // ------------------------------------------------------------------ texto que vai para o NIOGEN (sem CPF/telefone/e-mail)
  const redigir = (s) => String(s || '').replace(/[\w.+-]+@[\w-]+\.[\w.]+/g, '<email>').replace(/\d[\d.\-/() ]{5,}\d/g, '<num>').slice(0, 400);

  raiz.NIOGEN_TRAVAS = { norm, textoBotao, LISTA_NEGRA, BOTOES, POPUP, naListaNegra, popupSeguro, conferirClique, classificarPopup, MOTIVO_POPUP,
    temNumero, escolherOpcao, alvoComplemento, alvoEndereco, formaDaVenda, lerOferta, casarOferta, megas, preco,
    regrasRede, idsRegras, redeBloqueada, redigir, so };
})(typeof globalThis !== 'undefined' ? globalThis : window);
