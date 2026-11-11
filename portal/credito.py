#!/usr/bin/env python3
# NIOGEN | portal/credito.py | 11/11/2026 — Claude Code (docs/Prompt_operador_credito_consulta_111126_1650.md)
# OPERADOR DE CRÉDITO — CONSULTA-SÓ. Dirige a tela do Novo Pedido do portal PAP (login BO TT837725) pelas Etapas 1–4 e
# LÊ a Etapa 5 (Pagamento/Ofertas) para saber se o CPF passa no crédito da Nio ou se já tem pedido em andamento.
# Autorização: Rogério (gerência SDE MG, 11/11) e Ricardo (11/11 16h15/16h41). Nunca Avança na Etapa 5, nunca clica
# "Salvar interesse", nunca chega ao Resumo, OS, biometria ou pagamento.
#
# Travas (testadas sem navegador em portal/testar_travas.py):
#   1. REDE   — page.route aborta qualquer pedido de API/documento cujo caminho case REDE_SEMPRE e, depois da Etapa 2,
#               REDE_POS_ETAPA2. Trava acionada → job "erro", página fechada.
#   2. CLIQUE — todo clique passa por clicar(): lista negra por texto + Avançar só nas etapas 1–4.
#   3. FREIO  — limites por hora/dia e cache de 24 h por CPF (hash com sal) ficam no servico.py, só em memória.
#   4. SEM CPF em log e resposta (cpf_mascara). Nada vai a disco além das amostras REDIGIDAS (7 dias).
#
# Este módulo NÃO importa o Playwright no topo: o teste das travas roda sem navegador.

import datetime
import hashlib
import json
import os
import re
import time

PORTAL_HOST = 'https://pap.niointernet.com.br'

# ----------------------------------------------------------------------------------------------- travas de rede
REDE_SEMPRE = re.compile(r'aberturaos|checkout|carrinho|biometria|/pagamento/|reenviolink|dadosBancarios|portabilidade',
                         re.I)
REDE_POS_ETAPA2 = re.compile(r'interesse|prevenda|preVenda|SAVE_LEAD', re.I)
# Só pedidos que fazem algo: chamadas de API (xhr/fetch), documentos e qualquer método que não seja GET.
# Script/estilo/imagem estáticos não gravam nada no portal e não são barrados (um chunk "checkout.js" não é pedido).
TIPOS_VIGIADOS = ('xhr', 'fetch', 'document', 'eventsource', 'websocket', 'other')


def caminho_de(url):
    """Caminho sem query nem host (é o que vai para o log quando a trava dispara)."""
    u = str(url or '').split('?')[0].split('#')[0]
    if '://' in u:
        partes = u.split('/', 3)
        u = partes[3] if len(partes) > 3 else ''
    return u.lstrip('/')


def rede_bloqueada(url, metodo='GET', tipo='fetch', pos_etapa2=False):
    """Devolve o caminho barrado (str) ou None. Regra única usada pelo page.route e pelo teste das travas."""
    if tipo not in TIPOS_VIGIADOS and str(metodo).upper() == 'GET':
        return None
    c = '/' + caminho_de(url)
    if REDE_SEMPRE.search(c):
        return c.lstrip('/')
    if pos_etapa2 and REDE_POS_ETAPA2.search(c):
        return c.lstrip('/')
    return None


# ----------------------------------------------------------------------------------------------- travas de clique
LISTA_NEGRA = ('salvar interesse', 'abrir os', 'enviar', 'finalizar', 'confirmar pedido', 'carregar pedido', 'reenviar')
AVANCAR = re.compile(r'avan[cç]ar', re.I)
ETAPAS = {1: 'Identificação PDV', 2: 'Consulta de viabilidade', 3: 'Cadastro do cliente', 4: 'Contato',
          5: 'Pagamento/Ofertas'}


class TravaAcionada(Exception):
    pass


def _norm(t):
    return re.sub(r'\s+', ' ', str(t or '')).strip().lower()


