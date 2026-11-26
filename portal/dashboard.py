#!/usr/bin/env python3
# NIOGEN | portal/dashboard.py | 25/11/2026 — Claude Code / Opus 5.5
# Operador do Dashboard (Performance em Foco, Power BI embutido no portal PAP), login de gestão com a SESSÃO GUARDADA na VPS
# (exceção da regra 5 do CLAUDE.md — Ricardo, 25/11/2026: "Vamos pelo terceiro caminho"). Por aba, o que a config manda:
#   importar → acerta os filtros (TIPO VENDA, Faixa… = Selecionar tudo; ANOMES = meses que existem) e exporta a tabela
#              pelo menu do próprio visual (⋯ › Exportar dados › Dados com layout atual › .xlsx) — como gente;
#   listar   → só anota os visuais da aba e quais têm "Mais opções" (o mapeamento). Não exporta nada.
# Lê também os cartões FPD/SPD/TPD (texto da tela). Devolve as linhas já no formato que o banco recebe
# (osab_importar 0168 · faturas_importar 0407). Prompt: docs/Prompt_operador_dashboard_osab_fpd_251126_1847.md (Drive).
#
# TRAVAS (regra 5 — testadas em testar_travas.py, seção 7):
#   - o robô só navega para /administrativo/dashboard; NUNCA clica no menu do portal (frame principal);
#   - dentro do Power BI só clica no que está na lista branca: as abas da config, os filtros da config, "Selecionar tudo",
#     os meses, "Mais opções" do visual da config, "Exportar dados", "Exportar", "Cancelar", "Fechar";
#   - rede: a API do portal só GET de sessão e do embed do Power BI; tudo que grava no portal é barrado.
# Nada de cliente sai daqui: o painel não traz nome, CPF, telefone nem endereço.
#
# CLI (dentro do container, sessão em /sessao/dash.json):
#   python dashboard.py rodar [aba…]   # roda e imprime o resumo (sem as linhas)
import datetime
import json
import os
import re
import sys
import time
import zipfile
import io
import unicodedata
import xml.etree.ElementTree as ET

DASH_URL = 'https://pap.niointernet.com.br/administrativo/dashboard'
SESSAO = os.environ.get('NIO_DASH_SESSAO', '/sessao/dash.json')
API_HOST = 'pap-api.niointernet.com.br'


class TravaAcionada(Exception):
    pass


class SessaoExpirada(Exception):
    pass


def log(m):
    print(f'[{datetime.datetime.now().strftime("%d/%m %H:%M:%S")}] dashboard: {m}', flush=True)


# ------------------------------------------------------------------------------------------------------------ travas
CLIQUES_FIXOS = {'Selecionar tudo', 'Mais opções', 'Exportar dados', 'Exportar', 'Cancelar', 'Fechar'}
MES = re.compile(r'^20\d{4}$')
REDE_SESSAO = [re.compile(p) for p in (r'^auth/user/info$', r'^api/portal/permissoes(/skills)?$', r'^manutencao$',
                                       r'^api/portal/powerbi/embed-info$', r'^auth/.*refresh.*$',
                                       r'^api/app/novafibra/supervisor/permissao/matricula/\w+$')]   # 26/11: a página lê ao abrir
# Renovação do token pelo SSO (26/11): o token do portal dura pouco; a sessão guardada é a da Microsoft. O robô passa de novo
# pelo login SAML da Nio (a Microsoft reconhece a sessão e volta sem pedir a chave). Só estas rotas, GET ou o POST do SAML.
REDE_SSO = re.compile(r'^(auth/saml/[\w/-]+|api/portal/loginbo)$')
PORTAL_SAML = 'https://pap-api.niointernet.com.br/auth/saml/login?origem=bo'


def clique_permitido(rotulo, cfg_abas):
    """rotulo = texto/aria do alvo. cfg_abas = lista da config (aba, visual, filtros)."""
    r = (rotulo or '').strip()
    if not r:
        return False
    if r in CLIQUES_FIXOS or MES.match(r):
        return True
    for a in cfg_abas or []:
        if r == a.get('aba') or r == ('filtro:' + str(a.get('aba'))):
            return True
        if r in (a.get('filtros') or {}):
            return True
    return False


