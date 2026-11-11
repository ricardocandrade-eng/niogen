#!/usr/bin/env python3
# NIOGEN | dfv/operador.py | 11/11/2026 — Claude Code (docs/Prompt_operador_dfv_cobertura_111126_1520.md)
# OPERADOR DFV: um Chromium sem janela, logado como PARCEIRO no painel publicado da Nio "Direcionamento Força de
# Vendas — Sudeste" (Power BI publish-to-web), que responde CONSULTA-SÓ de viabilidade por CEP + número.
#
# Como lê (11/11):
#   1. login igual ao humano: usuário PARCEIRO, Senha 1 + Enter, Senha 2 + Enter (aviso "ok"), ENTRAR → página "3 de 4".
#   2. ao abrir a página 3, o próprio painel pede os dados da grade de fachadas, do mapa (lat/long) e da data da base.
#      O operador guarda esses pedidos como MODELO (são do painel, já com os filtros do login) e, a cada consulta,
#      repete o mesmo pedido DE DENTRO DA PÁGINA trocando só os filtros UF / CEP (/ MUNICIPIO). ~1 s por consulta.
#   3. se o modelo não existir ou o painel recusar (Nio republicou), refaz o login (recaptura) uma vez; se ainda falhar,
#      cai no caminho da TELA: escolhe UF / MUNICIPIO / CEP / NO_FACHADA nos filtros e lê a grade (role=grid) — ~30 s.
#   Nada de assinatura, token ou bloqueio contornado: o pedido é o que a página publicada faz, com a chave pública dela.
#
# Rotas (todas exigem Authorization: Bearer DFV_OP_TOKEN; sem ele, 401):
#   GET /saude                                   → {ok, logado, modelos, atualizado_painel, ultimo_uso, ultimo_erro}
#   GET /dfv?uf=MG&municipio=JUIZ%20DE%20FORA&cep=36010000&numero=241[&complemento=]  → JSON da consulta (README)
#   POST /renovar                                → refaz o login
# Segredos só no .env da VPS (SDE_USUARIO, SDE_SENHA1, SDE_SENHA2, DFV_URL, DFV_OP_TOKEN). Log sem endereço completo.

import copy
import datetime
import hmac
import json
import math
import os
import re
import sys
import time
import unicodedata
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

PORTA = int(os.environ.get('DFV_OP_PORTA', '8091'))
TOKEN = (os.environ.get('DFV_OP_TOKEN') or '').strip()
URL = (os.environ.get('DFV_URL') or '').strip()
USUARIO = (os.environ.get('SDE_USUARIO') or 'PARCEIRO').strip()
SENHA1 = (os.environ.get('SDE_SENHA1') or '').strip()
SENHA2 = (os.environ.get('SDE_SENHA2') or '').strip()
CACHE_S = int(os.environ.get('DFV_CACHE_S', '600'))          # mesma consulta de CEP em 10 min = memória
LIMITE_MIN = 30                                                 # freio contra laço
TZ = datetime.timezone(datetime.timedelta(hours=-3))
CHAVES_FILTRO = {'UF', 'MUNICIPIO', 'CEP', 'NO_FACHADA', 'COMPLEMENTO1', 'BAIRRO', 'LOGRADOURO'}

# Grade da página 3: nome no painel → nome no JSON
COLS = {
    'BASE_HP_F.UF': 'uf', 'BASE_HP_F.CODIGO_LOGRADOURO': 'cd_logradouro', 'BASE_HP_F.CODIGO_CDO': 'cd_cdo',
    'BASE_HP_F.CLASSIFICACAO': 'classificacao', 'BASE_HP_F.CELULA': 'celula', 'BASE_HP_F.BAIRRO': 'bairro',
    'BASE_HP_F.LOGRADOURO': 'logradouro', 'BASE_HP_F.NO_FACHADA': 'numero', 'BASE_HP_F.COMPLEMENTO1': 'complemento',
    'BASE_HP_F.COMPLEMENTO2': 'complemento2', 'BASE_HP_F.COMPLEMENTO3': 'complemento3', 'BASE_HP_F.CEP': 'cep',
    'BASE_HP_F.HPS': 'hps', 'MEDIDAS.HP_LIVRE': 'hp_livre', 'BASE_HP_F.HCS': 'hcs',
    'BASE_HP_F.VIABILIDADE_ATUAL': 'viabilidade', 'BASE_HP_F.FLAG_GROSS_6M_CEL': 'flag_gross_6m',
    'BASE_HP_F.ds_faixa_aprovacao_credito_total': 'faixa_credito', 'Sum(BASE_HP_F.F_HP_NOVO)': 'flag_hp_novo',
}
GRADE_TELA = {'UF': 'uf', 'CD_LOGRADOURO': 'cd_logradouro', 'CD_CDO': 'cd_cdo', 'CLASSIFICACAO': 'classificacao',
              'CELULA': 'celula', 'BAIRRO': 'bairro', 'LOGRADOURO': 'logradouro', 'NO_FACHADA': 'numero',
              'COMP.1': 'complemento', 'COMP.2': 'complemento2', 'COMP.3': 'complemento3', 'CEP': 'cep', 'HPS': 'hps',
              'HP_LIVRE': 'hp_livre', 'HCS': 'hcs', 'VIABILIDADE': 'viabilidade', 'FLAG GROSS 6M': 'flag_gross_6m',
              'FAIXA APROVAÇÃO TT': 'faixa_credito', 'FLAG HP NOVO': 'flag_hp_novo'}


