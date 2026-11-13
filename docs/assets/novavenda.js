/* NIOGEN | docs/assets/novavenda.js | 05/11/2026 01h40 — Claude Code, rodada noturna de layout
 * Gaveta "Nova venda" (venda de rua em 5 passos) como componente: saiu de dentro de vendas.html para a tela Cobertura
 * abrir a MESMA gaveta ("Criar venda com este endereço") sem navegar. O código é o mesmo da v0.7/v0.9 (regras, travas,
 * RPCs checar_duplicidade/checar_recompra e gravação iguais); só mudou: o HTML é injetado daqui, os seletores ficam presos
 * à gaveta e, depois de salvar, quem recarrega a lista é a tela (aoSalvar).
 * Uso: const nv = await NGNovaVenda.montar({ eu, aoSalvar }); nv.abrir() · nv.abrir({ cep, numero, complemento }).
 */
(function () {
  'use strict';
  const HTML = `
<!-- Nova venda de rua: gaveta lateral, 5 passos, um por vez. Regras, travas e gravação iguais às da v0.6.3. -->
<aside class="gaveta" id="gaveta-venda" aria-label="Nova venda de rua" aria-hidden="true">
  <form class="g-form" id="venda-rua" novalidate>
    <div class="g-cab">
      <div>
        <h2>Nova venda de rua</h2>
        <p>PAP ou indicação. Salve como qualificado agora; o pedido sai no portal PAP e a biometria vai por link.</p>
      </div>
      <button type="button" class="g-fechar" data-fechar aria-label="Fechar">×</button>
    </div>

    <ol class="g-passos" id="passos-ind" aria-label="Passos da venda">
      <li><button type="button" data-ir="1"><i></i>1. Endereço</button></li>
      <li><button type="button" data-ir="2"><i></i>2. Cliente</button></li>
      <li><button type="button" data-ir="3"><i></i>3. Oferta</button></li>
      <li><button type="button" data-ir="4"><i></i>4. Conferências</button></li>
      <li><button type="button" data-ir="5"><i></i>5. Pedido</button></li>
    </ol>

    <div class="g-corpo" id="g-corpo">
      <!-- 1 · Endereço e cobertura -->
      <section class="passo-g" data-passo="1">
        <h3>Endereço e cobertura</h3>
        <p class="ajuda">Sem endereço não existe venda: ele define cidade, tabela e cobertura.</p>
        <div class="grade3-end">
          <label class="campo">CEP<input type="text" name="cep" inputmode="numeric" placeholder="00000-000" maxlength="9" autocomplete="off" required></label>
          <label class="campo">Número<input type="text" name="numero" placeholder="nº" autocomplete="off" required></label>
          <label class="campo">Complemento<input type="text" name="complemento" placeholder="apto, bloco, casa" autocomplete="off"></label>
        </div>
        <div id="endereco" hidden>
          <div class="grade2">
            <label class="campo">Logradouro<input type="text" name="logradouro"></label>
            <label class="campo">Bairro<input type="text" name="bairro"></label>
            <label class="campo">Cidade / UF<input type="text" name="cidade_uf" readonly></label>
            <div class="campo"><span>Tabela da cidade</span><span id="cluster-chip" class="chip">—</span></div>
          </div>
        </div>
        <div class="faixa cinza" id="faixa-dfv" aria-live="polite">Digite CEP e número para consultar a cobertura.</div>
        <div class="chips" id="travas" aria-live="polite"></div>
        <div class="dfv-sem" id="dfv-sem" hidden>
          <span></span>
          <button type="button" class="btn btn-sm" id="btn-sem-cobertura"></button>
        </div>
        <details class="dfv-ajuste" id="dfv-ajuste">
          <summary>Ajustar a cobertura manualmente</summary>
          <div id="dfv-campos"></div>
        </details>
      </section>

      <!-- 2 · Cliente -->
      <section class="passo-g" data-passo="2" hidden>
        <h3>Cliente</h3>
        <p class="ajuda">Quem compra. Confirme telefone e endereço com a pessoa: erro de cadastro é venda indevida.</p>
        <div class="seg" role="radiogroup" aria-label="Segmento">
          <label><input type="radio" name="segmento" value="PF" checked>PF · Varejo</label>
          <label><input type="radio" name="segmento" value="MEI">PJ · MEI</label>
          <label><input type="radio" name="segmento" value="NMEI">PJ · NMEI</label>
        </div>
        <div class="grade2">
          <label class="campo" style="grid-column:1/-1">Nome completo<input type="text" name="nome" placeholder="como no documento" required></label>
          <label class="campo">CPF / CNPJ<input type="text" name="doc" inputmode="numeric" placeholder="valida dígito"><span class="erro" id="doc-erro"></span></label>
          <label class="campo">WhatsApp<input type="tel" name="whatsapp" placeholder="confirmado com o cliente" required></label>
          <label class="campo">E-mail<input type="email" name="email" placeholder="para a fatura"></label>
          <label class="campo">Origem<select name="origem"><option value="rua">Rua / PAP</option><option value="indicacao">Indicação de cliente</option><option value="outro">Evento</option></select></label>
          <label class="campo" id="campo-ref" hidden style="grid-column:1/-1">Quem indicou<input type="text" name="origem_ref"></label>
          <label class="campo" id="campo-parceiro" hidden style="grid-column:1/-1">Parceiro PAP (só ativos)<select name="parceiro_id"><option value="">Escolher o parceiro…</option></select>
            <span class="nota-campo" id="nota-parceiro">A venda nasce em conferência de qualidade: a Dharma liga para o cliente antes de seguir. Nada de pedido, biometria ou "Registrar venda" agora.</span></label>
        </div>
        <span class="nota-campo">PJ · NMEI recebe o bônus NMEI por cima da comissão.</span>
        <label class="check"><input type="checkbox" name="contato_ok"> WhatsApp, e-mail e endereço confirmados com o cliente (erro de cadastro conta como venda indevida)</label>
      </section>

      <!-- 3 · Oferta -->
      <section class="passo-g" data-passo="3" hidden>
        <h3>Oferta</h3>
        <p class="ajuda">Só a tabela vigente. Plano depende da cidade; o preço depende da forma de pagamento.</p>
        <div class="seg" role="radiogroup" aria-label="Forma de pagamento">
          <label><input type="radio" name="forma" value="cartao" checked>Cartão</label>
          <label><input type="radio" name="forma" value="boleto">Boleto</label>
          <label><input type="radio" name="forma" value="dacc">Débito</label>
        </div>
        <span class="nota-campo">1º vencimento: 25 dias após a instalação (cartão: no dia da instalação). Não se escolhe dia de vencimento.</span>
        <div class="campo">
          <span>Plano · tabela vigente desde <span id="vigencia">—</span> · <span id="tabela-cidade"></span></span>
          <div class="planos-op" id="planos-op" role="radiogroup" aria-label="Plano"></div>
        </div>
        <label class="check" id="campo-nfid"><input type="checkbox" name="nfid"> Cliente quer o plano sem fidelidade (taxa de R$ 540 à vista na 1ª fatura)</label>
        <div class="campo">
          <span>Serviços adicionais</span>
          <div class="adic" id="adicionais"></div>
        </div>
        <div class="resumo-venda" id="resumo" aria-live="polite"></div>
      </section>

      <!-- 4 · Conferências do contrato -->
      <section class="passo-g" data-passo="4" hidden>
        <h3>Conferências do contrato</h3>
        <p class="ajuda">As três perguntas que valem estorno de 100 %.</p>
        <div class="faixa vermelho" id="aviso-ocupado" hidden>A base DFV indica Nio ativo neste endereço: pergunte com atenção e confira no portal.</div>
        <div class="confs" role="group" aria-label="Conferências do contrato">
          <div class="conf"><span>Cancelou a Nio nos últimos 30 dias?</span>
            <span class="simnao"><label><input type="radio" name="cf_cancelou" value="sim"> Sim</label><label><input type="radio" name="cf_cancelou" value="nao"> Não</label></span></div>
          <div class="conf"><span>Já é cliente Nio?</span>
            <span class="simnao"><label><input type="radio" name="cf_cliente" value="sim"> Sim</label><label><input type="radio" name="cf_cliente" value="nao"> Não</label></span></div>
          <div class="conf"><span>O endereço tem produto Nio ativo?</span>
            <span class="simnao"><label><input type="radio" name="cf_endereco" value="sim"> Sim</label><label><input type="radio" name="cf_endereco" value="nao"> Não</label></span></div>
        </div>
        <div class="dfv-sem" id="conf-sim" hidden>
          <span></span>
          <button type="button" class="btn btn-sm" id="btn-conf-saida"></button>
        </div>
        <label class="check"><input type="checkbox" name="app_ok"> Conferi no portal PAP: não é cliente Nio, endereço sem produto ativo e sem cancelamento nos últimos 30 dias</label>
      </section>

      <!-- 5 · Pedido no portal e biometria por link (venda remota, 05/11: não existe biometria em campo) -->
      <section class="passo-g" data-passo="5" hidden>
        <h3>Pedido no portal e biometria</h3>
        <p class="ajuda">O pedido é aberto no portal PAP (perfil BO); ao concluir o pedido, a própria Nio manda ao cliente o link da biometria (WhatsApp + e-mail) e ele faz pelo celular. É o que transforma qualificado em vendido.</p>
        <div class="f-form-acoes"><a class="btn btn-ghost" href="https://pap.niointernet.com.br/administrativo/novo-pedido" target="_blank" rel="noopener">Abrir no portal PAP ↗</a></div>
        <div class="grade2">
          <label class="campo">Nº do pedido (portal PAP)<input type="text" name="pedido" placeholder="obrigatório p/ Vendido" autocomplete="off"></label>
          <label class="campo">Biometria (link)<select name="biometria"><option value="">Escolher…</option><option value="nao_enviada">Sem pedido (link ainda não saiu)</option><option value="pendente">Pendente (link enviado pela Nio)</option><option value="com_risco">Com risco</option><option value="validada">Validada</option></select></label>
          <label class="campo">Instalação · preferência<select name="inst_pref"><option value="">—</option><option value="manhã">Manhã</option><option value="tarde">Tarde</option></select></label>
        </div>
        <div class="faixa amarelo">Biometria validada: agendar a instalação em até 4 h (indicador do contrato).</div>
        <span class="nota-campo">O normal é salvar como qualificado agora e registrar a venda quando a biometria validar, pela ficha da venda.</span>
      </section>
    </div>

    <div class="g-pe">
      <div class="g-resumo"><span>Valor ao cliente<b id="r-valor">—</b></span><span>Comissão prevista<b id="r-com">—</b></span></div>
      <div class="g-falta" id="g-falta" aria-live="polite"></div>
      <div class="g-botoes">
        <button type="button" class="btn btn-ghost" id="btn-voltar">← Voltar</button>
        <div class="dir">
          <button type="button" class="btn" id="btn-qualificado" disabled title="Antes do pedido no portal: cria a venda em 0 · Qualificado">Salvar como qualificado</button>
          <button type="button" class="btn btn-acc" id="btn-avancar">Continuar →</button>
          <button type="button" class="btn btn-acc" id="btn-venda" disabled hidden title="Exige nº do pedido do portal, biometria validada, conferências e viabilidade (&lt; 7 dias)">Registrar venda</button>
        </div>
      </div>
    </div>
  </form>
</aside>
`;

  let promessa = null;
  function montar(opts) {
    if (!promessa) promessa = criar(opts || {});
    return promessa;
  }

  async function criar({ eu, aoSalvar }) {
    const { esc, STATUS_MAP } = NG;
    document.body.insertAdjacentHTML('beforeend', HTML);

    // ================================================================== nova venda (gaveta)
    // Daqui para baixo: as mesmas regras, travas e gravação da venda de rua da v0.6.3. Só muda a apresentação:
    // um passo por vez, barra de progresso clicável e rodapé fixo com valor, comissão prevista, o que falta e os botões.
    const gavetaEl = document.getElementById('gaveta-venda');
    const abrirGaveta = () => NG.gaveta.abrir(gavetaEl, { foco: false });
    // Seletores presos à gaveta: a tela que inclui este componente pode ter ids iguais (#resumo, #g-corpo…).
    const $ = (id) => gavetaEl.querySelector('#' + id);

    const form = $('venda-rua');
    const F = form.elements;
    const travasEl = $('travas');
    const btnQualif = $('btn-qualificado');
    const btnVenda = $('btn-venda');
    const btnAvancar = $('btn-avancar');
    const btnVoltar = $('btn-voltar');
    const corpoEl = $('g-corpo');

    const hoje = NG.diaSP();
    // Programa Parceiro PAP (prompt 25): só admin/backoffice lançam venda de parceiro (a tabela parceiros não abre para o vendedor).
    const lancaParceiro = ['admin', 'backoffice'].includes(eu.perfil);
    let parceirosAtivos = [];
    if (lancaParceiro) {
      const rpar = await NG.sb.from('parceiros').select('id, nome').eq('status', 'ativo').order('nome');
      parceirosAtivos = rpar.data || [];
      const selOri = gavetaEl.querySelector('select[name="origem"]');
      selOri.insertAdjacentHTML('beforeend', '<option value="parceiro_pap">Parceiro PAP</option>');
      gavetaEl.querySelector('select[name="parceiro_id"]').insertAdjacentHTML('beforeend',
        parceirosAtivos.map((p) => `<option value="${esc(p.id)}">${esc(p.nome)}</option>`).join(''));
      if (!parceirosAtivos.length) gavetaEl.querySelector('#nota-parceiro').textContent = 'Nenhum parceiro ativo: aprove um cadastro em Parceiros PAP antes.';
    }
    const [{ data: planos }, { data: areas }, { data: adicionais }, { data: bonus }] = await Promise.all([
      NG.sb.from('config_planos').select('*').eq('ativo', true).lte('vigencia_inicio', hoje).order('preco'),
      NG.sb.from('config_area').select('*').eq('ativo', true),
      NG.sb.from('config_adicionais').select('*').eq('ativo', true).lte('vigencia_inicio', hoje).order('id'),
      NG.sb.from('config_bonus').select('*').lte('valido_de', hoje),
    ]);
    const vigentes = (planos || []).filter((p) => !p.vigencia_fim || p.vigencia_fim >= hoje);
    const bonusVigente = (bonus || []).filter((b) => !b.valido_ate || b.valido_ate >= hoje);
    const ini = vigentes.map((p) => p.vigencia_inicio).sort().pop();
    $('vigencia').textContent = ini ? NG.fmtDiaISO(ini) : '—';

    // Endereço vindo do ViaCEP + resultado das travas.
    const estado = { viacep: null, cobertura: null, area: null, cluster: null, dup: null, recompra: null, avisos: null, dfv: null, dfvErro: false, consultando: false };

    const norm = (s) => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').trim().toLowerCase();
    // Linha da área que cobre o endereço (traz o cluster: a tabela de preço da cidade). A mesma regra roda no banco (cluster_da_area).
    function areaDe(cidade, bairro, uf) {
      if (!cidade) return null;
      return (areas || []).filter((a) => norm(a.cidade) === norm(cidade) && norm(a.uf) === norm(uf || 'MG') &&
        (!a.bairro || norm(a.bairro) === norm(bairro))).sort((a, b) => (b.bairro ? 1 : 0) - (a.bairro ? 1 : 0))[0] || null;
    }
    function atualizarArea() {
      const j = estado.viacep;
      const a = j ? areaDe(j.localidade, F.bairro.value, j.uf) : null;
      estado.area = j ? !!a : null;
      estado.cluster = a ? a.cluster : null;
    }

    // Varejo = PF; Empresas = MEI/NMEI. A variante sem fidelidade não aparece na lista: o checkbox troca para ela.
    const SEM_FID = { regular: 'nfid', oferta50: 'oferta50_nfid' };
    const portfolio = () => (F.segmento.value === 'PF' ? 'varejo' : 'empresas');
    const planoMarcado = () => (form.querySelector('input[name="plano"]:checked') || {}).value || '';

    function renderPlanos() {
      const atual = planoMarcado();
      // A tabela é a da cidade do CEP; antes do CEP mostra a Regular. Plano de um cluster nunca vale na cidade do outro.
      const cluster = estado.cluster || 'regular';
      const lista = vigentes.filter((p) => p.cluster === cluster && (p.segmentos || []).includes(F.segmento.value) && !Object.values(SEM_FID).includes(p.variante) &&
        (!p.forma_pagamento_permitida || p.forma_pagamento_permitida.includes(F.forma.value)));
      const cidade = estado.viacep ? estado.viacep.localidade : '';
      const vazio = cluster === 'btu' && portfolio() === 'varejo'
        ? `<span class="rv-alerta">Tabela Varejo BTU pendente — fale com o Ricardo. ${esc(cidade)} é cidade BTU: hoje lá só vende Empresas (MEI/NMEI).</span>`
        : '<span class="nota-campo">Nenhum plano vigente para este segmento/forma</span>';
      $('tabela-cidade').textContent = estado.cluster
        ? `${cidade} · tabela ${cluster === 'btu' ? 'BTU' : 'Regular'}`
        : estado.area === false ? `${cidade} · fora da área de atuação` : 'tabela Regular até o CEP dizer a cidade';
      $('planos-op').innerHTML = lista.length ? lista.map((p) => `
        <label class="plano-op">
          <input type="radio" name="plano" value="${p.id}" ${String(p.id) === atual ? 'checked' : ''}>
          <span class="po-nome">${esc(p.nome)}</span>
          <span class="po-preco"><b>${NG.fmtMoeda(F.forma.value === 'cartao' && p.preco_cartao != null ? p.preco_cartao : p.preco)}</b>/mês ${({ cartao: 'no cartão', boleto: 'no boleto', dacc: 'no débito' })[F.forma.value]}</span>
          <span class="po-det">${esc([p.velocidade, p.wifi, p.internet_5g ? `Internet 5G ${p.internet_5g}` : null].filter(Boolean).join(' · '))}</span>
          ${p.inclusos && p.inclusos.length ? `<span class="po-det">Já vem com ${esc(p.inclusos.join(', '))}</span>` : ''}
          <span class="po-com">comissão ${NG.fmtMoeda(p.comissao)}</span>
        </label>`).join('') : vazio;
      const temSemFid = vigentes.some((p) => p.portfolio === portfolio() && p.cluster === cluster && Object.values(SEM_FID).includes(p.variante));
      $('campo-nfid').hidden = !temSemFid;
      if (!temSemFid) F.nfid.checked = false;
      renderAdicionais();
    }

    // Plano que vai para a venda: o marcado, ou o equivalente sem fidelidade se o checkbox estiver marcado.
    function planoEscolhido() {
      const base = vigentes.find((p) => String(p.id) === planoMarcado()) || null;
      if (!base || !F.nfid.checked) return base;
      return vigentes.find((p) => p.portfolio === base.portfolio && p.familia === base.familia && p.cluster === base.cluster &&
        p.variante === SEM_FID[base.variante]) || base;
    }

    function renderAdicionais() {
      const port = portfolio();
      const lista = (adicionais || []).filter((a) => (a.portfolio || []).includes(port));
      const antes = {};
      gavetaEl.querySelectorAll('#adicionais [data-ad]').forEach((el) => { antes[el.dataset.ad] = el.type === 'checkbox' ? (el.checked ? 1 : 0) : Number(el.value); });
      $('adicionais').innerHTML = lista.map((a) => {
        const preco = a.preco != null ? `${NG.fmtMoeda(a.preco)}/mês${a.max_por_contrato > 1 ? ' cada' : ''}` : 'preço no portal';
        const info = `<span class="ad-info">${preco} · comissão ${NG.fmtMoeda(a.comissao)}</span>`;
        if (a.max_por_contrato > 1) {
          const opts = Array.from({ length: a.max_por_contrato + 1 }, (_, i) => `<option value="${i}" ${antes[a.codigo] === i ? 'selected' : ''}>${i}</option>`).join('');
          return `<label class="ad-linha"><span class="ad-nome">${esc(a.nome)}${info}</span><select data-ad="${a.codigo}" aria-label="${esc(a.nome)}: quantidade">${opts}</select></label>`;
        }
        return `<label class="ad-linha"><span class="ad-nome">${esc(a.nome)}${info}</span><input type="checkbox" data-ad="${a.codigo}" ${antes[a.codigo] ? 'checked' : ''}></label>`;
      }).join('') || '<span class="nota-campo">Nenhum serviço adicional para este portfólio</span>';
      renderResumo();
    }

    function adicionaisEscolhidos() {
      return [...gavetaEl.querySelectorAll('#adicionais [data-ad]')]
        .map((el) => ({ a: (adicionais || []).find((x) => x.codigo === el.dataset.ad), qtd: el.type === 'checkbox' ? (el.checked ? 1 : 0) : Number(el.value) }))
        .filter((x) => x.a && x.qtd > 0);
    }

    // Prévia da conta que o banco faz em recalcular_comissao: nominal + adicionais + transição + NMEI. O M-10 fica fora.
    function bonusDe(tipo, p) {
      const b = bonusVigente.filter((x) => x.tipo === tipo && x.cluster === p.cluster && (!x.plano_codigo || x.plano_codigo === p.codigo))
        .sort((x, y) => (y.plano_codigo ? 1 : 0) - (x.plano_codigo ? 1 : 0))[0];
      return b ? Number(b.valor) : 0;
    }
    function calcular() {
      const p = planoEscolhido();
      if (!p) return null;
      const ads = adicionaisEscolhidos();
      const valor = F.forma.value === 'cartao' && p.preco_cartao != null ? Number(p.preco_cartao) : Number(p.preco);
      const valorAd = ads.reduce((s, x) => s + Number(x.a.preco || 0) * x.qtd, 0);
      const nominal = Number(p.comissao || 0);
      const adic = ads.reduce((s, x) => s + Number(x.a.comissao) * x.qtd, 0);
      const transicao = bonusDe('transicao', p);
      const nmei = F.segmento.value === 'NMEI' && p.portfolio === 'empresas' ? bonusDe('nmei', p) : 0;
      return { p, valor, valorAd, nominal, adic, transicao, nmei, total: nominal + adic + transicao + nmei, m10: bonusDe('m10', p) };
    }

    function renderResumo() {
      const c = calcular();
      const el = $('resumo');
      $('r-valor').textContent = c ? NG.fmtMoeda(c.valor + c.valorAd) : '—';
      $('r-com').textContent = c ? NG.fmtMoeda(c.total) : '—';
      if (!c) { el.innerHTML = ''; return; }
      const m = NG.fmtMoeda;
      const forma = F.forma.value === 'cartao' ? 'no cartão' : 'boleto/débito';
      const hab = c.p.taxa_a_vista
        ? `<span class="rv-alerta">Sem fidelidade: taxa de habilitação de ${m(c.p.taxa_habilitacao)} à vista na 1ª fatura.</span>`
        : `<span class="rv-nota">Habilitação de ${m(c.p.taxa_habilitacao)} isenta ficando ${c.p.isencao_meses} meses (cancelou antes, paga o proporcional).</span>`;
      el.innerHTML = `
        <div class="rv-linha"><span>Valor mensal ao cliente</span><strong>${m(c.valor + c.valorAd)}</strong></div>
        <span class="rv-nota">${esc(c.p.nome)} ${m(c.valor)} ${forma}${c.valorAd ? ` + ${m(c.valorAd)} de adicionais` : ''}</span>
        ${hab}
        <div class="rv-linha"><span>Comissão prevista</span><strong>${m(c.total)}</strong></div>
        <span class="rv-nota">${m(c.nominal)} nominal · ${m(c.adic)} adicionais · ${m(c.transicao)} transição · ${m(c.nmei)} NMEI</span>
        ${c.m10 ? `<span class="rv-nota">${NG.rotulo(`Bônus M-10 potencial: ${m(c.m10)} no 11º mês`, 'm10')} (fora da comissão prevista)</span>` : ''}
        ${c.p.observacao ? `<span class="rv-nota">${esc(c.p.observacao)}</span>` : ''}`;
    }

    function renderTravas() {
      const chip = $('cluster-chip');
      chip.className = `chip ${estado.area === false ? 'bad' : estado.area ? 'ok' : ''}`;
      chip.textContent = estado.area === false ? 'Fora da área de atuação' : estado.cluster ? (estado.cluster === 'btu' ? 'BTU' : 'Regular') : '—';
      const selos = NG.selosFicha(estado.avisos);   // 0076: ficha única, só aviso
      if (!estado.viacep) { travasEl.innerHTML = selos; return; }
      const a = estado.area === false ? '<span class="chip bad">Cidade fora da área de atuação ✗</span>'
        : estado.area ? `<span class="chip ok">Dentro da área ✓ · ${estado.cluster === 'btu' ? 'BTU' : 'Regular'}</span>` : '';
      const d = estado.dup === null ? '' : estado.dup.endereco
        ? '<span class="chip bad">Endereço já tem venda ativa no NIOGEN ✗</span>'
        : '<span class="chip ok">Endereço sem venda ativa no NIOGEN ✓</span>';
      const doc = estado.dup && estado.dup.documento ? '<span class="chip bad">CPF/CNPJ já tem venda ativa ✗</span>' : '';
      // Recompra (endereço que já teve venda que saiu ou que a Nio cancelou): avisa, não bloqueia.
      const rec = estado.recompra && estado.recompra.recompra ? '<span class="chip warn recompra">Possível recompra: a Nio aplica multa de R$ 500 por pedido. Confirme com o Ricardo antes de registrar.</span>' : '';
      travasEl.innerHTML = a + d + doc + rec + selos;
    }

    // 0076 (onda 3.1 fase 1): cruza CPF/CNPJ, telefone e endereço com vendas, conversas da Mari, OSAB e DFV. Só aviso.
    let avisosSeq = 0;
    async function checarAvisos() {
      const seq = ++avisosSeq;
      const p = { p_doc: F.doc.value || null, p_tel: F.whatsapp.value || null, p_cep: F.cep.value || null, p_numero: F.numero.value || null, p_complemento: F.complemento.value || null };
      if (!NG.soDigitos(p.p_doc) && !NG.soDigitos(p.p_tel) && !(NG.soDigitos(p.p_cep) && (p.p_numero || '').trim())) { estado.avisos = null; atualizar(); return; }
      const { data, error } = await NG.sb.rpc('ficha_avisos', p);
      if (seq !== avisosSeq) return;
      estado.avisos = error ? null : data;
      atualizar();
    }

    async function checarDuplicidade() {
      checarAvisos();
      if (!NG.soDigitos(F.cep.value) || !F.numero.value.trim()) { estado.dup = null; atualizar(); return; }
      const { data, error } = await NG.sb.rpc('checar_duplicidade', { p_cpf_cnpj: F.doc.value, p_cep: F.cep.value, p_numero: F.numero.value });
      estado.dup = error ? null : data;
      atualizar();
      checarRecompra();
    }

    async function checarRecompra() {
      if (!NG.soDigitos(F.cep.value) || !F.numero.value.trim()) { estado.recompra = null; atualizar(); return; }
      const { data, error } = await NG.sb.rpc('checar_recompra', { p_cep: F.cep.value, p_numero: F.numero.value, p_complemento: F.complemento.value || null });
      estado.recompra = error ? null : data;
      atualizar();
    }

    async function buscarCep() {
      const cep = NG.soDigitos(F.cep.value);
      if (cep.length !== 8) return;
      F.cep.value = `${cep.slice(0, 5)}-${cep.slice(5)}`;
      try {
        const r = await fetch(`https://viacep.com.br/ws/${cep}/json/`);
        const j = await r.json();
        if (j.erro) throw new Error('CEP não encontrado');
        estado.viacep = j;
        F.logradouro.value = j.logradouro || '';
        F.bairro.value = j.bairro || '';
        F.cidade_uf.value = `${j.localidade} / ${j.uf}`;
        $('endereco').hidden = false;
        atualizarArea();
        consultarDfv();
      } catch (e) {
        estado.viacep = null;
        atualizarArea();
        $('endereco').hidden = true;
        NG.toast(e.message === 'CEP não encontrado' ? 'CEP não encontrado no ViaCEP' : 'ViaCEP indisponível — tente de novo', 'bad');
      }
      renderPlanos();
      checarDuplicidade();
    }

    // ------------------------------------------------------------- cobertura (passo 1)
    // A base responde sozinha ao sair do número/complemento (e depois do ViaCEP). O resultado aparece como faixa no passo 1;
    // os campos dfv_* vão junto na gravação. O seletor manual (5 opções) fica recolhido em "Ajustar a cobertura manualmente".
    const dfvEl = $('dfv-campos');
    const semEl = $('dfv-sem');
    const btnSem = $('btn-sem-cobertura');
    const faixaEl = $('faixa-dfv');
    const dfvOk = () => ['viavel', 'viavel_predio'].includes(F.dfv_viabilidade.value);
    let seqDfv = 0;

    function coberturaDoSeletor() {
      const vi = F.dfv_viabilidade.value;
      return dfvOk() ? true : vi === 'nao_consultado' ? null : false;
    }
    function montarDfv() {
      dfvEl.innerHTML = NG.dfvCampos();
      NG.ligarLinkDfv(dfvEl);
      // "Consultar de novo" e a troca manual dentro do ajuste continuam valendo; o resultado volta para a faixa.
      NG.ligarDfvAuto(dfvEl,
        () => ({ cep: F.cep.value, numero: F.numero.value, complemento: F.complemento.value }),
        {
          aoEscolher: (comp) => { F.complemento.value = comp; },
          aoMudar: (r) => {
            estado.dfvErro = false;
            if (r) estado.dfv = r;
            estado.cobertura = r ? (r.resultado === 'precisa_numero' ? null : ['viavel', 'viavel_predio'].includes(r.resultado)) : coberturaDoSeletor();
            atualizar();
          },
        });
    }
    async function consultarDfv() {
      const e = { cep: F.cep.value, numero: F.numero.value, complemento: F.complemento.value };
      // Endereço novo = consulta nova: os campos dfv_* de um endereço anterior não podem ir para esta venda.
      montarDfv();
      estado.dfv = null;
      estado.cobertura = null;
      estado.dfvErro = false;
      if (NG.soDigitos(e.cep).length !== 8 || !String(e.numero).trim()) { atualizar(); return; }
      const meu = ++seqDfv;
      estado.consultando = true;
      atualizar();
      try {
        const r = await NG.dfvConsultar(e.cep, e.numero, e.complemento);
        if (meu !== seqDfv) return;
        estado.dfv = r;
        NG.dfvPreencher(dfvEl, r);
        estado.cobertura = !r || r.resultado === 'precisa_numero' ? null : ['viavel', 'viavel_predio'].includes(r.resultado);
      } catch (err) {
        if (meu !== seqDfv) return;
        estado.dfvErro = true;
      }
      estado.consultando = false;
      atualizar();
    }

    function renderFaixa() {
      const cep = NG.soDigitos(F.cep.value);
      const num = F.numero.value.trim();
      const set = (cor, html) => { faixaEl.className = `faixa ${cor}`; faixaEl.innerHTML = html; NG.ligarLinkDfv(faixaEl); };
      const q = new URLSearchParams(Object.entries({ cep, numero: num, complemento: F.complemento.value.trim() }).filter(([, v]) => v));
      const links = `<span class="faixa-links"><a href="cobertura.html?${esc(q.toString())}" target="_blank" rel="noopener">Abrir tela de cobertura ↗</a>`
        + '<a data-dfv-link href="#" target="_blank" rel="noopener noreferrer">Abrir DFV Sudeste ↗</a></span>';
      if (cep.length !== 8 || !num) return set('cinza', cep.length === 8 ? 'Digite o número para consultar a cobertura.' : 'Digite CEP e número para consultar a cobertura.');
      if (estado.consultando) return set('cinza', 'Consultando a base DFV…');
      const vi = F.dfv_viabilidade.value;
      if (F.dfv_origem.value === 'manual') {
        if (dfvOk()) return set('verde', `Cobertura (ajuste manual): ${vi === 'viavel_predio' ? 'prédio viável' : 'viável'}`);
        if (vi === 'nao_consultado') return set('cinza', 'Cobertura ainda não consultada.');
        return set('amarelo', `Cobertura (ajuste manual): ${esc(NG.DFV_OPCOES[vi].toLowerCase())} — conferir no portal (quem manda é o portal).`);
      }
      if (estado.dfvErro) return set('amarelo', `Base DFV indisponível — conferir no painel ou no portal antes de abrir o pedido. ${links}`);
      const r = estado.dfv;
      const base = F.dfv_particao.value ? ` · base de ${NG.fmtDiaISO(F.dfv_particao.value).slice(0, 5)}` : '';
      switch (r && r.resultado) {
        case 'viavel': return set('verde', `✓ Cobertura viável${base}`);
        case 'viavel_predio': {
          const ops = (r.opcoes || []).slice(0, 120);
          return set('verde', `✓ Prédio viável — escolha a unidade${base}
            <span class="dfv-opcoes-lista">${ops.map((o) => `<button type="button" class="chip ${o.hp_livre >= 1 ? 'ok' : 'bad'}" data-unidade="${esc(o.complemento || '')}"
              title="HP livre ${o.hp_livre ?? '—'} · HC ${o.hc_tot ?? '—'}">${esc(o.complemento || `nº ${o.numero} (sem complemento)`)}</button>`).join('')}</span>`);
        }
        case 'endereco_ocupado': return set('vermelho', 'Atenção: a base indica Nio ativo neste endereço — confirme com o cliente e no portal.');
        case 'sem_porta_livre': return set('amarelo', `Na base, mas sem porta livre — conferir no painel ou no portal antes de abrir o pedido${base}. ${links}`);
        case 'nao_encontrado': return set('amarelo', `Não encontrado na base — conferir no painel ou no portal antes de abrir o pedido. ${links}`);
        default: return set('cinza', 'Digite o número para consultar a cobertura.');
      }
    }
    faixaEl.addEventListener('click', (ev) => {
      const b = ev.target.closest('[data-unidade]');
      if (!b) return;
      F.complemento.value = b.dataset.unidade;
      consultarDfv();
    });

    // ------------------------------------------------------------- passos e botões
    const passos = [...form.querySelectorAll('.passo-g')];
    const indEl = $('passos-ind');
    const btnConfSaida = $('btn-conf-saida');
    let passoAtual = 1;
    const radio = (n) => (form.querySelector(`input[name="${n}"]:checked`) || {}).value || '';
    const diaMais = (n) => NG.diaSP(new Date(Date.now() + n * 86400000));

    // Um passo por vez. Fora da área de atuação a venda não passa do passo 1 (mesma regra da v0.6.3).
    function irPara(n) {
      if (n > 1 && estado.area === false) { NG.toast('Cidade fora da área de atuação: a venda não segue.', 'bad'); return false; }
      passoAtual = Math.max(1, Math.min(5, n));
      passos.forEach((s, i) => { s.hidden = i !== passoAtual - 1; });
      [...indEl.querySelectorAll('button')].forEach((b, i) => {
        b.classList.toggle('atual', i === passoAtual - 1);
        if (i === passoAtual - 1) b.setAttribute('aria-current', 'step'); else b.removeAttribute('aria-current');
      });
      btnVoltar.hidden = passoAtual === 1;
      btnAvancar.hidden = passoAtual === 5;
      btnVenda.hidden = passoAtual !== 5;
      corpoEl.scrollTop = 0;
      return true;
    }

    // Estado de cada passo: '' vazio · ok · warn (atenção) · bad. "pronto" = o mínimo para seguir (libera o qualificado).
    function avaliar() {
      const enderecoOk = NG.soDigitos(F.cep.value).length === 8 && !!estado.viacep && !!F.numero.value.trim() && estado.area === true;
      const docTxt = F.doc.value.trim();
      const docOk = NG.documentoValido(docTxt);
      const confs = [radio('cf_cancelou'), radio('cf_cliente'), radio('cf_endereco')];
      const ocupado = F.dfv_resultado.value === 'endereco_ocupado';
      const pronto = [
        enderecoOk,
        !!F.nome.value.trim() && !!F.whatsapp.value.trim() && F.contato_ok.checked && (!docTxt || docOk),
        !!planoEscolhido(),
        confs.every((x) => x === 'nao') && F.app_ok.checked,
        !!F.pedido.value.trim() && F.biometria.value === 'validada',
      ];
      const naoViavel = F.dfv_viabilidade.value !== 'nao_consultado' && !dfvOk();
      const est = [
        estado.area === false ? 'bad' : enderecoOk ? (naoViavel || estado.dfvErro ? 'warn' : 'ok') : '',
        docTxt && !docOk ? 'warn' : pronto[1] ? 'ok' : '',
        pronto[2] ? 'ok' : '',
        confs.includes('sim') ? 'bad' : pronto[3] ? 'ok' : ocupado ? 'warn' : '',
        F.biometria.value === 'com_risco' ? 'bad' : pronto[4] ? 'ok' : F.biometria.value === 'pendente' ? 'warn' : '',
      ];
      const foraArea = estado.area === false ? 'cidade fora da área' : 'endereço';
      const faltaQ = [];
      const ehParceiro = F.origem.value === 'parceiro_pap';
      if (ehParceiro && !F.parceiro_id.value) faltaQ.push('parceiro');
      if (!pronto[0]) faltaQ.push(foraArea);
      if (!pronto[1]) faltaQ.push(docTxt && !docOk ? 'CPF/CNPJ válido' : 'cliente');
      if (!pronto[2]) faltaQ.push('plano');
      const faltaV = [];
      if (ehParceiro) faltaV.push('conferência de qualidade do parceiro (a Dharma aprova antes)');
      if (!pronto[0]) faltaV.push(foraArea);
      if (!dfvOk()) faltaV.push('cobertura');
      if (!F.nome.value.trim() || !F.whatsapp.value.trim() || !F.contato_ok.checked) faltaV.push('cliente');
      if (!docOk) faltaV.push('CPF/CNPJ válido');
      if (!pronto[2]) faltaV.push('plano');
      if (!pronto[3]) faltaV.push('conferências');
      if (estado.dup && estado.dup.endereco) faltaV.push('endereço já tem venda ativa');
      if (estado.dup && estado.dup.documento) faltaV.push('CPF/CNPJ já tem venda ativa');
      if (!F.pedido.value.trim()) faltaV.push('nº do pedido');
      if (F.biometria.value !== 'validada') faltaV.push('biometria validada');
      return { pronto, est, faltaQ, faltaV, confs, ocupado };
    }

    function atualizar() {
      const a = avaliar();
      a.est.forEach((e, i) => { passos[i].dataset.estado = e; indEl.querySelectorAll('button')[i].dataset.estado = e; });
      if (estado.area === false && passoAtual > 1) irPara(1);

      btnQualif.disabled = a.faltaQ.length > 0;
      btnVenda.disabled = a.faltaV.length > 0;
      const falta = $('g-falta');
      falta.className = `g-falta${a.faltaV.length ? '' : ' ok'}`;
      falta.textContent = a.faltaQ.length ? `Falta: ${a.faltaQ.join(' · ')}`
        : a.faltaV.length ? `Pronto para qualificado · para a venda falta: ${a.faltaV.join(' · ')}`
          : '✓ Tudo certo para registrar a venda';

      // Passo 1: saída pronta quando o DFV acusa Nio ativo ou o ajuste manual diz sem cobertura.
      const manualSem = F.dfv_origem.value === 'manual' && ['sem_viabilidade', 'nao_encontrado'].includes(F.dfv_viabilidade.value);
      semEl.hidden = !(a.ocupado || manualSem);
      semEl.querySelector('span').textContent = a.ocupado
        ? 'Se o cliente confirmar que já tem Nio: não vender (estorno 100 %). Registrar como saída?'
        : 'O portal confirmou sem cobertura (depois de tentar variações de CEP, rua e número)? Quer registrar como saída e voltar a falar em 90 dias?';
      btnSem.textContent = a.ocupado ? 'Salvar como saída "Já é cliente Nio"' : 'Salvar como saída "Fachada não atendida" · volta em 90 d';

      // Passo 4: o DFV pré-marca atenção; um "Sim" explica o que acontece e oferece a saída certa.
      $('aviso-ocupado').hidden = !a.ocupado;
      const conf = $('conf-sim');
      const cliente = a.confs[1] === 'sim' || a.confs[2] === 'sim';
      conf.hidden = !a.confs.includes('sim');
      conf.querySelector('span').textContent = cliente
        ? 'Já é cliente Nio ou o endereço tem produto ativo: a venda seria estornada em 100 % (e multa de recompra). Não vender — saída "Já é cliente Nio".'
        : 'Cancelou há 30 dias ou menos: reativar nesse prazo é estorno de 100 %. Não vender agora — Interesse futuro daqui a 31 dias.';
      btnConfSaida.textContent = cliente ? 'Salvar como saída "Já é cliente Nio"' : 'Salvar como saída "Recusou · momento" · volta em 31 d';
      btnConfSaida.dataset.saida = cliente ? 'cliente' : 'futuro';

      renderTravas();
      renderFaixa();
    }

    indEl.addEventListener('click', (ev) => { const b = ev.target.closest('[data-ir]'); if (b) irPara(Number(b.dataset.ir)); });
    btnAvancar.addEventListener('click', () => irPara(passoAtual + 1));
    btnVoltar.addEventListener('click', () => irPara(passoAtual - 1));

    F.cep.addEventListener('input', () => { if (NG.soDigitos(F.cep.value).length === 8) buscarCep(); });
    F.numero.addEventListener('change', () => { checarDuplicidade(); consultarDfv(); });
    F.complemento.addEventListener('change', () => { consultarDfv(); checarRecompra(); checarAvisos(); });
    F.whatsapp.addEventListener('change', () => checarAvisos());
    F.bairro.addEventListener('change', () => {
      if (estado.viacep) { atualizarArea(); renderPlanos(); atualizar(); }
    });
    F.doc.addEventListener('change', () => {
      const v = F.doc.value.trim();
      $('doc-erro').textContent = v && !NG.documentoValido(v) ? 'CPF/CNPJ inválido' : '';
      checarDuplicidade();
    });
    // Segmento e forma agora são segmentos (rádios): a troca chega pelo change do formulário.
    form.addEventListener('change', (ev) => { if (['segmento', 'forma'].includes(ev.target.name)) renderPlanos(); });
    $('planos-op').addEventListener('change', renderResumo);
    $('adicionais').addEventListener('change', renderResumo);
    F.nfid.addEventListener('change', renderResumo);
    F.origem.addEventListener('change', () => {
      $('campo-ref').hidden = F.origem.value !== 'indicacao';
      $('campo-parceiro').hidden = F.origem.value !== 'parceiro_pap';
      if (F.origem.value !== 'parceiro_pap') F.parceiro_id.value = '';
    });
    form.addEventListener('input', atualizar);
    form.addEventListener('change', atualizar);
    form.addEventListener('submit', (ev) => ev.preventDefault());

    // Monta a linha de vendas. Devolve [payload, pendências que impedem o status pedido].
    function montar(status, saida) {
      const a = avaliar();
      const falta = status === '1_vendido' ? a.faltaV : status === '0_qualificado' ? a.faltaQ
        : [!F.nome.value.trim() && 'nome', !F.whatsapp.value.trim() && 'WhatsApp', !(estado.viacep && F.numero.value.trim()) && 'CEP e número'].filter(Boolean);
      const docOk = NG.documentoValido(F.doc.value);
      const p = planoEscolhido();


      const j = estado.viacep || {};
      return [{
        status,
        origem: F.origem.value,
        origem_ref: F.origem.value === 'indicacao' ? (F.origem_ref.value.trim() || null) : null,
        // Venda de parceiro: o banco força a conferência pendente e só aceita parceiro ativo (vendas_antes_conferencia).
        parceiro_id: F.origem.value === 'parceiro_pap' ? (F.parceiro_id.value || null) : null,
        cliente_nome: F.nome.value.trim(),
        cliente_cpf_cnpj: NG.soDigitos(F.doc.value) || null,
        cliente_whatsapp: NG.soDigitos(F.whatsapp.value) || null,
        cliente_email: F.email.value.trim() || null,
        segmento: F.segmento.value,
        cep: NG.soDigitos(F.cep.value) || null,
        logradouro: F.logradouro.value.trim() || null,
        numero: F.numero.value.trim() || null,
        complemento: F.complemento.value.trim() || null,
        bairro: F.bairro.value.trim() || null,
        cidade: j.localidade || null,
        uf: j.uf || null,
        plano_id: p ? p.id : null,
        forma_pagamento: F.forma.value,
        nio_pedido: F.pedido.value.trim() || null,
        biometria_status: F.biometria.value || null,   // carimbos de data: trigger vendas_antes_biometria
        instalacao_preferencia: F.inst_pref.value || null,
        vendedor_id: eu.id,
        trava_cobertura: estado.cobertura,
        trava_area: estado.area,
        // Conferências do passo 4 (até o OSAB, quem confere é o vendedor no portal).
        trava_sem_produto_ativo: F.app_ok.checked && a.confs[1] === 'nao' && a.confs[2] === 'nao' && !(estado.dup && (estado.dup.endereco || estado.dup.documento)),
        trava_sem_cancelamento_30d: F.app_ok.checked && a.confs[0] === 'nao',
        trava_cpf_valido: docOk,
        trava_contato_confirmado: F.contato_ok.checked,
        ...NG.dfvLer(dfvEl),
        ...(status === 'saida' ? saida : {}),
      }, falta];
    }

    function limpar() {
      form.reset();
      Object.assign(estado, { viacep: null, cobertura: null, area: null, cluster: null, dup: null, recompra: null, avisos: null, dfv: null, dfvErro: false, consultando: false });
      $('endereco').hidden = true;
      $('doc-erro').textContent = '';
      $('campo-ref').hidden = true;
      $('campo-parceiro').hidden = true;
      montarDfv();
      renderPlanos();
      irPara(1);
      atualizar();
    }

    async function salvar(status, botao, saida) {
      const [linha, falta] = montar(status, saida);
      if (falta.length) { NG.toast(`Falta: ${falta.join(', ')}.`, 'bad'); return; }
      botao.disabled = true;
      // Comissão, valor mensal e vencimento quem calcula é o banco (recalcular_comissao / vendas_calcula_vencimento).
      // As travas também: se algo escapar daqui, o RAISE do banco volta como toast.
      const ads = adicionaisEscolhidos();
      const recompra = estado.recompra && estado.recompra.recompra ? estado.recompra : null;
      const { data, error } = await NG.sb.from('vendas').insert(linha).select('id').single();
      if (!error && recompra) {
        await NG.sb.from('eventos_venda').insert({ venda_id: data.id, tipo: 'alerta_recompra', detalhe: {
          cep: linha.cep, numero: linha.numero, complemento: linha.complemento, anteriores: recompra.anteriores, ultima_em: recompra.ultima_em } });
      }
      if (!error && ads.length) {
        const r = await NG.sb.from('venda_adicionais').insert(ads.map((x) => ({ venda_id: data.id, adicional_id: x.a.id, qtd: x.qtd })));
        if (r.error) NG.toast(`Venda salva, mas os adicionais não: ${NG.msgErro(r.error)}`, 'bad');
      }
      botao.disabled = false;
      if (error) { NG.toast(NG.msgErro(error), 'bad'); atualizar(); return; }
      NG.toast(`${NG.primeiroNome(linha.cliente_nome)} salvo como ${status === 'saida' ? `saída · ${linha.motivo_saida}` : STATUS_MAP[status].curto}`, 'ok');
      limpar();
      NG.gaveta.fechar();
      if (aoSalvar) await aoSalvar(data);
      return data;
    }

    // 13/11 (etapa 4a): a venda que já nasce em Saída usa a lista única (config_lead) — o mesmo motivo, porquê e data que a
    // lead_sair grava nas outras saídas. Sem cobertura = Fachada não atendida (revisão em 90 d); cancelou há ≤ 30 d = Recusou · momento.
    const saidaUnica = async (bt, cod, sub, volta, obs) => {
      let campos;
      try { campos = await NG.saidaCampos(cod, sub, volta, obs); } catch (e) { NG.toast(e.message, 'bad'); return; }
      return salvar('saida', bt, campos);
    };
    btnSem.addEventListener('click', (ev) => (F.dfv_resultado.value === 'endereco_ocupado'
      ? saidaUnica(ev.currentTarget, 'ja_cliente_nio', 'cliente ativo', null)
      : saidaUnica(ev.currentTarget, 'fachada_nao_atendida', null, diaMais(90))));
    btnConfSaida.addEventListener('click', (ev) => (ev.currentTarget.dataset.saida === 'cliente'
      ? saidaUnica(ev.currentTarget, 'ja_cliente_nio', 'cliente ativo', null)
      : saidaUnica(ev.currentTarget, 'recusou', 'momento', diaMais(31), 'reativar até 30 dias do cancelamento é estorno')));
    btnQualif.addEventListener('click', () => salvar('0_qualificado', btnQualif));
    btnVenda.addEventListener('click', () => salvar('1_vendido', btnVenda));

    montarDfv();
    renderPlanos();
    irPara(1);
    atualizar();

    // Abre a gaveta; com endereço (tela Cobertura), começa limpa, preenche e já roda ViaCEP + consulta do DFV.
    async function abrir(e) {
      abrirGaveta();
      if (e && e.cep) {
        limpar();
        F.numero.value = e.numero || '';
        F.complemento.value = e.complemento || '';
        F.cep.value = NG.soDigitos(e.cep);
        await buscarCep();
      } else {
        setTimeout(() => F.cep.focus(), 300);
      }
    }
    return { abrir };
  }

  window.NGNovaVenda = { montar };
})();