def caminho_de(url):
    m = re.match(r'^[a-z]+://[^/]+/?([^?#]*)', str(url or ''), re.I)
    return (m.group(1) if m else '').strip('/')


def host_de(url):
    m = re.match(r'^[a-z]+://([^/?#]+)', str(url or ''), re.I)
    return (m.group(1) if m else '').lower()


def rede_bloqueada(url, metodo='GET'):
    """Devolve o caminho barrado ou None. API do portal: só GET de sessão e do embed. Front: só GET. Power BI e Microsoft
    passam (são as consultas e a exportação do próprio painel — leitura)."""
    metodo = str(metodo or 'GET').upper()
    h, c = host_de(url), caminho_de(url)
    if h == API_HOST:
        if metodo == 'GET' and any(p.match(c) for p in REDE_SESSAO):
            return None
        if metodo in ('GET', 'POST') and REDE_SSO.match(c):
            return None
        if metodo in ('GET', 'OPTIONS') and c.startswith('api/portal/') and not re.search(
                r'(credito|pedido|pagamento|checkout|biometria|aberturaos|agendamento|cancel|usuario|cadastro|gestao)', c, re.I):
            return None   # leituras que a página do Dashboard faz ao abrir (menu, avisos)
        return c or '(raiz da api)'
    if h.endswith('niointernet.com.br'):
        return None if metodo == 'GET' else (c or '(front)')
    return None


# ------------------------------------------------------------------------------------------------------------ planilha
NS = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'


def _col(ref):
    n = 0
    for ch in re.match(r'[A-Z]+', ref).group(0):
        n = n * 26 + ord(ch) - 64
    return n - 1


def ler_xlsx(dados):
    """xlsx (bytes) → lista de linhas (listas). Sem dependência: o Power BI grava inlineStr e números; sharedStrings também lido."""
    z = zipfile.ZipFile(io.BytesIO(dados))
    compart = []
    if 'xl/sharedStrings.xml' in z.namelist():
        for si in ET.fromstring(z.read('xl/sharedStrings.xml')).iter(NS + 'si'):
            compart.append(''.join(t.text or '' for t in si.iter(NS + 't')))
    folha = sorted(n for n in z.namelist() if n.startswith('xl/worksheets/sheet'))[0]
    linhas = []
    for row in ET.fromstring(z.read(folha)).iter(NS + 'row'):
        vals = {}
        for c in row.iter(NS + 'c'):
            i = _col(c.get('r')) if c.get('r') else len(vals)
            t = c.get('t')
            if t == 'inlineStr':
                v = ''.join(x.text or '' for x in c.iter(NS + 't'))
            elif t == 's':
                v = compart[int(c.find(NS + 'v').text)]
            else:
                e = c.find(NS + 'v')
                v = None if e is None or e.text is None else (float(e.text) if t != 'str' else e.text)
            vals[i] = v
        linhas.append([vals.get(i) for i in range(max(vals) + 1)] if vals else [])
    return linhas


def _partes(v):
    if v is None or v == '':
        return None
    if isinstance(v, (int, float)):
        d = datetime.datetime(1899, 12, 30) + datetime.timedelta(days=float(v))
        d = d + datetime.timedelta(microseconds=500000)   # arredonda ao segundo (mesmo resultado do osab.js)
        return d.year, d.month, d.day, d.hour, d.minute, d.second
    s = str(v).strip()
    m = re.match(r'^(\d{2})/(\d{2})/(\d{4})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?', s)
    if m:
        return int(m[3]), int(m[2]), int(m[1]), int(m[4] or 0), int(m[5] or 0), int(m[6] or 0)
    m = re.match(r'^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?', s)
    if m:
        return int(m[1]), int(m[2]), int(m[3]), int(m[4] or 0), int(m[5] or 0), int(m[6] or 0)
    return None