def texto_proibido(texto):
    t = _norm(texto)
    return next((p for p in LISTA_NEGRA if p in t), None)


def conferir_clique(texto, etapa):
    """Levanta TravaAcionada se o clique é proibido. etapa = etapa em que a tela está (1–5)."""
    p = texto_proibido(texto)
    if p:
        raise TravaAcionada(f'clique recusado pela lista negra: "{p}"')
    if AVANCAR.search(str(texto or '')) and (etapa is None or int(etapa) >= 5):
        raise TravaAcionada(f'Avançar recusado na etapa {etapa} (só 1–4)')


def _texto_do(loc):
    t = ''
    try:
        t = loc.inner_text(timeout=3000) or ''
    except Exception:  # noqa: BLE001
        pass
    if not t.strip():
        for a in ('value', 'aria-label', 'title'):
            try:
                t = loc.get_attribute(a, timeout=1000) or ''
            except Exception:  # noqa: BLE001
                t = ''
            if t.strip():
                break
    return t


def clicar(loc, etapa):
    """ÚNICO caminho de clique do operador. Lê o texto do alvo, confere a lista negra e a etapa, e só então clica."""
    conferir_clique(_texto_do(loc), etapa)
    loc.click(timeout=15000)


# ----------------------------------------------------------------------------------------------- CPF
def so_digitos(s):
    return re.sub(r'\D', '', str(s or ''))


def cpf_valido(cpf):
    c = so_digitos(cpf)
    if len(c) != 11 or c == c[0] * 11:
        return False
    for n in (9, 10):
        soma = sum(int(c[i]) * (n + 1 - i) for i in range(n))
        dv = (soma * 10) % 11 % 10
        if dv != int(c[n]):
            return False
    return True


def cpf_mascara(cpf):
    c = so_digitos(cpf)
    return f'{c[:3]}.***.***-{c[-2:]}' if len(c) == 11 else '***'


def cpf_chave(cpf, sal):
    return hashlib.sha256((str(sal or '') + so_digitos(cpf)).encode()).hexdigest()


def sem_pii(msg):
    """Tira de mensagens de erro qualquer sequência longa de dígitos e e-mail (o Playwright às vezes ecoa valores)."""
    m = re.sub(r'[\w.+-]+@[\w-]+\.[\w.]+', '<email>', str(msg or ''))
    return re.sub(r'\d[\d.\-/ ]{5,}\d', '<num>', m)[:300]


# ----------------------------------------------------------------------------------------------- leitura do resultado
RESULTADOS = ('aprovado_todas', 'aprovado_cartao', 'aprovado_parcial', 'pendente', 'negado', 'pedido_em_andamento',
              'sem_viabilidade', 'erro_receita', 'nao_classificado', 'erro')
RE_ANDAMENTO = re.compile(r'já existe outro pedido|em andamento', re.I)
RE_NEGADO = re.compile(r'negad|não aprovad|nao aprovad|sem ofertas', re.I)
RE_PENDENTE = re.compile(r'pendente|24\s*h|aguard', re.I)
RE_RECEITA = re.compile(r'ops,?\s*ocorreu um erro', re.I)


def classificar_popup(titulo, texto, etapa=None):
    """Classifica um popup visível. 'receita_retry' = erro da Receita na Etapa 3 (o fluxo tenta 1× de novo)."""
    t = f'{titulo or ""} {texto or ""}'
    if RE_ANDAMENTO.search(t):
        return 'pedido_em_andamento'
    if RE_RECEITA.search(t) and etapa == 3:
        return 'receita_retry'
    if RE_NEGADO.search(t):
        return 'negado'
    if RE_PENDENTE.search(t):
        return 'pendente'
    return 'nao_classificado'


def classificar_formas(formas):
    f = {str(x).upper() for x in formas or []}
    if not f:
        return None
    if f == {'BOLETO', 'CREDITO', 'DACC'}:
        return 'aprovado_todas'
    if f == {'CREDITO'}:
        return 'aprovado_cartao'
    return 'aprovado_parcial'