def log(msg):
    print(f'{datetime.datetime.now(TZ):%d/%m %H:%M:%S} {msg}', flush=True)


def agora():
    return datetime.datetime.now(TZ).isoformat(timespec='seconds')


class Falha(Exception):
    pass


# ---------------------------------------------------------------- formato DSR das respostas do Power BI
def decodificar(resp):
    """Resposta querydata → lista de linhas {nome da coluna: valor}. Formato DSR v2 (comprimido: C/R/Ø/ValueDicts/M)."""
    res = resp['results'][0]['result']['data']
    nome = {s['Value']: s.get('Name') for s in res['descriptor']['Select']}
    ds = res['dsr']['DS'][0]
    dicts = ds.get('ValueDicts', {})
    linhas = []

    def dm(rows, pai):
        esquema, ant = None, None
        for r in rows:
            if 'S' in r:
                esquema = r['S']
                ant = [None] * len(esquema)
            if esquema is None:
                continue
            rep, nul = r.get('R', 0), r.get('Ø', 0)
            c = list(r.get('C', []))
            atual = []
            for i, col in enumerate(esquema):
                if col['N'] in r:
                    v = r[col['N']]
                elif rep >> i & 1:
                    v = ant[i]
                elif nul >> i & 1:
                    v = None
                else:
                    v = c.pop(0) if c else None
                if col.get('DN') and isinstance(v, int):
                    v = dicts[col['DN']][v]
                atual.append(v)
            ant = atual
            vals = dict(pai)
            vals.update({nome.get(col['N'], col['N']): atual[i] for i, col in enumerate(esquema)})
            if 'M' in r:
                for filho in r['M']:
                    for _, sub in filho.items():
                        dm(sub, vals)
            else:
                linhas.append(vals)

    for ph in ds.get('PH', []):
        for _, rows in ph.items():
            dm(rows, {})
    return linhas


def _selects(corpo):
    try:
        q = json.loads(corpo)['queries'][0]['Query']['Commands'][0]['SemanticQueryDataShapeCommand']['Query']
        return [s.get('Name') or '' for s in q.get('Select', [])]
    except Exception:  # noqa: BLE001
        return []


def tipo_do_pedido(corpo):
    s = _selects(corpo)
    if any('VIABILIDADE_ATUAL' in x for x in s) and any('CODIGO_LOGRADOURO' in x for x in s):
        return 'grade'
    if any('LATITUDE' in x for x in s) and any('LONGITUDE' in x for x in s):
        return 'mapa'
    if s == ['Min(BASE_HP_F.dt_dfv_particao)']:
        return 'data'
    return None