def data_iso(v):
    p = _partes(v)
    return f'{p[0]:04d}-{p[1]:02d}-{p[2]:02d}' if p else None


def data_hora_sp(v):
    p = _partes(v)
    return f'{p[0]:04d}-{p[1]:02d}-{p[2]:02d}T{p[3]:02d}:{p[4]:02d}:{p[5]:02d}-03:00' if p else None


def texto(v):
    if v is None:
        return None
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    s = str(v).strip()
    return s or None


def _norm(s):
    s = unicodedata.normalize('NFKD', str(s or '')).encode('ascii', 'ignore').decode()
    return re.sub(r'\s+', ' ', s).strip().upper()


def _tabela(linhas, obrig):
    """Acha a linha de cabeçalho; devolve (índice por nome normalizado, linhas de dados, rodapé de filtros)."""
    for i, r in enumerate(linhas[:10]):
        cab = [_norm(c) for c in r]
        if all(_norm(o) in cab for o in obrig):
            idx = {c: k for k, c in enumerate(cab) if c}
            dados, filtros = [], None
            for row in linhas[i + 1:]:
                if not row or all(c in (None, '') for c in row):
                    continue
                p = texto(row[0])
                if p and re.match(r'^filtros aplicados', p, re.I):
                    filtros = re.sub(r'\s*\n\s*', ' · ', p)[:400]
                    continue
                dados.append(row)
            return idx, dados, filtros
    raise ValueError('cabeçalho não encontrado (faltam ' + ', '.join(obrig) + ')')


def osab_painel(linhas):
    """Mesma leitura do docs/assets/osab.js (lerPainel) — uma regra só. Teste: testar_travas.py, seção 7."""
    idx, dados, filtros = _tabela(linhas, ['NR ORDEM', 'STATUS', 'DATA VENDA', 'DATA HORA - Atualização', 'DATA ATIVACAO'])
    col = lambda row, nome: (row[idx[_norm(nome)]] if _norm(nome) in idx and idx[_norm(nome)] < len(row) else None)  # noqa: E731
    juntar = lambda *p: ' · '.join(x for x in map(texto, p) if x) or None  # noqa: E731
    por = {}
    sem = 0
    for row in dados:
        ped = texto(col(row, 'NR ORDEM'))
        if not ped:
            sem += 1
            continue
        at = col(row, 'DATA HORA - Atualização')
        o = {
            'pedido': ped, 'dt_ref': data_iso(at), 'produto': texto(col(row, 'PLANO')), 'uf': texto(col(row, 'UF')),
            'localidade': texto(col(row, 'MUNICIPIO')), 'celula': texto(col(row, 'CELULA')), 'segmento': texto(col(row, 'SEGMENTO')),
            'velocidade': texto(col(row, 'VELOCIDADE')), 'matricula_vendedor': texto(col(row, 'MATRICULA VENDEDOR')),
            'situacao': texto(col(row, 'STATUS')), 'data_agendamento': data_hora_sp(col(row, 'DATA AGENDAMENTO')),
            'data_abertura': data_hora_sp(col(row, 'DATA VENDA')),
            'data_fechamento': data_hora_sp(col(row, 'FIM EXECUÇÃO REAL')) or data_hora_sp(col(row, 'DATA ATIVACAO')),
            'cod_pendencia': None, 'desc_pendencia': texto(col(row, 'PENDENCIA BA')), 'numero_ba': texto(col(row, 'NR BA')),
            'venda_valida': None, 'meio_pagamento': texto(col(row, 'MÉTODO PGTO')), 'campanha': texto(col(row, 'CAMPANHA')),
            'flg_mei': texto(col(row, 'TP MEI')), 'motivo_cancelamento': texto(col(row, 'MOTIVO ORDEM')),
            'submotivo_cancelamento': juntar(col(row, 'SUB MOTIVO'), col(row, 'DETALHE MOTIVO')), 'classificacao': None,
            'fonte': 'painel', 'atualizado_nio_em': data_hora_sp(at), 'data_ativacao': data_hora_sp(col(row, 'DATA ATIVACAO')),
            'estado_ba': texto(col(row, 'ESTADO BA')), 'status_ba': texto(col(row, 'STATUS BA')), 'motivo_ba': texto(col(row, 'MOTIVO BA')),
            'faixa_agendamento': texto(col(row, 'FAIXA AGENDAMENTO')),
            'execucao_inicio': data_hora_sp(col(row, 'INÍCIO EXECUÇÃO REAL')), 'execucao_fim': data_hora_sp(col(row, 'FIM EXECUÇÃO REAL')),
        }
        a = por.get(ped)
        if not a or str(o['atualizado_nio_em'] or '') > str(a['atualizado_nio_em'] or ''):
            por[ped] = o
    return {'linhas': list(por.values()), 'sem_pedido': sem, 'filtros': filtros}