# ----------------------------------------------------------------------------------------------- amostras redigidas
RE_CHAVE_PII = re.compile(r'cpf|documento|nome|mae|nascimento|email|telefone|celular|endereco', re.I)
RE_URL_AMOSTRA = re.compile(r'analiseCredito|propostaCredito|elegibilidade|duplicidadepedido', re.I)


def redigir(obj):
    if isinstance(obj, dict):
        return {k: ('<redigido>' if RE_CHAVE_PII.search(str(k)) else redigir(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redigir(x) for x in obj]
    if isinstance(obj, str):
        return sem_pii(obj) if len(obj) < 400 else sem_pii(obj[:400]) + '…'
    return obj


def limpar_amostras(pasta, dias=7):
    if not pasta or not os.path.isdir(pasta):
        return 0
    limite = time.time() - dias * 86400
    n = 0
    for nome in os.listdir(pasta):
        if not nome.endswith('.json'):
            continue
        p = os.path.join(pasta, nome)
        try:
            if os.path.getmtime(p) < limite:
                os.remove(p)
                n += 1
        except OSError:
            pass
    return n


# ----------------------------------------------------------------------------------------------- JS de leitura da tela
POPUP_JS = r"""
() => {
  const vis = (el) => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el);
    return r.width > 60 && r.height > 40 && s.visibility !== 'hidden' && s.display !== 'none' && +s.opacity > 0.05; };
  const fixo = (el) => { for (let e = el, i = 0; e && i < 8; e = e.parentElement, i++) {
    const p = getComputedStyle(e).position; if (p === 'fixed') return true; } return false; };
  const sel = '[role=dialog],[role=alertdialog],[aria-modal=true],.modal-content,.MuiDialog-paper,.swal2-popup,' +
              '.ReactModal__Content,[class*=modal i],[class*=Modal],[class*=popup i]';
  const cands = [...document.querySelectorAll(sel)].filter((el) => vis(el) && fixo(el)
    && (el.innerText || '').trim().length > 3 && el.querySelector('button,[role=button]'));
  if (!cands.length) return null;
  // o mais interno: o que não contém outro candidato
  const el = cands.find((c) => !cands.some((o) => o !== c && c.contains(o))) || cands[0];
  const h = el.querySelector('h1,h2,h3,h4,h5,h6,[class*=title i],[class*=Title]');
  const botoes = [...el.querySelectorAll('button,[role=button]')].filter(vis).map((b) => (b.innerText || '').trim()).filter(Boolean);
  return { titulo: h ? (h.innerText || '').trim() : '', texto: (el.innerText || '').trim().slice(0, 1200), botoes };
}
"""

RADIOS_JS = r"""
() => [...document.querySelectorAll('input[name="radio-group"]')].map((e) => ({
  v: String(e.value || '').toUpperCase(),
  d: !!(e.disabled || e.getAttribute('aria-disabled') === 'true' || e.closest('[aria-disabled=true],.Mui-disabled,.disabled,[disabled]')),
}))
"""

OFERTAS_JS = r"""
() => {
  const vis = (el) => { const r = el.getBoundingClientRect(); return r.width > 40 && r.height > 20; };
  const preco = /R\$\s*\d/;
  const folhas = [...document.querySelectorAll('div,li,label,article,section')].filter((el) => {
    const t = (el.innerText || '').trim();
    if (!vis(el) || !preco.test(t) || t.length > 400 || /resumo da oferta/i.test(t)) return false;
    return ![...el.children].some((c) => preco.test(c.innerText || '') && (c.innerText || '').trim().length > 20);
  });
  const vistos = new Set();
  return folhas.map((el) => (el.innerText || '').trim()).filter((t) => !vistos.has(t) && vistos.add(t)).slice(0, 12);
}
"""

ENDERECO_JS = r"""
() => {
  for (const s of document.querySelectorAll('select')) {
    const t = [...s.selectedOptions].map((o) => o.textContent.trim()).join(' ');
    if (t && !/selecione/i.test(t)) return t;
  }
  return null;
}
"""

RE_PEDIDO = re.compile(r'Novo pedido\s*[-–]\s*(\d{10,})', re.I)


def ler_oferta(texto):
    linhas = [x.strip() for x in str(texto or '').splitlines() if x.strip()]
    vel = re.search(r'\d+\s*(?:Mega|MB|Giga|GB)\b', texto or '', re.I)
    preco = re.search(r'R\$\s*[\d.]+,\d{2}', texto or '')
    fid = None
    if re.search(r'sem fidelidade', texto or '', re.I):
        fid = False
    elif re.search(r'com fidelidade', texto or '', re.I):
        fid = True
    return {'nome': linhas[0] if linhas else '', 'velocidade': vel.group(0) if vel else None,
            'preco': preco.group(0) if preco else None, 'fidelidade': fid}


def resumo_viabilidade(popup):
    if not popup:
        return None
    botoes = {_norm(b) for b in popup.get('botoes') or []}
    linhas = [x.strip() for x in (popup.get('texto') or '').splitlines()
              if x.strip() and _norm(x) not in botoes and len(x.strip()) < 80]
    return ' · '.join(linhas[:3]) or None


# ----------------------------------------------------------------------------------------------- o fluxo
class SessaoCaida(Exception):
    pass


class Parar(Exception):
    """Fim antecipado com resultado (popup, sem viabilidade…)."""

    def __init__(self, resultado, **extra):
        super().__init__(resultado)
        self.resultado = resultado
        self.extra = extra


class Consulta:
    """Uma consulta = uma página nova no contexto logado. Use rodar(); a página é sempre fechada no fim."""

    def __init__(self, ctx, params, cfg, progresso=None, log=print):
        self.ctx = ctx
        self.p = params          # {cpf, endereco?, contato?}
        self.cfg = cfg           # CREDITO_* do .env
        self.progresso = progresso or (lambda **k: None)
        self.log = log
        self.page = None
        self.etapa = 0
        self.pos_etapa2 = False
        self.trava = None
        self.respostas = []
        self.out = {'pedido_portal': None, 'nome_receita': None, 'endereco': None, 'popup': None,
                    'formas_liberadas': [], 'ofertas': [], 'etapa_parada': None}

    # ---------------------------------------------------------------- utilidades de página
    def _rota(self, route, request):
        try:
            barrado = rede_bloqueada(request.url, request.method, request.resource_type, self.pos_etapa2)
        except Exception:  # noqa: BLE001
            barrado = None
        if barrado:
            if not self.trava:
                self.trava = barrado
            return route.abort()
        return route.continue_()

    def _resposta(self, r):
        if RE_URL_AMOSTRA.search(r.url):
            self.respostas.append(r)

    def _checar_trava(self):
        if self.trava:
            raise TravaAcionada(f'trava acionada: {self.trava}')

    def _ir_etapa(self, n):
        self.etapa = n
        self.progresso(etapa_atual=n, etapa_nome=ETAPAS.get(n))

    def esperar(self, cond, segundos, passo=0.5):
        fim = time.time() + segundos
        while time.time() < fim:
            self._checar_trava()
            v = cond()
            if v:
                return v
            self.page.wait_for_timeout(int(passo * 1000))
        self._checar_trava()
        return None

    def visivel(self, loc):
        try:
            return loc.count() > 0 and loc.first.is_visible()
        except Exception:  # noqa: BLE001
            return False

    def campo(self, *nomes, exato=False):
        """Primeiro input visível por placeholder, depois por label/name."""
        for n in nomes:
            for loc in (self.page.get_by_placeholder(n, exact=exato), self.page.get_by_label(n, exact=exato),
                        self.page.locator(f'input[name="{n}"]')):
                try:
                    for i in range(min(loc.count(), 4)):
                        if loc.nth(i).is_visible():
                            return loc.nth(i)
                except Exception:  # noqa: BLE001
                    pass
        return None

    def preencher(self, loc, valor, devagar=True):
        loc.click(timeout=10000)
        loc.fill('')
        if devagar:
            loc.press_sequentially(str(valor), delay=35)
        else:
            loc.fill(str(valor))

    def botao(self, padrao):
        loc = self.page.get_by_role('button', name=re.compile(padrao, re.I))
        for i in range(min(loc.count(), 6)):
            b = loc.nth(i)
            try:
                if b.is_visible() and b.is_enabled():
                    return b
            except Exception:  # noqa: BLE001
                pass
        return None

    def etapa_na_tela(self):
        """Etapa pelos campos que só existem nela (o stepper mostra os 5 títulos o tempo todo)."""
        pg = self.page
        try:
            if pg.locator('input[name="radio-group"]').count() > 0:
                return 5
            if self.visivel(pg.locator('input[name="contato"]')):
                return 4
            if self.campo('CPF/CNPJ', 'CPF'):
                return 3
            if self.campo('Endereço ou CEP'):
                return 2
            if self.campo('Informe a matrícula do vendedor'):
                return 1
        except Exception:  # noqa: BLE001
            pass
        return None

    def clicar(self, loc):
        # a etapa considerada é a MAIOR entre a máquina de estados e a tela: Avançar nunca sai na 5
        na_tela = self.etapa_na_tela() or 0
        clicar(loc, max(self.etapa or 0, na_tela))

    def avancar(self):
        b = self.esperar(lambda: self.botao(r'^\s*avan[cç]ar'), 20)
        if not b:
            raise Parar('nao_classificado', texto_tela=self.texto_tela(), motivo=f'Avançar não habilitou na etapa {self.etapa}')
        self.clicar(b)

    def popup(self):
        try:
            return self.page.evaluate(POPUP_JS)
        except Exception:  # noqa: BLE001
            return None

    def texto_tela(self):
        try:
            return sem_pii((self.page.inner_text('body') or '')[:800])
        except Exception:  # noqa: BLE001
            return ''

    def ler_pedido(self):
        try:
            m = RE_PEDIDO.search(self.page.inner_text('body') or '')
            if m:
                self.out['pedido_portal'] = m.group(1)
        except Exception:  # noqa: BLE001
            pass

    def parar_por_popup(self, pp):
        cls = classificar_popup(pp.get('titulo'), pp.get('texto'), self.etapa)
        self.out['popup'] = pp
        raise Parar(cls)

    def opcao(self, texto):
        """Escolhe a opção de uma lista suspensa (autocomplete) que contém o texto."""
        def achar():
            for loc in (self.page.get_by_role('option', name=re.compile(re.escape(texto), re.I)),
                        self.page.locator('li, [class*=option i]', has_text=texto)):
                try:
                    for i in range(min(loc.count(), 5)):
                        if loc.nth(i).is_visible():
                            return loc.nth(i)
                except Exception:  # noqa: BLE001
                    pass
            return None
        o = self.esperar(achar, 15)
        if not o:
            raise Parar('erro', motivo=f'opção "{texto}" não apareceu na etapa {self.etapa}')
        self.clicar(o)

    # ---------------------------------------------------------------- etapas
    def etapa0(self):
        pg = self.page
        pg.goto(PORTAL_HOST + '/administrativo', wait_until='domcontentloaded', timeout=45000)
        if 'login.microsoftonline.com' in pg.url or '/login' in pg.url.split('?')[0].lower():
            raise SessaoCaida('portal pediu login')
        menu = self.esperar(lambda: next((l for l in (pg.get_by_role('link', name=re.compile(r'^\s*novo pedido\s*$', re.I)),
                                                      pg.get_by_role('button', name=re.compile(r'^\s*novo pedido\s*$', re.I)),
                                                      pg.get_by_text(re.compile(r'^\s*novo pedido\s*$', re.I)))
                                          if self.visivel(l)), None), 30)
        if not menu:
            if 'login' in pg.url.lower():
                raise SessaoCaida('portal pediu login')
            raise Parar('erro', motivo='menu "Novo Pedido" não apareceu')
        self.clicar(menu.first)

    def etapa1(self):
        self._ir_etapa(1)
        mat = self.esperar(lambda: self.campo('Informe a matrícula do vendedor'), 30)
        if not mat:
            raise Parar('erro', motivo='Etapa 1 não abriu (página em branco?)')
        uf = self.campo('Informe a UF')
        if uf is not None and not (uf.input_value() or '').strip():   # reescolher a UF limpa o PDV: só se vazia
            self.preencher(uf, 'MG')
            self.opcao('MG')
        pdv = self.campo('Insira o código ou nome do seu PDV')
        if pdv is not None and not (pdv.input_value() or '').strip():
            self.preencher(pdv, '1069521')
            self.opcao('1069521')
        matricula = self.cfg['matricula']
        if matricula.lower() not in (mat.input_value() or '').lower():
            self.preencher(mat, matricula)
            self.opcao(matricula)
        self.avancar()

    def etapa2(self):
        e = self.p['endereco']
        cep = self.esperar(lambda: self.campo('Endereço ou CEP'), 30)
        self._ir_etapa(2)
        if not cep:
            raise Parar('erro', motivo='Etapa 2 não abriu')
        self.ler_pedido()
        self.preencher(cep, so_digitos(e['cep']))
        num = self.campo('Número', exato=True)
        if e.get('numero'):
            if num is not None:
                self.preencher(num, e['numero'], devagar=False)
        else:
            sn = self.page.get_by_label(re.compile(r'sem n[uú]mero', re.I))
            if self.visivel(sn):
                sn.first.check()
        b = self.botao(r'^\s*buscar\s*$')
        if b:
            self.clicar(b)
        ref = self.esperar(lambda: (lambda r: r if r is not None and r.is_enabled() else None)(
            self.campo('Referência (Obrigatório)', 'Referência')), 30)
        pp = self.popup()
        if pp and not ref:
            self.out['popup'] = pp
            raise Parar('sem_viabilidade')
        if not ref:
            raise Parar('nao_classificado', texto_tela=self.texto_tela(), motivo='endereço não resolveu na Etapa 2')
        if e.get('complemento'):
            comp = self.campo('Complemento')
            if comp is not None and comp.is_enabled():
                try:
                    self.preencher(comp, e['complemento'], devagar=False)
                except Exception:  # noqa: BLE001
                    pass
        self.preencher(ref, e.get('referencia') or 'Sem referência', devagar=False)
        try:
            resolvido = self.page.evaluate(ENDERECO_JS)
        except Exception:  # noqa: BLE001
            resolvido = None
        self.out['endereco'] = {'origem': self.p['origem_endereco'], 'resolvido': resolvido, 'viabilidade': None}
        self.avancar()
        pp = self.esperar(self.popup, 45, passo=1)          # "Consultando viabilidade" 8–20 s
        if not pp:
            raise Parar('nao_classificado', texto_tela=self.texto_tela(), motivo='sem modal de viabilidade em 45 s')
        txt = f'{pp.get("titulo")} {pp.get("texto")}'
        continuar = next((x for x in pp.get('botoes') or [] if re.match(r'^\s*continuar\s*$', x, re.I)), None)
        if continuar and re.search(r'dispon', txt, re.I) and not re.search(r'indispon', txt, re.I):
            self.out['endereco']['viabilidade'] = resumo_viabilidade(pp)
            b = self.botao(r'^\s*continuar\s*$')
            if not b:
                raise Parar('erro', motivo='botão Continuar sumiu do modal de viabilidade')
            self.clicar(b)               # NUNCA "Salvar interesse" (lista negra)
            return
        self.out['popup'] = pp
        self.out['endereco']['viabilidade'] = resumo_viabilidade(pp)
        raise Parar('sem_viabilidade')

    def etapa3(self):
        cpf = self.esperar(lambda: self.campo('CPF/CNPJ', 'CPF'), 30)
        if not cpf:
            raise Parar('nao_classificado', texto_tela=self.texto_tela(), motivo='Etapa 3 não abriu')
        self._ir_etapa(3)
        self.pos_etapa2 = True           # a partir daqui, interesse/pré-venda na rede = trava
        self.ler_pedido()
        self.preencher(cpf, so_digitos(self.p['cpf']))
        tentativas = 0
        while True:
            b = self.botao(r'^\s*buscar\s*$')
            if b:
                self.clicar(b)

            def pronto():
                pp = self.popup()
                if pp:
                    return ('popup', pp)
                nome = self.campo('Nome completo')
                if nome is not None and (nome.input_value() or '').strip():
                    return ('nome', nome.input_value().strip())
                return None
            r = self.esperar(pronto, 45, passo=1)    # Receita 5–20 s
            if not r:
                raise Parar('nao_classificado', texto_tela=self.texto_tela(), motivo='Receita sem resposta em 45 s')
            if r[0] == 'nome':
                self.out['nome_receita'] = r[1]
                break
            pp = r[1]
            cls = classificar_popup(pp.get('titulo'), pp.get('texto'), 3)
            if cls == 'receita_retry':
                if tentativas >= 1:
                    self.out['popup'] = pp
                    raise Parar('erro_receita')
                tentativas += 1
                fechar = self.botao(r'tentar novamente')    # só fecha o modal; depois Buscar de novo
                if fechar:
                    self.clicar(fechar)
                self.page.wait_for_timeout(1500)
                continue
            self.parar_por_popup(pp)
        self.ler_pedido()
        self.avancar()
        # "Verificando duplicidade de pedido" 25–30 s → popup "Pedido encontrado" ou Etapa 4

        def depois():
            pp = self.popup()
            if pp:
                return ('popup', pp)
            if self.visivel(self.page.locator('input[name="contato"]')):
                return ('etapa4', None)
            return None
        r = self.esperar(depois, 60, passo=1)
        if not r:
            raise Parar('nao_classificado', texto_tela=self.texto_tela(), motivo='sem Etapa 4 em 60 s')
        if r[0] == 'popup':
            self.parar_por_popup(r[1])

    def etapa4(self):
        self._ir_etapa(4)
        c = self.p['contato']
        cel = so_digitos(c['celular'])
        for nome, valor in (('contato', cel), ('confirmacaoContato', cel), ('email', c['email']),
                            ('confirma-email', c['email'])):
            loc = self.page.locator(f'input[name="{nome}"]')
            if self.visivel(loc):
                self.preencher(loc.first, valor, devagar=nome in ('contato', 'confirmacaoContato'))
        aceite = self.page.locator('input[name="aceiteComunicacao"]')
        if aceite.count():                  # obrigatório (Ricardo, 11/11 16h15): sem ele o Avançar não habilita
            try:
                if not aceite.first.is_checked():
                    aceite.first.check(force=True)
            except Exception:  # noqa: BLE001
                pass
        self.page.wait_for_timeout(500)    # a página rola sozinha depois de preencher: clique por seletor
        self.avancar()

        def depois():
            pp = self.popup()
            if pp:
                return ('popup', pp)
            if self.page.locator('input[name="radio-group"]').count() > 0:
                return ('etapa5', None)
            return None
        r = self.esperar(depois, 60, passo=1)
        if not r:
            raise Parar('nao_classificado', texto_tela=self.texto_tela(), motivo='sem Etapa 5 em 60 s')
        if r[0] == 'popup':
            self.parar_por_popup(r[1])

    def etapa5(self):
        self._ir_etapa(5)                   # a partir daqui, NENHUM Avançar (clicar() recusa)
        self.page.wait_for_timeout(3000)   # popup atrasado (negado aparece em popup)
        self._checar_trava()
        pp = self.popup()
        if pp:
            self.parar_por_popup(pp)
        radios = self.esperar(lambda: [x for x in (self.page.evaluate(RADIOS_JS) or [])] or None, 40)
        formas = sorted({x['v'] for x in radios or [] if not x['d'] and x['v']})
        self.out['formas_liberadas'] = formas
        try:
            if self.p['origem_endereco'] == 'cliente':
                self.out['ofertas'] = [ler_oferta(t) for t in self.page.evaluate(OFERTAS_JS) or []]
        except Exception:  # noqa: BLE001
            pass
        cls = classificar_formas(formas)
        if not cls:
            pp = self.popup()
            if pp:
                self.parar_por_popup(pp)
            raise Parar('nao_classificado', texto_tela=self.texto_tela(), motivo='Etapa 5 sem formas habilitadas')
        raise Parar(cls)

    # ---------------------------------------------------------------- execução
    def rodar(self):
        t0 = time.time()
        self.page = self.ctx.new_page()
        self.page.route('**/*', self._rota)
        self.page.on('response', self._resposta)
        resultado, extra = 'erro', {}
        try:
            self.etapa0()
            self.etapa1()
            self.etapa2()
            self.etapa3()
            self.etapa4()
            self.etapa5()
        except Parar as p:
            resultado, extra = p.resultado, p.extra
        except TravaAcionada as t:
            resultado, extra = 'erro', {'motivo': str(t), 'trava': True}
        except SessaoCaida:
            raise
        except Exception as e:  # noqa: BLE001
            resultado, extra = 'erro', {'motivo': f'{type(e).__name__}: {sem_pii(e)}'}
        finally:
            if self.trava and resultado != 'erro':
                resultado, extra = 'erro', {'motivo': f'trava acionada: {self.trava}', 'trava': True}
            self.ler_pedido_seguro()
            self.amostras_corpos = self._ler_amostras()
            try:
                self.page.close()        # para sair de qualquer popup: fechar a página, nunca um botão dele
            except Exception:  # noqa: BLE001
                pass
        out = dict(self.out)
        out.update(resultado=resultado, etapa_parada=self.etapa or None, ms=int((time.time() - t0) * 1000))
        if extra.get('motivo'):
            out['motivo'] = sem_pii(extra['motivo'])
        if extra.get('texto_tela'):
            out['texto_tela'] = extra['texto_tela']
        if extra.get('trava'):
            out['trava'] = True
        if self.p['origem_endereco'] != 'cliente':
            out['ofertas'] = []
        return out

    def ler_pedido_seguro(self):
        try:
            if self.page and not self.page.is_closed():
                self.ler_pedido()
        except Exception:  # noqa: BLE001
            pass

    def _ler_amostras(self):
        corpos = []
        for r in self.respostas[:20]:
            item = {'caminho': caminho_de(r.url), 'metodo': r.request.method, 'status': r.status}
            try:
                item['corpo'] = redigir(r.json())
            except Exception:  # noqa: BLE001
                item['corpo'] = None
            corpos.append(item)
        return corpos


def gravar_amostra(pasta, job_id, out, corpos):
    """Um JSON por consulta, só com valores redigidos (estrutura e campos de status). Fora do repo, 7 dias."""
    if not pasta:
        return None
    try:
        os.makedirs(pasta, exist_ok=True)
        try:
            os.chmod(pasta, 0o700)
        except OSError:
            pass
        pp = out.get('popup') or None
        amostra = {
            'job': job_id[:8], 'quando': datetime.datetime.now().isoformat(timespec='seconds'),
            'resultado': out.get('resultado'), 'etapa_parada': out.get('etapa_parada'),
            'formas_liberadas': out.get('formas_liberadas'),
            'popup': {'titulo': sem_pii(pp.get('titulo')), 'texto': sem_pii(pp.get('texto')),
                      'botoes': pp.get('botoes')} if pp else None,
            'respostas': corpos,
        }
        nome = os.path.join(pasta, f'{datetime.datetime.now().strftime("%d%m%y_%H%M%S")}_{job_id[:8]}.json')
        with open(nome, 'w', encoding='utf-8') as f:
            json.dump(amostra, f, ensure_ascii=False, indent=1)
        return nome
    except Exception:  # noqa: BLE001
        return None