def com_filtros(corpo, filtros, janela=None):
    """Copia o pedido do painel trocando os filtros de endereço (In em BASE_HP_F.<col>) e tirando o TopN da grade."""
    b = json.loads(corpo)
    cmd = b['queries'][0]['Query']['Commands'][0]['SemanticQueryDataShapeCommand']
    q = cmd['Query']
    fonte = next((f['Name'] for f in q['From'] if f.get('Entity') == 'BASE_HP_F'), None)
    if not fonte:
        raise Falha('modelo sem BASE_HP_F')
    novo = []
    for w in q.get('Where', []):
        c = w.get('Condition', {})
        if 'In' in c:
            ex = c['In'].get('Expressions', [{}])[0].get('Column', {})
            if ex.get('Expression', {}).get('SourceRef', {}).get('Source') == fonte and ex.get('Property') in CHAVES_FILTRO:
                continue
        lado = c.get('Comparison', {}).get('Left', {}).get('Measure', {})
        if lado.get('Property') == 'Mostrar TopN':
            continue
        novo.append(w)
    for col, val in filtros.items():
        if val in (None, ''):
            continue
        lit = "'" + str(val).replace("'", "''") + "'"
        novo.append({'Condition': {'In': {
            'Expressions': [{'Column': {'Expression': {'SourceRef': {'Source': fonte}}, 'Property': col}}],
            'Values': [[{'Literal': {'Value': lit}}]]}}})
    q['Where'] = novo
    if janela:
        try:
            cmd['Binding']['DataReduction']['Primary']['Window']['Count'] = janela
        except (KeyError, TypeError):
            pass
    b['cancelQueries'] = []
    return json.dumps(b, ensure_ascii=False)


# ---------------------------------------------------------------- utilidades de endereço
def so_digitos(s):
    return re.sub(r'\D', '', str(s or ''))


def norm(s):
    s = unicodedata.normalize('NFKD', str(s or '')).encode('ascii', 'ignore').decode().upper()
    return re.sub(r'[^A-Z0-9]', '', s)


def uf_do_cep(cep):
    n = int(cep[:5]) if len(cep) >= 5 and cep[:5].isdigit() else -1
    if 30000 <= n <= 39999:
        return 'MG'
    if 29000 <= n <= 29999:
        return 'ES'
    if 20000 <= n <= 28999:
        return 'RJ'
    if 1000 <= n <= 19999:
        return 'SP'
    return None


def num_int(s):
    m = re.match(r'\d+', str(s or ''))
    return int(m.group()) if m else None


def haversine_m(a, b):
    r = 6371000.0
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def montar(entrada, linhas, pontos, particao_ms, metodo, ms):
    """Linhas da grade (+ pontos do mapa) → JSON da consulta (formato do prompt)."""
    numero = (entrada.get('numero') or '').strip()
    comp = norm(entrada.get('complemento'))
    # lat/long: o mapa agrupa por (classificação, lat, long) com Min(NO_FACHADA) e Min(BAIRRO) — casa por número + bairro.
    geo = {}
    for p in pontos:
        k = (str(p.get('Min(BASE_HP_F.NO_FACHADA)') or ''), norm(p.get('Min(BASE_HP_F.BAIRRO)')))
        if p.get('BASE_HP_F.LATITUDE') is not None:
            geo.setdefault(k, (p['BASE_HP_F.LATITUDE'], p['BASE_HP_F.LONGITUDE']))
    fach = []
    for l in linhas:
        f = {COLS.get(k, k): v for k, v in l.items() if k in COLS}
        if not f.get('numero') and not f.get('logradouro'):
            continue                                            # linha de total
        g = geo.get((str(f.get('numero') or ''), norm(f.get('bairro'))))
        f['lat'], f['lon'] = (g if g else (None, None))
        fach.append(f)
    fach.sort(key=lambda f: (norm(f.get('logradouro')), num_int(f.get('numero')) or 0, str(f.get('complemento') or '')))

    match, viab, achadas = 'sem_numero', None, []
    if numero:
        achadas = [f for f in fach if str(f.get('numero') or '').strip().upper() == numero.upper()]
        if comp and achadas:
            exatas = [f for f in achadas if comp in (norm(f.get('complemento')), norm(f.get('complemento2')),
                                                     norm(f.get('complemento3')))]
            achadas = exatas or achadas
        match = 'exato' if achadas else 'nao_encontrado'
        viab = 'viavel' if achadas else 'nao_encontrado'
    else:
        viab = 'rua_viavel' if fach else 'nao_encontrado'
    ref = achadas[0] if achadas else (fach[0] if fach else None)

    regra = {'status': 'nao_avaliada_v1',
             'nota': 'v1: sem lat/long do endereço do cliente — conferir os 200 m no mapa do painel.'}
    if match == 'exato':
        regra = {'status': 'dentro', 'nota': 'A própria fachada está na base de viáveis.'}
    elif match == 'nao_encontrado' and fach:
        alvo = num_int(numero)
        viz = sorted((f for f in fach if num_int(f.get('numero')) is not None),
                     key=lambda f: abs(num_int(f['numero']) - alvo) if alvo is not None else 0)
        perto = viz[0] if viz else None
        regra['nota'] = ('Há fachadas viáveis neste CEP — conferir os 200 m no mapa do painel'
                         + (f' (a mais próxima pela numeração: nº {perto["numero"]}, {perto.get("logradouro") or ""}).'
                            if perto else '.'))
        regra['vizinha_mais_proxima'] = ({'numero': perto['numero'], 'logradouro': perto.get('logradouro'),
                                          'lat': perto.get('lat'), 'lon': perto.get('lon')} if perto else None)
        # TODO v2: geocodificar o endereço do cliente e usar haversine_m() até a fachada viável mais próxima → dentro/fora.
    elif not fach:
        regra = {'status': 'indefinido', 'nota': 'Nenhuma fachada viável neste CEP no painel — conferir CEP/rua no portal.'}

    atual = (datetime.datetime.fromtimestamp(particao_ms / 1000, datetime.timezone.utc).strftime('%d/%m/%Y')
             if particao_ms else None)
    return {
        'consultado_em': agora(),
        'atualizado_painel': atual,
        'fonte': 'ao_vivo',
        'metodo': metodo,
        'ms': ms,
        'entrada': {k: entrada.get(k) for k in ('uf', 'municipio', 'cep', 'numero', 'complemento')},
        'match': match,
        'viabilidade': viab,
        'faixa_credito_bairro': (ref or {}).get('faixa_credito'),
        'bairro': (ref or {}).get('bairro'),
        'logradouro': (ref or {}).get('logradouro'),
        'celula': (ref or {}).get('celula'),
        'classificacao': (ref or {}).get('classificacao'),
        'fachada': achadas[0] if achadas else None,
        'unidades': achadas if len(achadas) > 1 else [],
        'fachadas_no_cep': fach[:300],
        'total_fachadas_no_cep': len(fach),
        'regra_200m': regra,
    }