def faturas_painel(linhas):
    idx, dados, filtros = _tabela(linhas, ['NR ORDEM', 'DT VENCIMENTO', 'STATUS PGTO'])
    nomes = {k: c for c, k in idx.items()}
    col = lambda row, nome: (row[idx[_norm(nome)]] if _norm(nome) in idx and idx[_norm(nome)] < len(row) else None)  # noqa: E731

    def achar(prefixo):
        for c in idx:
            if c.startswith(_norm(prefixo)):
                return c
        return None
    c_bloq = achar('DIAS ATE BLOQ')
    c_regra = achar('REGRA BLOQ')
    out = []
    for row in dados:
        ordem = texto(col(row, 'NR ORDEM'))
        if not ordem:
            continue
        num = lambda v: (int(float(v)) if v not in (None, '') and re.match(r'^-?\d+(\.\d+)?$', str(v).strip()) else None)  # noqa: E731
        out.append({
            'nr_ordem': ordem, 'nr_fatura': texto(col(row, 'NR FATURA')), 'indicador': texto(col(row, 'INDICADOR')),
            'dt_ativacao': data_iso(col(row, 'DT ATIVAÇÃO')), 'dt_geracao': data_iso(col(row, 'DT GERAÇÃO FATURA')),
            'dt_vencimento': data_iso(col(row, 'DT VENCIMENTO')), 'dt_pagamento': data_iso(col(row, 'DT PAGAMENTO')),
            'status_pgto': texto(col(row, 'STATUS PGTO')), 'dias_atraso': num(col(row, 'DIAS EM ATRASO')),
            'faixa': texto(col(row, 'FAIXA')), 'forma_pgto': texto(col(row, 'FORMA PGTO')), 'modelo_pgto': texto(col(row, 'MODELO PGTO')),
            'dias_ate_bloqueio': num(row[idx[c_bloq]]) if c_bloq and idx[c_bloq] < len(row) else None,
            'regra_bloqueio': texto(row[idx[c_regra]]) if c_regra and idx[c_regra] < len(row) else None,
            'bruto': {nomes[k]: texto(v) for k, v in enumerate(row) if k in nomes and texto(v) is not None},
        })
    return {'linhas': out, 'filtros': filtros}


def ler_cartao(txt):
    """'FPD (Data Vencimento) | 1 | STATUS | QTD. | % QTD. | Pagas | 1 | 100,0% | A vencer | 0 | …' → {pagas, a_vencer, vencidas}."""
    t = ' | '.join(x.strip() for x in str(txt or '').split('\n') if x.strip())
    out = {}
    for rot, chave in (('Pagas', 'pagas'), ('A vencer', 'a_vencer'), ('Vencidas', 'vencidas')):
        m = re.search(re.escape(rot) + r'\s*\|\s*(\d+)\s*\|', t)
        out[chave] = int(m.group(1)) if m else 0
    return out


# ------------------------------------------------------------------------------------------------------------ navegador
ITENS_JS = r"""() => [...document.querySelectorAll('.slicerItemContainer')].filter(e=>e.offsetParent)
  .map(e=>({t:(e.getAttribute('title')||e.innerText||'').trim(), chk:e.getAttribute('aria-checked')}))"""
