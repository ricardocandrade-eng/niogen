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
# Consultas que a tela da Etapa 5 faz sozinha ao abrir (portabilidade do móvel: lista de DDDs da UF e de operadoras) e que
# casam "portabilidade" sem gravar nada. Barrar quebra a tela ("OPS, OCORREU UM ERRO!", visto em 11/11 17h40 e 18h16).
# Lista fechada: só rotas "consulta…" da portabilidade; qualquer outra rota de portabilidade segue barrada.
LIBERADOS = (
    re.compile(r'^api/portal/novafibra/portabilidadenovafibra/consulta[A-Za-z]+(/[A-Za-z0-9_-]{1,40})?$'),
)


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
    if any(p.match(c.lstrip('/')) for p in LIBERADOS):
        return None
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
              'sem_viabilidade', 'erro_receita', 'contato_repetido', 'nao_classificado', 'erro')
RE_ANDAMENTO = re.compile(r'já existe outro pedido|em andamento', re.I)
RE_NEGADO = re.compile(r'negad|não aprovad|nao aprovad|sem ofertas', re.I)
RE_PENDENTE = re.compile(r'pendente|24\s*h|aguard', re.I)
RE_RECEITA = re.compile(r'ops,?\s*ocorreu um erro', re.I)
# Etapa 4 (11/11 18h50): "Não é possível utilizar o telefone de contato informado pois excede a quantidade de repetições
# de mesmo número permitidas." — a Nio limita o mesmo celular em vários pedidos; a consulta precisa do celular do cliente.
RE_CONTATO = re.compile(r'repeti[cç][õo]es de mesmo n[úu]mero|telefone de contato informado', re.I)


def classificar_popup(titulo, texto, etapa=None):
    """Classifica um popup visível. 'receita_retry' = erro da Receita na Etapa 3 (o fluxo tenta 1× de novo)."""
    t = f'{titulo or ""} {texto or ""}'
    if RE_CONTATO.search(t):
        return 'contato_repetido'
    if RE_ANDAMENTO.search(t):
        return 'pedido_em_andamento'
    if RE_RECEITA.search(t) and etapa == 3:
        return 'receita_retry'
    if RE_NEGADO.search(t):
        return 'negado'
    if RE_PENDENTE.search(t):
        return 'pendente'
    return 'nao_classificado'


def tem_numero(opcao, numero):
    """A opção de endereço traz o número informado como número (não como parte de outro: 52 casa "Rua X, 52", não "520")."""
    return bool(re.search(r'(^|[\s,º°nN.-])' + re.escape(str(numero).strip()) + r'(?!\d)', str(opcao or '')))


def _sem_acento(t):
    import unicodedata
    return ''.join(c for c in unicodedata.normalize('NFD', str(t or '')) if unicodedata.category(c) != 'Mn')