# ---------------------------------------------------------------- o navegador
class Operador:
    def __init__(self):
        from playwright.sync_api import sync_playwright
        self.pw = sync_playwright().start()
        self.nav = None
        self.page = None
        self.modelos = {}          # tipo → {'url', 'headers', 'corpo'}
        self.cache = {}            # (uf, municipio, cep) → (instante, linhas, pontos, particao)
        self.chamadas = []
        self.leve = False          # True = relatório fechado, página leve do mesmo domínio (só caminho rápido)
        self.capturando = False    # só guarda os pedidos do próprio painel durante o login (não os nossos)
        self.estado = {'logado': False, 'logado_em': None, 'ultimo_uso': None, 'ultimo_erro': None,
                       'ultimo_erro_em': None, 'atualizado_painel': None, 'consultas': 0}

    # ---------------- login
    def _ouvir(self, req):
        if not self.capturando or 'querydata' not in req.url or req.method != 'POST':
            return
        corpo = req.post_data or ''
        t = tipo_do_pedido(corpo)
        if t and 'PSenha1' in corpo:                     # só pedidos já com o login (o "check" do painel)
            h = req.headers
            self.modelos[t] = {'url': req.url, 'corpo': corpo,
                               'chave': h.get('x-powerbi-resourcekey') or h.get('X-PowerBI-ResourceKey')}

    def login(self, leve=True):
        t0 = time.time()
        if not URL or not SENHA1 or not SENHA2:
            raise Falha('faltam DFV_URL / SDE_SENHA1 / SDE_SENHA2 no .env')
        if self.nav is None or not self.nav.is_connected():
            self.nav = self.pw.chromium.launch(headless=True, channel=os.environ.get('DFV_CHROME_CANAL') or None, args=['--no-sandbox', '--disable-dev-shm-usage',
                                                                    '--disable-gpu'])
        if self.page is not None:
            try:
                self.page.context.close()
            except Exception:  # noqa: BLE001
                pass
        ctx = self.nav.new_context(viewport={'width': 1600, 'height': 1000}, locale='pt-BR',
                                   timezone_id='America/Sao_Paulo')
        # Azulejos de mapa e imagens não fazem falta para ler dados: menos memória e banda na VPS.
        ctx.route(re.compile(r'atlas\.microsoft\.com|\.(png|jpg|jpeg|gif|woff2?)(\?|$)'), lambda r: r.abort())
        pg = ctx.new_page()
        pg.on('request', self._ouvir)
        self.modelos = {}
        self.cache = {}
        self.capturando = True
        pg.goto(URL, wait_until='domcontentloaded', timeout=90000)
        pg.wait_for_function("() => /LOGIN DE ACESSO/.test(document.body.innerText||'')", timeout=90000)
        pg.wait_for_timeout(1000)
        pg.locator('.slicer-dropdown-menu').first.click()
        pg.locator('.slicer-dropdown-popup').get_by_text(USUARIO, exact=True).click()
        pg.keyboard.press('Escape')
        pg.wait_for_function("() => /Digite a senha/.test(document.body.innerText||'')", timeout=30000)
        ins = pg.locator('input.date-slicer-input')
        ins.nth(0).click()
        ins.nth(0).fill(SENHA1)
        ins.nth(0).press('Enter')
        pg.wait_for_timeout(2500)
        ins.nth(2).click()
        ins.nth(2).fill(SENHA2)
        ins.nth(2).press('Enter')
        pg.wait_for_function(
            "() => [...document.querySelectorAll('visual-container')].some(v => (v.innerText||'').trim() === 'ok')",
            timeout=30000)
        pg.get_by_text('ENTRAR', exact=True).click()
        pg.wait_for_function(
            "() => [...document.querySelectorAll('visual-container')].some(v => /CD_LOGRADOURO/.test(v.innerText||''))",
            timeout=90000)
        fim = time.time() + 20
        while time.time() < fim and not {'grade', 'data'} <= set(self.modelos):
            pg.wait_for_timeout(500)
        self.capturando = False
        self.page = pg
        self.leve = False
        if leve and {'grade', 'data'} <= set(self.modelos):
            # Com os modelos guardados, o relatório (mapa com ~20 mil pontos) não precisa ficar aberto: a página vai
            # para um arquivo leve do mesmo domínio e os pedidos continuam saindo dela (~250 MB a menos na VPS).
            pg.goto('https://app.powerbi.com/robots.txt', wait_until='domcontentloaded', timeout=30000)
            self.leve = True
        self.estado.update(logado=True, logado_em=agora())
        log(f'login ok ({time.time() - t0:.1f} s, modelos: {sorted(self.modelos)}{", página leve" if self.leve else ""})')

    # ---------------- caminho rápido: o pedido do próprio painel, de dentro da página
    def _pedir(self, tipo, filtros, janela=None):
        m = self.modelos.get(tipo)
        if not m:
            raise Falha(f'sem modelo "{tipo}"')
        corpo = com_filtros(m['corpo'], filtros, janela)
        r = self.page.evaluate("""async ({url, chave, corpo, aid, rid}) => {
            const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 15000);
            try {
              const r = await fetch(url, {method: 'POST', body: corpo, signal: ctl.signal, headers: {
                'Content-Type': 'application/json;charset=UTF-8', 'Accept': 'application/json, text/plain, */*',
                'X-PowerBI-ResourceKey': chave, 'ActivityId': aid, 'RequestId': rid}});
              const txt = await r.text();
              return {status: r.status, txt};
            } catch (e) { return {status: 0, txt: String(e)}; } finally { clearTimeout(t); }
        }""", {'url': m['url'], 'chave': m['chave'], 'corpo': corpo, 'aid': str(uuid.uuid4()), 'rid': str(uuid.uuid4())})
        if r['status'] != 200:
            raise Falha(f'painel respondeu {r["status"]} ({tipo})')
        dados = json.loads(r['txt'])
        res = dados['results'][0]['result']
        if 'error' in json.dumps(res.get('data', {}).get('dsr', {}).get('DataShapes', []))[:2000].lower():
            raise Falha(f'painel recusou o pedido ({tipo})')
        return decodificar(dados)

    def _rapido(self, uf, municipio, cep):
        filtros = {'UF': uf, 'MUNICIPIO': municipio, 'CEP': cep}
        linhas = self._pedir('grade', filtros, janela=1000)
        pontos = []
        if 'mapa' in self.modelos:
            try:
                pontos = self._pedir('mapa', filtros, janela=3000)
            except Falha as f:
                log(f'mapa sem lat/long nesta consulta ({f})')
        particao = None
        try:
            d = self._pedir('data', {'UF': uf})
            particao = (d[0] if d else {}).get('Min(BASE_HP_F.dt_dfv_particao)')
        except Falha:
            pass
        return linhas, pontos, particao

    # ---------------- caminho lento: os filtros da tela (como o humano)
    def _slicer(self, titulo, valor):
        pg = self.page
        vc = pg.locator('visual-container').filter(
            has=pg.locator('.slicer-header-text', has_text=re.compile(rf'^\s*{re.escape(titulo)}\s*$'))).first
        vc.locator('.slicer-dropdown-menu').click()
        pop = pg.locator('.slicer-dropdown-popup:visible').last
        si = pop.locator('input.searchInput')
        si.click()
        si.press('Control+a')
        si.press('Backspace')
        si.press_sequentially(valor, delay=30)
        pg.wait_for_timeout(2000)
        itens = pop.locator('.slicerItemContainer').filter(has_text=re.compile(rf'^\s*{re.escape(valor)}\s*$'))
        if itens.count() == 0:
            pg.keyboard.press('Escape')
            return False
        itens.first.click()
        pg.wait_for_timeout(400)
        pg.keyboard.press('Escape')
        pg.wait_for_timeout(1500)
        return True

    def _tela(self, uf, municipio, cep):
        pg = self.page
        try:
            pg.get_by_text('Limpar Filtros', exact=True).click(timeout=5000)
            pg.wait_for_timeout(2500)
        except Exception:  # noqa: BLE001
            pass
        for tit, val in (('UF', uf), ('MUNICIPIO', municipio), ('CEP', cep)):
            if val and not self._slicer(tit, val):
                if tit == 'CEP':
                    return [], [], None
        pg.wait_for_timeout(2500)
        g = pg.evaluate("""() => {
          const v = [...document.querySelectorAll('visual-container')].find(v => /CD_LOGRADOURO/.test(v.innerText||''));
          if (!v) return null;
          const cab = [...v.querySelectorAll('[role=columnheader]')].map(e => e.innerText.trim());
          const linhas = [...v.querySelectorAll('[role=row]')].map(r => [...r.querySelectorAll('[role=gridcell]')]
            .map(c => c.innerText.trim())).filter(l => l.length);
          const at = (document.body.innerText.match(/ATUALIZADO\\s+(\\d{2}\\/\\d{2}\\/\\d{4})/) || [])[1] || null;
          return {cab, linhas, at};
        }""")
        if not g:
            raise Falha('grade não encontrada na tela')
        cab = [c for c in g['cab'] if c != 'Seleção de Linha']
        inv = {v: k for k, v in COLS.items()}
        linhas = []
        for l in g['linhas']:
            l = [x for x in l if x != 'Selecionar Linha']
            if not l or l[0] == 'Total':
                continue
            d = {}
            for i, c in enumerate(cab):
                if c in GRADE_TELA and i < len(l):
                    d[inv[GRADE_TELA[c]]] = l[i] or None
            linhas.append(d)
        particao = None
        if g.get('at'):
            dd, mm, aa = g['at'].split('/')
            particao = datetime.datetime(int(aa), int(mm), int(dd), tzinfo=datetime.timezone.utc).timestamp() * 1000
        return linhas, [], particao

    # ---------------- consulta
    def consultar(self, entrada):
        t0 = time.time()
        agora_s = time.time()
        self.chamadas = [c for c in self.chamadas if agora_s - c < 60]
        if len(self.chamadas) >= LIMITE_MIN:
            raise Falha('freio do operador: mais de 30 consultas/min')
        self.chamadas.append(agora_s)
        cep = so_digitos(entrada.get('cep'))
        if len(cep) != 8:
            raise Falha('CEP inválido')
        uf = (entrada.get('uf') or uf_do_cep(cep) or '').upper()
        municipio = (entrada.get('municipio') or '').strip().upper() or None
        entrada = {**entrada, 'cep': cep, 'uf': uf, 'municipio': municipio}
        chave = (uf, municipio, cep)
        hit = self.cache.get(chave)
        metodo = 'cache'
        if hit and time.time() - hit[0] < CACHE_S:
            _, linhas, pontos, particao = hit
        else:
            if not self.page or self.page.is_closed():
                self.login()
            try:
                linhas, pontos, particao = self._rapido(uf, municipio, cep)
                metodo = 'painel'
            except Exception as e:  # noqa: BLE001
                log(f'caminho rápido falhou ({type(e).__name__}: {str(e)[:120]}) — refazendo o login')
                try:
                    self.login()
                    linhas, pontos, particao = self._rapido(uf, municipio, cep)
                    metodo = 'painel'
                except Exception as e2:  # noqa: BLE001
                    log(f'caminho rápido falhou de novo ({type(e2).__name__}) — indo pela tela')
                    if getattr(self, 'leve', False):
                        self.login(leve=False)
                    linhas, pontos, particao = self._tela(uf, municipio, cep)
                    metodo = 'tela'
            self.cache[chave] = (time.time(), linhas, pontos, particao)
            if len(self.cache) > 500:
                self.cache.pop(next(iter(self.cache)))
        out = montar(entrada, linhas, pontos, particao, metodo, int((time.time() - t0) * 1000))
        self.estado['ultimo_uso'] = agora()
        self.estado['consultas'] += 1
        self.estado['atualizado_painel'] = out['atualizado_painel'] or self.estado['atualizado_painel']
        log(f'consulta {uf} {cep[:5]}*** → {out["match"]} ({out["total_fachadas_no_cep"]} fachadas, {metodo}, {out["ms"]} ms)')
        return out