MAPA_JS = r"""() => [...document.querySelectorAll('div.visualContainer[aria-roledescription]')].map(v => {
  const ct = v.closest('[data-testid="visual-container"]');
  return {titulo: (v.getAttribute('aria-label')||'').trim().slice(0,80), tipo: v.getAttribute('aria-roledescription'),
          tabela: /tabela|matriz/i.test(v.getAttribute('aria-roledescription') || '')};   // tabela/matriz = dá para exportar linha a linha
}).filter(x => x.tipo && x.tipo !== 'Segmentação de Dados')"""


class Dashboard:
    def __init__(self, ctx, abas_cfg, meses=2, log_fn=log):
        self.ctx = ctx
        self.cfg = abas_cfg or []
        self.meses = int(meses or 2)
        self.log = log_fn
        self.page = None
        self.fr = None
        self.barrados = []

    # -- travas
    def _rota(self, route, request):
        b = rede_bloqueada(request.url, request.method)
        if b:
            self.barrados.append(f'{request.method} {b}'[:120])
            return route.abort()
        return route.continue_()

    def _checar(self):
        # o logout que a própria página chama quando o token vence não é tentativa de gravar: é sessão caída (renova)
        outros = [b for b in self.barrados if not b.endswith('auth/logout')]
        if outros:
            raise TravaAcionada('rede barrada: ' + '; '.join(outros[:3]))

    def _clicar(self, loc, rotulo, **kw):
        if not clique_permitido(rotulo, self.cfg):
            raise TravaAcionada(f'clique fora da lista branca: {rotulo!r}')
        loc.click(**kw)

    # -- abrir
    def _renovar_sso(self):
        """Passa pelo login SAML da Nio. Sessão da Microsoft viva → volta ao portal sem tela nenhuma. Pediu usuário,
        senha ou a chave de acesso → a sessão guardada acabou (SessaoExpirada: o Ricardo refaz no PC)."""
        self.barrados = [b for b in self.barrados if not b.endswith('auth/logout')]
        self.page.goto(PORTAL_SAML, wait_until='domcontentloaded', timeout=60000)
        for _ in range(45):
            u = self.page.url
            if u.startswith('https://pap.niointernet.com.br/administrativo') and 'login-callback' not in u:
                self.page.wait_for_timeout(2000)
                self.log('token do portal renovado pelo SSO (sessão da Microsoft ainda válida)')
                return
            if 'login.microsoftonline.com' in u and (self.page.query_selector('input[name=loginfmt]:visible')
                                                    or self.page.query_selector('input[name=passwd]:visible')):
                raise SessaoExpirada('a Microsoft pediu login de novo: refazer a sessão (python portal/dashboard_sessao.py no PC)')
            self.page.wait_for_timeout(1000)
        raise SessaoExpirada('o SSO não voltou ao portal em 45 s: refazer a sessão (python portal/dashboard_sessao.py no PC)')

    def abrir(self, tentativa=1):
        if self.page is None:
            self.page = self.ctx.new_page()
            self.page.route('**/*', self._rota)
        self.page.goto(DASH_URL, wait_until='domcontentloaded', timeout=60000)
        caiu = False
        for _ in range(60):
            if any(b.endswith('auth/logout') for b in self.barrados) or 'login.microsoftonline.com' in self.page.url:
                caiu = True
                break
            el = self.page.query_selector('iframe[src*="powerbi"]')
            if el:
                self.fr = el.content_frame()
                break
            self.page.wait_for_timeout(1000)
        else:
            caiu = True
        if caiu:
            if tentativa > 1:
                raise SessaoExpirada('o Dashboard não abriu nem depois de renovar o token pelo SSO')
            self._renovar_sso()
            return self.abrir(tentativa=2)
        for _ in range(40):
            try:
                if self.fr.locator('[role=tab]').count() > 3:
                    break
            except Exception:  # noqa: BLE001
                pass
            self.page.wait_for_timeout(2000)
        else:
            raise RuntimeError('as abas do painel não apareceram em 80 s')
        self._checar()
        try:
            self.atualizado = self.fr.evaluate(
                """() => { const v = document.querySelector('div.visualContainer[aria-label^="ATUALIZADO"]');
                   const c = v && v.closest('[data-testid="visual-container"]');
                   return c ? c.innerText.replace(/\\s+/g, ' ').trim().slice(0, 40) : null; }""")
        except Exception:  # noqa: BLE001
            self.atualizado = None

    def ir_aba(self, nome):
        self._clicar(self.fr.get_by_role('tab', name=nome, exact=True), nome)
        self.page.wait_for_timeout(8000)
        self._checar()

    def _itens(self):
        return self.fr.evaluate(ITENS_JS)

    def filtro(self, nome, modo):
        cb = self.fr.get_by_role('combobox', name=nome, exact=True)
        if cb.count() == 0:
            raise RuntimeError(f'filtro {nome} não existe nesta aba')
        self._clicar(cb, nome)
        self.page.wait_for_timeout(2000)
        its = self._itens()
        if modo == 'todos':
            st = [i for i in its if i['t'] == 'Selecionar tudo']
            if st and st[0]['chk'] != 'true':
                self._clicar(self.fr.locator('.slicerItemContainer[title="Selecionar tudo"]:visible').first, 'Selecionar tudo')
                self.page.wait_for_timeout(2500)
        elif modo == 'meses':
            meses = sorted([i['t'] for i in its if MES.match(i['t'])], reverse=True)[:self.meses]
            for m in meses:
                atual = next((i for i in self._itens() if i['t'] == m), None)
                if atual and atual['chk'] != 'true':
                    self._clicar(self.fr.locator(f'.slicerItemContainer[title="{m}"]:visible').first, m, modifiers=['Control'])
                    self.page.wait_for_timeout(2000)
        depois = self._itens()
        self.page.keyboard.press('Escape')
        self.page.wait_for_timeout(1500)
        self._checar()
        return {'filtro': nome, 'modo': modo, 'marcados': [i['t'] for i in depois if i['chk'] == 'true'][:12],
                'mostra': cb.inner_text().strip()[:40]}

    def exportar(self, visual):
        tab = self.fr.locator(f'div.visualContainer[aria-roledescription="Visual de tabela"][aria-label^="{visual}"]')
        if tab.count() != 1:
            raise RuntimeError(f'tabela "{visual}" não encontrada ({tab.count()})')
        tab.hover()
        self.page.wait_for_timeout(800)
        mais = self.fr.locator('[data-testid="visual-container"]').filter(has=tab).locator('button[aria-label="Mais opções"]')
        if mais.count() == 0:
            raise RuntimeError('o visual não tem "Mais opções"')
        if not clique_permitido('Mais opções', self.cfg):
            raise TravaAcionada('Mais opções fora da lista')
        mais.first.evaluate('b => b.click()')   # o cabeçalho do visual some ao mover o mouse: clique direto no botão
        self.page.wait_for_timeout(1500)
        self._clicar(self.fr.get_by_text('Exportar dados', exact=True).first, 'Exportar dados')
        self.page.wait_for_timeout(2500)
        with self.page.expect_download(timeout=120000) as dl:
            self._clicar(self.fr.get_by_role('button', name='Exportar', exact=True), 'Exportar')
        caminho = dl.value.path()
        with open(caminho, 'rb') as f:
            dados = f.read()
        try:
            dl.value.delete()
        except Exception:  # noqa: BLE001
            pass
        self._checar()
        return dados

    def cartoes(self):
        out = {}
        for f in self.page.frames:
            if 'cvSandboxPack' not in f.url:
                continue
            try:
                t = f.locator('body').inner_text(timeout=3000)
            except Exception:  # noqa: BLE001
                continue
            m = re.match(r'\s*(FPD|SPD|TPD)\b', t)
            if m:
                out[m.group(1)] = ler_cartao(t)
        return out

    def mapear(self):
        return self.fr.evaluate(MAPA_JS)

    # -- rodada
    def rodar(self, so=None):
        ini = datetime.datetime.now(datetime.timezone.utc).isoformat()
        self.abrir()
        res = {'iniciada_em': ini, 'atualizado_painel': self.atualizado, 'abas': {}, 'mapa': [], 'osab': None, 'faturas': None}
        for a in self.cfg:
            nome = a.get('aba')
            if so and nome not in so:
                continue
            t0 = time.time()
            item = {'modo': a.get('modo')}
            try:
                self.ir_aba(nome)
                if a.get('modo') == 'importar':
                    item['filtros'] = [self.filtro(k, v) for k, v in (a.get('filtros') or {}).items()]
                    if nome.startswith('Dinâmica - FPD'):
                        item['cartoes'] = self.cartoes()
                    dados = self.exportar(a.get('visual'))
                    linhas = ler_xlsx(dados)
                    if 'OSAB' in (a.get('visual') or ''):
                        o = osab_painel(linhas)
                        res['osab'] = {'linhas': o['linhas'], 'filtros': o['filtros'], 'arquivo': f'Dashboard OSAB {ini[:10]}'}
                        item['linhas'] = len(o['linhas'])
                    else:
                        fa = faturas_painel(linhas)
                        res['faturas'] = {'linhas': fa['linhas'], 'filtros': fa['filtros'], 'cartoes': item.get('cartoes'),
                                          'arquivo': f'Dashboard Faturas {ini[:10]}'}
                        item['linhas'] = len(fa['linhas'])
                    item['ok'] = True
                else:
                    vis = self.mapear()
                    res['mapa'].append({'aba': nome, 'visuais': vis})
                    item.update(ok=True, visuais=len(vis))
            except (TravaAcionada, SessaoExpirada):
                raise
            except Exception as e:  # noqa: BLE001
                item.update(ok=False, erro=f'{type(e).__name__}: {str(e)[:200]}')
                self.log(f'{nome}: {item["erro"]}')
            item['segundos'] = round(time.time() - t0, 1)
            res['abas'][nome] = item
        res['ok'] = all(v.get('ok') for k, v in res['abas'].items() if v.get('modo') == 'importar')
        return res