def escolher_opcao(opcoes, valor):
    """Opção da lista do portal que corresponde ao valor digitado: igual (sem caixa/acento/espaços) ou, se só uma, que contém."""
    n = lambda t: re.sub(r'\W+', '', _sem_acento(t).lower())   # noqa: E731
    v = n(valor)
    if not v:
        return None
    iguais = [o for o in opcoes if n(o) == v]
    if iguais:
        return iguais[0]
    contem = [o for o in opcoes if v in n(o)]
    return contem[0] if len(contem) == 1 else None


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
RE_CHAVE_PII = re.compile(r'cpf|documento|nome|mae|nascimento|email|telefone|celular|endereco|sexo|genero|rg$|logradouro|cep|numero|whatsapp', re.I)
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
  // Os modais do portal (11/11) são uma camada position:fixed, z-index alto, do tamanho da tela, sem role nem classe
  // semântica (styled-components), com um cartão e os botões dentro. Carregando ("Consultando…") = mesma camada SEM botão.
  const vis = (el) => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el);
    return r.width > 60 && r.height > 40 && s.visibility !== 'hidden' && s.display !== 'none' && +s.opacity > 0.05; };
  const temBotao = (el) => [...el.querySelectorAll('button,[role=button]')].some((b) => vis(b) && (b.innerText || '').trim());
  const sel = '[role=dialog],[role=alertdialog],[aria-modal=true],.modal-content,.MuiDialog-paper,.swal2-popup,.ReactModal__Content';
  let cands = [...document.querySelectorAll(sel)].filter((el) => vis(el) && temBotao(el));
  if (!cands.length) {
    cands = [...document.querySelectorAll('body *')].filter((el) => {
      const s = getComputedStyle(el);
      if (s.position !== 'fixed' || !(+s.zIndex >= 100)) return false;
      const r = el.getBoundingClientRect();
      return r.width >= innerWidth * 0.5 && r.height >= innerHeight * 0.5 && vis(el) && temBotao(el);
    });
  }
  if (!cands.length) return null;
  const el = cands.find((c) => !cands.some((o) => o !== c && c.contains(o))) || cands[0];
  const h = el.querySelector('h1,h2,h3,h4,h5,h6,[class*=title i],[class*=Title]');
  const texto = (el.innerText || '').trim();
  const botoes = [...el.querySelectorAll('button,[role=button]')].filter(vis).map((b) => (b.innerText || '').trim()).filter(Boolean);
  return { titulo: h ? (h.innerText || '').trim() : (texto.split(/\r?\n/)[0] || ''), texto: texto.slice(0, 1200), botoes };
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
  for (const i of document.querySelectorAll('input[placeholder="Endereço de instalação"]')) {
    if ((i.value || '').trim()) return i.value.trim();
  }
  for (const s of document.querySelectorAll('select')) {
    const t = [...s.selectedOptions].map((o) => o.textContent.trim()).join(' ');
    if (t && !/selecione/i.test(t)) return t;
  }
  return null;
}
"""

NOME_JS = r"""
() => {
  const vis = (e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  for (const e of document.querySelectorAll('input')) {
    const k = `${e.name || ''} ${e.placeholder || ''} ${e.id || ''}`;
    if (vis(e) && /nome/i.test(k) && !/m[aã]e|social/i.test(k) && (e.value || '').trim()) return e.value.trim();
  }
  return null;
}
"""

ETAPA_JS = r"""
() => {
  // Retrato da área do pedido (sem o menu lateral): campos, opções abertas, avisos e botões. Sem valores digitados.
  const vis = (e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const raiz = document.querySelector('main') || document.body;
  const campos = [...raiz.querySelectorAll('input,select,textarea')].filter(vis).map((e) =>
    `${e.name || e.placeholder || e.type}${e.disabled ? ' (bloqueado)' : ''}${(e.value || '').trim() ? ' [preenchido]' : ' [vazio]'}`);
  const opcoes = [...raiz.querySelectorAll('li,[role=option]')].filter(vis).map((e) => (e.innerText || '').trim())
    .filter((t) => t && t.length < 160 && !/^etapa|^(identifica|consulta|cadastro|contato|pagamento)/i.test(t)).slice(0, 15);
  const avisos = [...raiz.querySelectorAll('[class*=error i],[class*=erro i],[class*=invalid i],[class*=feedback i],small,span')]
    .filter(vis).map((e) => (e.innerText || '').trim())
    .filter((t) => t && t.length < 200 && /n[aã]o|inv[aá]lid|obrigat|encontrad|informe|erro/i.test(t)).slice(0, 8);
  const botoes = [...raiz.querySelectorAll('button')].filter(vis).map((b) => `${(b.innerText || '').trim()}${b.disabled ? ' (bloqueado)' : ''}`).filter(Boolean);
  return { campos, opcoes, avisos: [...new Set(avisos)], botoes };
}
"""

ENDERECO_OPCOES_JS = r"""
() => {
  // Lista aberta sob o campo "Endereço de instalação" (o CEP trouxe mais de um endereço).
  const vis = (e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const inp = document.querySelector('input[placeholder="Endereço de instalação"]');
  if (!inp) return null;
  const caixa = inp.parentElement;
  const lis = [...(caixa ? caixa.querySelectorAll('li') : [])].filter(vis)
    .filter((l) => !l.hasAttribute('disabled') && !/nenhum resultado/i.test(l.innerText || ''));
  return { aberto: lis.length > 0, opcoes: lis.map((l) => (l.innerText || '').trim()).slice(0, 30),
           vazio: !(inp.value || '').trim(), bloqueado: inp.disabled };
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
                self.trava = f'{request.method} {barrado}'
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
            for loc in (self.page.locator(f'input[name="{n}"]'), self.page.get_by_placeholder(n, exact=exato),
                        self.page.get_by_label(n, exact=exato)):
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
            if self.campo('documento', 'CPF/CNPJ'):
                return 3
            if self.campo('cep', 'Endereço ou CEP'):
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
        """Retrato da área do pedido (campos, opções, avisos, botões) — não o menu lateral do portal."""
        try:
            r = self.page.evaluate(ETAPA_JS) or {}
            partes = [f'Etapa {self.etapa} · {ETAPAS.get(self.etapa, "")}']
            for chave, rot in (('avisos', 'Avisos'), ('opcoes', 'Opções na tela'), ('campos', 'Campos'), ('botoes', 'Botões')):
                if r.get(chave):
                    partes.append(f'{rot}: ' + ' · '.join(r[chave]))
            return sem_pii(chr(10).join(partes))[:900]
        except Exception:  # noqa: BLE001
            try:
                return sem_pii((self.page.inner_text('main') or '')[:800])
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
        # UF (MG) e PDV (1069521) chegam preenchidos alguns segundos DEPOIS do campo aparecer (visto em 11/11):
        # espera até 12 s antes de decidir que estão vazios.
        def _cheio(*nomes):
            loc = self.campo(*nomes)
            return loc is not None and (loc.input_value() or '').strip()
        self.esperar(lambda: _cheio('Informe a UF') and _cheio('Insira o código ou nome do seu PDV'), 12)
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
        cep = self.esperar(lambda: self.campo('cep', 'Endereço ou CEP'), 30)   # input name="cep" (visto em 11/11)
        self._ir_etapa(2)
        if not cep:
            raise Parar('erro', motivo='Etapa 2 não abriu')
        self.ler_pedido()
        self.preencher(cep, so_digitos(e['cep']))
        num = self.campo('numero', 'Número')
        if e.get('numero'):
            if num is not None:
                self.preencher(num, e['numero'], devagar=False)
        else:
            sn = self.page.locator('input[name="semNumero"]')
            if self.visivel(sn) and not sn.first.is_checked():
                sn.first.check(force=True)
        b = self.botao(r'^\s*buscar\s*$')
        if b:
            self.clicar(b)
        ref = self.resolver_endereco(e)
        pp = self.popup()
        if pp and not ref:
            self.out['popup'] = pp
            raise Parar('sem_viabilidade')
        if not ref:
            raise Parar('nao_classificado', texto_tela=self.texto_tela(), motivo='endereço não resolveu na Etapa 2')
        self.complemento(str(e.get('complemento') or '').strip())
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

    def resolver_endereco(self, e):
        """Depois do Buscar: espera a Referência habilitar. Se o CEP trouxe mais de um endereço, o portal abre uma lista
        em "Endereço de instalação" e espera a escolha (visto em 11/11 com um CEP de várias ruas/complementos): escolhe a
        opção com o número informado, ou a única opção; com várias e nenhuma clara, para e devolve a lista."""
        def ref_ok():
            r = self.campo('referencia', 'Referência (Obrigatório)')
            return r if r is not None and r.is_enabled() else None
        fim = time.time() + 35
        abriu = False
        while time.time() < fim:
            self._checar_trava()
            r = ref_ok()
            if r is not None:
                return r
            if self.popup():
                return None
            info = None
            try:
                info = self.page.evaluate(ENDERECO_OPCOES_JS)
            except Exception:  # noqa: BLE001
                pass
            if info and info.get('aberto'):
                ops = info['opcoes']
                num = str(e.get('numero') or '').strip()
                alvo = None
                if num:
                    alvo = next((o for o in ops if tem_numero(o, num)), None)
                if alvo is None and len(ops) == 1:
                    alvo = ops[0]
                if alvo is None:
                    raise Parar('nao_classificado', texto_tela=sem_pii('CEP com mais de um endereço; nenhum com o número '
                                                                          f'informado. Opções: ' + ' · '.join(ops[:15])),
                                motivo='CEP com vários endereços — confira o número/complemento')
                li = self.page.locator('input[placeholder="Endereço de instalação"] ~ ul li', has_text=alvo).first
                self.clicar(li)
                self.page.wait_for_timeout(1500)
                continue
            if info and info.get('vazio') and not info.get('bloqueado') and not abriu and time.time() > fim - 27:
                abriu = True            # campo liberado e vazio: abre a lista para ver as opções
                try:
                    self.clicar(self.page.locator('input[placeholder="Endereço de instalação"]').first)
                except TravaAcionada:
                    raise
                except Exception:  # noqa: BLE001
                    pass
            self.page.wait_for_timeout(700)
        return ref_ok()

    def complemento(self, valor):
        """Complemento: campo livre, <select> ou lista sugerida pelo portal ("CASA A", "CASA B"… — Ricardo, 11/11 19h).
        Com valor: escolhe a opção igual (ou que contém); sem opção que bata, para e devolve as opções. Sem valor: não mexe
        (se o portal exigir, o Avançar não habilita e a tela mostra as opções)."""
        if not valor:
            return
        pg = self.page
        sel = pg.locator('select[name*="omplement" i]')
        if self.visivel(sel):
            ops = [o.strip() for o in sel.first.locator('option').all_inner_texts() if o.strip()]
            alvo = escolher_opcao(ops, valor)
            if alvo is None:
                raise Parar('nao_classificado', texto_tela=sem_pii('Complemento não está na lista do portal. Opções: '
                                                                      + ' · '.join(ops[:20])),
                            motivo='complemento fora da lista do portal')
            sel.first.select_option(label=alvo)
            return
        comp = None
        for loc in (pg.locator('input[name*="omplement" i]'), pg.locator('input[placeholder*="omplement" i]')):
            if self.visivel(loc) and loc.first.is_enabled():
                comp = loc.first
                break
        if comp is None:
            return
        self.preencher(comp, valor, devagar=True)
        pg.wait_for_timeout(1500)
        try:
            ops = comp.evaluate("""(i) => { const vis = (e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
              const c = i.closest('div') && i.closest('div').parentElement || i.parentElement;
              return [...c.querySelectorAll('li,[role=option]')].filter(vis).map((l) => (l.innerText || '').trim())
                .filter((t) => t && !/nenhum resultado/i.test(t)).slice(0, 40); }""")
        except Exception:  # noqa: BLE001
            ops = []
        if not ops:
            return                       # campo livre: fica o texto digitado
        alvo = escolher_opcao(ops, valor)
        if alvo is None:
            raise Parar('nao_classificado', texto_tela=sem_pii('Complemento não está na lista do portal. Opções: '
                                                                  + ' · '.join(ops[:20])),
                        motivo='complemento fora da lista do portal')
        li = comp.locator('xpath=ancestor::div[1]/..').locator('li, [role=option]', has_text=alvo).first
        self.clicar(li)
        pg.wait_for_timeout(800)

    def etapa3(self):
        cpf = self.esperar(lambda: self.campo('documento', 'CPF/CNPJ'), 30)   # input name="documento" (11/11)
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
                nome = self.page.evaluate(NOME_JS)
                if nome:
                    return ('nome', nome)
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
                vistas, ofertas = set(), []
                for t in self.page.evaluate(OFERTAS_JS) or []:
                    o = ler_oferta(t)
                    chave = (o['nome'], o['velocidade'], o['preco'])
                    # cartão de plano = nome + velocidade + preço; fora: só preço, resumo repetido, aviso de taxa
                    if not o['velocidade'] or not o['preco'] or o['nome'].startswith('R$') or chave in vistas:
                        continue
                    vistas.add(chave)
                    ofertas.append(o)
                self.out['ofertas'] = ofertas
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