OP = None


class Handler(BaseHTTPRequestHandler):
    server_version = 'niogen-dfv'

    def log_message(self, fmt, *args):  # o log padrão traz a query string (endereço)
        pass

    def _resp(self, code, obj):
        corpo = json.dumps(obj, ensure_ascii=False, default=str).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(corpo)))
        self.end_headers()
        self.wfile.write(corpo)

    def _autorizado(self):
        h = self.headers.get('Authorization') or ''
        dado = h[7:] if h.lower().startswith('bearer ') else ''
        return bool(TOKEN) and hmac.compare_digest(dado.encode(), TOKEN.encode())

    def _rota(self, metodo):
        u = urlparse(self.path)
        rota = '/' + u.path.strip('/').split('/')[-1] if u.path.strip('/') else '/'
        if not self._autorizado():
            self._resp(401, {'ok': False, 'erro': 'token inválido'})
            return
        try:
            if metodo == 'GET' and rota == '/saude':
                self._resp(200, {'ok': True, 'modelos': sorted(OP.modelos), **OP.estado})
            elif metodo == 'GET' and rota == '/dfv':
                q = {k: v[0] for k, v in parse_qs(u.query).items()}
                self._resp(200, {'ok': True, **OP.consultar(q)})
            elif metodo == 'POST' and rota == '/renovar':
                OP.login()
                self._resp(200, {'ok': True, 'modelos': sorted(OP.modelos), **OP.estado})
            else:
                self._resp(404, {'ok': False, 'erro': 'rota inexistente'})
        except Falha as f:
            OP.estado.update(ultimo_erro=str(f), ultimo_erro_em=agora())
            self._resp(422 if 'CEP' in str(f) else 502, {'ok': False, 'erro': str(f)})
            log(f'{metodo} {rota} → falha: {f}')
        except Exception as e:  # noqa: BLE001
            OP.estado.update(ultimo_erro=type(e).__name__, ultimo_erro_em=agora())
            self._resp(500, {'ok': False, 'erro': type(e).__name__})
            log(f'{metodo} {rota} → 500 ({type(e).__name__}: {str(e)[:160]})')

    def do_GET(self):
        self._rota('GET')

    def do_POST(self):
        self._rota('POST')


def main():
    global OP
    if len(TOKEN) < 24:
        raise SystemExit('DFV_OP_TOKEN ausente ou curto (mín. 24) — o operador não sobe sem ele.')
    OP = Operador()
    try:
        OP.login()
    except Exception as e:  # noqa: BLE001
        OP.estado.update(ultimo_erro=f'login: {type(e).__name__}', ultimo_erro_em=agora())
        log(f'login inicial falhou ({type(e).__name__}: {str(e)[:160]}) — tenta de novo na 1ª consulta')
    log(f'niogen-dfv ouvindo na porta {PORTA}')
    HTTPServer(('0.0.0.0', PORTA), Handler).serve_forever()


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'teste':
        # python operador.py teste 36010000 241 [complemento] — uma consulta sem servidor (para testar na máquina)
        OP = Operador()
        OP.login()
        print(json.dumps(OP.consultar({'cep': sys.argv[2], 'numero': sys.argv[3] if len(sys.argv) > 3 else '',
                                       'complemento': sys.argv[4] if len(sys.argv) > 4 else ''}),
                         ensure_ascii=False, indent=1)[:4000])
    else:
        main()