def main():
    from playwright.sync_api import sync_playwright
    so = sys.argv[2:] or None
    abas = json.loads(os.environ.get('DASH_ABAS') or 'null') or [
        {'aba': 'Dinâmica - OSAB', 'modo': 'importar', 'visual': 'Exportação - OSAB', 'filtros': {'tp_venda_irregular': 'todos', 'ANOMES': 'meses'}},
        {'aba': 'Dinâmica - FPD SPD TPD', 'modo': 'importar', 'visual': 'Exportação - Faturas',
         'filtros': {'FAIXA': 'todos', 'NR_DIAS_ATE_BLOQUEIO': 'todos', 'ANOMES': 'todos'}},
        {'aba': 'Geral', 'modo': 'listar'}]
    with sync_playwright() as pw:
        nav = pw.chromium.launch(headless=True, args=['--no-sandbox', '--disable-dev-shm-usage'])
        ctx = nav.new_context(storage_state=SESSAO, locale='pt-BR', timezone_id='America/Sao_Paulo',
                              viewport={'width': 1600, 'height': 1000}, accept_downloads=True)
        try:
            r = Dashboard(ctx, abas).rodar(so)
            ctx.storage_state(path=SESSAO)
        finally:
            ctx.close()
            nav.close()
    for k in ('osab', 'faturas'):
        if r.get(k):
            r[k] = {'linhas': len(r[k]['linhas']), 'filtros': r[k]['filtros']}
    print(json.dumps(r, ensure_ascii=False, indent=1)[:4000])


if __name__ == '__main__':
    if len(sys.argv) < 2 or sys.argv[1] != 'rodar':
        sys.exit('uso: python dashboard.py rodar [aba…]')
    main()
