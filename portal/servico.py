#!/usr/bin/env python3
# NIOGEN | portal/servico.py | 05/11/2026 — Claude Code (prompt nº 16, Plano B)
# 11/11/2026 — + OPERADOR DE CRÉDITO (docs/Prompt_operador_credito_consulta_111126_1650.md): ThreadingHTTPServer +
#              UMA thread do navegador com fila (o Playwright síncrono exige uma thread só) e as rotas /credito.
# "Operador" do portal PAP: mantém UM Chromium logado no portal (IP do Brasil) e executa, dentro da página, só as
# chamadas de viabilidade (nível A) que o n8n pedir, e as consultas de crédito (consulta-só, credito.py).
#
# Rotas (todas exigem o header X-Portal-Secret = NIO_PORTAL_SERVICO_SECRET; sem ele, 401):
#   GET  /saude                         → {ok, logado, plano, obtido_em, ultimo_uso, ultimo_erro, credito{...}} (fora da fila)
#   POST /renovar  {forcar?: bool}      → confere a sessão (GET permissoes); se caiu ou forcar, faz login de novo
#   POST /chamar   {metodo, caminho, corpo?} → chamada à API do portal pela página; 401 = renova UMA vez e repete
#   POST /credito  {cpf, endereco?, contato?, origem?} → 202 {job_id, posicao_fila, estado} (cache 24 h → 200 pronto)
#   GET  /credito/{job_id}              → {estado: fila|rodando|pronto|erro, etapa_atual, posicao_fila, ...resultado}
#   POST /credito/duplicidade {cpf}       → 202 {job_id, ...} — Etapas 0–3 com o endereço padrão; para na duplicidade de pedido
#                                         (12/11, Mari): pedido_em_andamento | sem_pedido_em_andamento. Sem contato, sem crédito.
#   POST /credito/viabilidade {endereco} → 202 {job_id, ...} — SÓ Etapas 0–2, sem CPF/contato (11/11 ~21h, consulta
#                                         unificada). Resultado viavel | sem_viabilidade | complemento_fora_lista | ...
#                                         Cache 6 h por endereço; limite VIAB_LIMITE_HORA (60). Mesma fila do navegador.
#   POST /os {cpf, os, criada_em?}      → 202 {job_id, ...} — OPERADOR DE OS (13/11, etapa 3): lê o andamento da OS na
#                                         Consulta OS (consulta_os.py: só "Filtros" e "Filtrar"; rede em lista branca).
#                                         Resultado lida {leitura} | nao_encontrada | erro. Crédito e viabilidade primeiro:
#                                         com qualquer job na fila ou rodando, responde 429 e a rotina tenta na próxima volta.
#                                         Cache 10 min por OS; limite OS_LIMITE_HORA (padrão 90).
#   GET  /os/{job_id}                   → igual a GET /credito/{job_id}
#   POST /credito/os {cpf, os, criada_em?} → o MESMO /os, no caminho que o proxy da tela já repassa (/credito/*). É por aqui
#                                         que a edge function credito-consulta pede a leitura de UMA OS ("Consultar OS agora",
#                                         13/11); o status sai por GET /credito/{job_id}. A rotina do n8n segue no /os.
#
# Limites: até 40 chamadas/min no /chamar; crédito: fila máx. 3, CREDITO_LIMITE_HORA / CREDITO_LIMITE_DIA (429), mesmo
# CPF < 24 h = resultado da memória (sem abrir o portal, sem Serasa repetido). Log sem corpo e sem CPF.
#
# Rodar fora do Docker (fase 0, PC com IP do Brasil): NIO_PORTAL_ENV=C:\caminho\.env  NIO_PORTAL_CANAL=chrome
# python servico.py   (o .env fica FORA do repo; NIO_PORTAL_HEADLESS=0 mostra a janela)

import base64
import datetime
import hmac
import hashlib
import json
import os
import queue
import re
import threading
import time
import uuid
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def _carregar_env():
    caminho = os.environ.get('NIO_PORTAL_ENV')
    if not caminho or not os.path.isfile(caminho):
        return
    with open(caminho, encoding='utf-8') as f:
        for linha in f:
            linha = linha.strip()
            if not linha or linha.startswith('#') or '=' not in linha:
                continue
            k, v = linha.split('=', 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


_carregar_env()

import consulta_os as co  # noqa: E402
import credito as cr  # noqa: E402
import portal_login as pl  # noqa: E402

PORTA = int(os.environ.get('NIO_PORTAL_PORTA', '8090'))
SEGREDO = (os.environ.get('NIO_PORTAL_SERVICO_SECRET') or '').strip()
LIMITE_MIN = 40
FILA_MAX = 3
JOB_TTL = 30 * 60
CACHE_TTL = 24 * 3600
# Só veredito de crédito entra no cache de 24 h. Erro, erro da Receita, sem viabilidade e não classificado podem
# ser refeitos (ex.: "Consultar com o endereço padrão" depois de um endereço do cliente sem viabilidade).
VIAB_TTL = 6 * 3600       # viabilidade do portal vale "hoje": 6 h por endereço
VIAB_CACHEAVEIS = {'viavel', 'sem_viabilidade', 'complemento_fora_lista'}
CACHEAVEIS = {'aprovado_todas', 'aprovado_cartao', 'aprovado_parcial', 'pendente', 'negado', 'pedido_em_andamento'}
DUP_CACHEAVEIS = {'pedido_em_andamento', 'sem_pedido_em_andamento'}   # 12/11: modo duplicidade (Mari), 24 h por CPF
OS_TTL = 10 * 60          # 13/11: a mesma OS não é lida de novo no portal em menos de 10 min


def chave_viab(endereco, sal):
    """Chave do cache de viabilidade: CEP · número · complemento · opção, sem caixa e espaços repetidos (com letras)."""
    norm = lambda t: ' '.join(str(t or '').lower().split())   # noqa: E731
    base = '|'.join(norm(endereco.get(k)) for k in ('cep', 'numero', 'complemento', 'opcao'))
    return hashlib.sha256((str(sal or '') + '|' + base).encode()).hexdigest()


def agora():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def agora_br():
    return datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=-3))).isoformat(timespec='seconds')


def cfg_credito():
    e = os.environ.get
    return {
        'matricula': (e('CREDITO_MATRICULA') or 'TT837725').strip(),
        'end_cep': cr.so_digitos(e('CREDITO_END_CEP') or ''),
        'end_numero': (e('CREDITO_END_NUMERO') or '').strip(),
        'end_referencia': (e('CREDITO_END_REFERENCIA') or '').strip(),
        'contato_celular': cr.so_digitos(e('CREDITO_CONTATO_CELULAR') or ''),
        'contato_email': (e('CREDITO_CONTATO_EMAIL') or '').strip(),
        'limite_hora': int(e('CREDITO_LIMITE_HORA') or 20),
        'limite_dia': int(e('CREDITO_LIMITE_DIA') or 60),
        'sal': e('CREDITO_SAL') or SEGREDO,
        'amostras': e('CREDITO_AMOSTRAS_DIR') or '/amostras',
        'viab_limite_hora': int(e('VIAB_LIMITE_HORA') or 60),
        'dup_limite_hora': int(e('DUP_LIMITE_HORA') or 20),
        'os_limite_hora': int(e('OS_LIMITE_HORA') or 90),   # rotina + varredura pedida + consulta de uma OS pela ficha
    }


class Operador:
    """Vive SÓ na thread do navegador."""

    def __init__(self):
        from playwright.sync_api import sync_playwright
        self.pw = sync_playwright().start()
        self.nav = None
        self.ctx = None
        self.page = None
        self.estado = {'logado': False, 'plano': None, 'obtido_em': None, 'ultimo_uso': None, 'ultimo_erro': None,
                       'ultimo_erro_em': None, 'meta': {}}
        self.chamadas = deque()

    def _abrir(self):
        if self.nav is None or not self.nav.is_connected():
            canal = (os.environ.get('NIO_PORTAL_CANAL') or '').strip() or None      # 'chrome' = Chrome do sistema
            headless = os.environ.get('NIO_PORTAL_HEADLESS', '1') != '0'
            self.nav = self.pw.chromium.launch(headless=headless, channel=canal,
                                               args=['--no-sandbox', '--disable-dev-shm-usage'])
        if self.ctx is not None:
            try:
                self.ctx.close()
            except Exception:  # noqa: BLE001
                pass
        self.ctx = pl.novo_contexto(self.nav)
        self.page = None

    def login(self):
        self._abrir()
        try:
            self.page, info = pl.entrar(self.ctx, exigir_front=True)
        except pl.Falha as f:
            self.estado.update(logado=False, ultimo_erro=f'{f.codigo}: {f}', ultimo_erro_em=agora())
            raise
        self.estado.update(logado=True, plano=info.get('plano'), obtido_em=agora(), meta={
            k: info.get(k) for k in ('usuario_formato', 'kmsi', 'plano', 'segundos')})
        pl.log(f'login ok ({info.get("segundos")} s, plano {info.get("plano")})')
        return info

    def sessao_viva(self):
        if not self.page or self.page.is_closed():
            return False
        try:
            r = pl.chamar(self.page, 'GET', 'api/portal/permissoes')
            return r.get('status') == 200
        except Exception:  # noqa: BLE001
            return False

    def renovar(self, forcar=False):
        if not forcar and self.sessao_viva():
            return {'ok': True, 'renovado': False}
        self.login()
        return {'ok': True, 'renovado': True}

    def chamar(self, metodo, caminho, corpo=None):
        t = time.time()
        while self.chamadas and t - self.chamadas[0] > 60:
            self.chamadas.popleft()
        if len(self.chamadas) >= LIMITE_MIN:
            raise pl.Falha(429, 'freio do serviço: mais de 40 chamadas/min')
        self.chamadas.append(t)
        renovou = False
        if not self.page or self.page.is_closed():
            self.login()
            renovou = True
        r = pl.chamar(self.page, metodo, caminho, corpo)
        if r.get('status') == 401 or r.get('erro') == 'sem_gancho':
            if renovou:
                raise pl.Falha(8, 'portal recusou a sessão logo após o login')
            self.login()
            renovou = True
            r = pl.chamar(self.page, metodo, caminho, corpo)
        self.estado['ultimo_uso'] = agora()
        r['renovou'] = renovou
        return r

    def consultar_credito(self, params, cfg, progresso):
        """Uma consulta numa página nova do mesmo contexto (herda o login). Sessão caída → login 1× e recomeça."""
        if self.ctx is None or not self.estado.get('logado'):
            self.login()
        for tentativa in (1, 2):
            c = cr.Consulta(self.ctx, params, cfg, progresso=progresso, log=pl.log)
            try:
                out = c.rodar()
                self.estado['ultimo_uso'] = agora()
                return out, getattr(c, 'amostras_corpos', []), getattr(c, 'print_jpeg', None)
            except cr.SessaoCaida:
                if tentativa == 2:
                    raise pl.Falha(8, 'portal pediu login de novo logo após o login')
                pl.log('crédito: sessão caída — login e recomeço do job')
                self.login()
        raise pl.Falha(8, 'inalcançável')

    def consultar_os(self, params):
        """Uma leitura da Consulta OS numa página nova do mesmo contexto. Sessão caída → login 1× e recomeça."""
        if self.ctx is None or not self.estado.get('logado'):
            self.login()
        for tentativa in (1, 2):
            c = co.ConsultaOS(self.ctx, params, log=pl.log)
            try:
                out = c.rodar()
                # 13/11: a tela não carregou (visto às 11h30, sem a página pedir para sair). Antes de desistir, confere a
                # sessão — caiu: entra de novo — e tenta UMA vez mais. Nenhuma pesquisa foi feita no portal nessa falha.
                if tentativa == 1 and out.get('resultado') == 'erro' and 'não carregou' in str(out.get('motivo') or ''):
                    pl.log('os: a tela não carregou — conferindo a sessão e tentando de novo')
                    if not self.sessao_viva():
                        self.login()
                    continue
                self.estado['ultimo_uso'] = agora()
                return out
            except cr.SessaoCaida:
                if tentativa == 2:
                    raise pl.Falha(8, 'portal pediu login de novo logo após o login')
                pl.log('os: sessão caída — login e recomeço da leitura')
                self.login()
        raise pl.Falha(8, 'inalcançável')


# ------------------------------------------------------------------------------------------- thread do navegador
FILA = queue.Queue()
OP = None
OP_PRONTO = threading.Event()


class Tarefa:
    def __init__(self, fn):
        self.fn = fn
        self.feito = threading.Event()
        self.resultado = None
        self.erro = None


def no_navegador(fn, timeout=180):
    """Executa fn(OP) na thread do navegador e espera o resultado (para /chamar e /renovar)."""
    t = Tarefa(fn)
    FILA.put(t)
    if not t.feito.wait(timeout):
        raise pl.Falha(5, 'o navegador não respondeu a tempo (fila ocupada)')
    if t.erro:
        raise t.erro
    return t.resultado


def thread_navegador():
    global OP
    OP = Operador()
    try:
        OP.login()
    except pl.Falha as f:
        pl.log(f'login inicial falhou ({f.codigo}: {f}) — o serviço segue e tenta de novo no próximo pedido')
    OP_PRONTO.set()
    while True:
        t = FILA.get()
        try:
            t.resultado = t.fn(OP)
        except Exception as e:  # noqa: BLE001
            t.erro = e
        finally:
            t.feito.set()


# ------------------------------------------------------------------------------------------- jobs de crédito
JOBS = {}
TRAVA_JOBS = threading.Lock()
INICIOS = deque()          # horários de consultas que abriram o portal (freio hora/dia)
VIAB_INICIOS = deque()     # idem, só viabilidade (não passa pela Receita/Serasa)
DUP_INICIOS = deque()      # idem, só duplicidade de pedido (Etapas 0–3, Receita sim, Serasa não)
OS_INICIOS = deque()       # idem, só leitura da Consulta OS (13/11)
CACHE = {}                 # chave sha256(sal+cpf) → (time, resultado). Só memória: nada vai a disco.


def _limpar_jobs():
    t = time.time()
    for k in [k for k, j in JOBS.items() if t - j['criado'] > JOB_TTL and j['estado'] in ('pronto', 'erro')]:
        JOBS.pop(k, None)
    for k in [k for k, (ts, _) in CACHE.items()
              if t - ts > (VIAB_TTL if k.startswith('v:') else OS_TTL if k.startswith('o:') else CACHE_TTL)]:
        CACHE.pop(k, None)
    while VIAB_INICIOS and t - VIAB_INICIOS[0] > 3600:
        VIAB_INICIOS.popleft()
    while INICIOS and t - INICIOS[0] > 86400:
        INICIOS.popleft()


def _posicao(job_id):
    fila = sorted((j for j in JOBS.values() if j['estado'] == 'fila'), key=lambda j: j['criado'])
    for i, j in enumerate(fila, 1):
        if j['id'] == job_id:
            return i
    return 0


def _publico(j):
    base = {'ok': True, 'job_id': j['id'], 'estado': j['estado'], 'etapa_atual': j.get('etapa_atual'),
            'etapa_nome': j.get('etapa_nome'), 'posicao_fila': _posicao(j['id']) if j['estado'] == 'fila' else 0,
            'cpf_mascara': j['cpf_mascara'], 'origem': j.get('origem'), 'modo': j.get('modo') or 'credito'}
    if j.get('resultado'):
        base.update(j['resultado'])
    return base


def log_credito(job_id, origem, resultado, ms, etapa, cache=False, extra=''):
    """Linha sem CPF/nome/contato: job · origem · resultado · ms · etapa. Também em credito_log.jsonl (métrica de 7 d)."""
    pl.log(f'credito {job_id[:8]} · {origem} · {resultado} · {ms} ms · etapa {etapa}{" · cache" if cache else ""}'
           f'{" · " + extra if extra else ""}')
    pasta = cfg_credito()['amostras']
    try:
        if pasta and os.path.isdir(pasta):
            with open(os.path.join(pasta, 'credito_log.jsonl'), 'a', encoding='utf-8') as f:
                f.write(json.dumps({'em': agora_br(), 'job': job_id[:8], 'origem': origem, 'resultado': resultado,
                                    'ms': ms, 'etapa': etapa, 'cache': cache}) + '\n')
    except OSError:
        pass


def _arquivo_print(pasta, job_id):
    jid = re.sub(r'[^0-9a-f]', '', str(job_id or ''))[:32]
    return os.path.join(pasta, 'prints', f'{jid}.jpg') if len(jid) == 32 and pasta else None


def gravar_print(pasta, job_id, jpeg):
    """Print da tela do portal (só viabilidade, sem CPF). Fica na VPS, em amostras/prints (chmod 700), 7 dias."""
    arq = _arquivo_print(pasta, job_id)
    if not arq:
        return False
    try:
        os.makedirs(os.path.dirname(arq), exist_ok=True)
        os.chmod(os.path.dirname(arq), 0o700)
        with open(arq, 'wb') as f:
            f.write(jpeg)
        return True
    except OSError:
        return False


def _rodar_job(job_id, params, cfg):
    def tarefa(op):
        j = JOBS[job_id]
        j['estado'] = 'rodando'
        cr.limpar_amostras(cfg['amostras'])

        def progresso(**k):
            j.update(k)
        jpeg = None
        try:
            out, corpos, jpeg = op.consultar_credito(params, cfg, progresso)
        except pl.Falha as f:
            out, corpos = {'resultado': 'erro', 'motivo': cr.sem_pii(f), 'ms': 0,
                           'etapa_parada': j.get('etapa_atual')}, []
        except Exception as e:  # noqa: BLE001
            out, corpos = {'resultado': 'erro', 'motivo': f'{type(e).__name__}: {cr.sem_pii(e)}', 'ms': 0,
                           'etapa_parada': j.get('etapa_atual')}, []
        out.update(consultado_em=agora_br(), cache=False)
        if jpeg and params.get('modo') == 'viabilidade' and gravar_print(cfg['amostras'], job_id, jpeg):
            out['print_job'] = job_id      # o cache leva junto: quem pegar o resultado do cache vê o mesmo print
        j['resultado'] = out
        j['estado'] = 'erro' if out['resultado'] == 'erro' else 'pronto'
        modo = params.get('modo') or 'credito'
        viab = modo == 'viabilidade'
        cacheaveis = VIAB_CACHEAVEIS if viab else DUP_CACHEAVEIS if modo == 'duplicidade' else CACHEAVEIS
        if out['resultado'] in cacheaveis:
            CACHE[params['chave']] = (time.time(), out)
        cr.gravar_amostra(cfg['amostras'], job_id, out, corpos)
        log_credito(job_id, modo if modo != 'credito' else params['origem_endereco'], out['resultado'], out.get('ms'), out.get('etapa_parada'),
                    extra=(out.get('motivo') or '')[:120] if out['resultado'] in ('erro', 'nao_classificado') else '')
        return None
    FILA.put(Tarefa(tarefa))


def novo_job_credito(b):
    cfg = cfg_credito()
    cpf = cr.so_digitos(b.get('cpf'))
    if not cr.cpf_valido(cpf):
        raise pl.Falha(400, 'CPF inválido')
    chave = cr.cpf_chave(cpf, cfg['sal'])
    end_in = b.get('endereco') or None
    if end_in and cr.so_digitos(end_in.get('cep')):
        if len(cr.so_digitos(end_in.get('cep'))) != 8:
            raise pl.Falha(400, 'CEP do cliente inválido')
        endereco = {'cep': cr.so_digitos(end_in.get('cep')), 'numero': str(end_in.get('numero') or '').strip()[:20],
                    'complemento': str(end_in.get('complemento') or '').strip()[:60],
                    'referencia': str(end_in.get('referencia') or '').strip()[:80] or 'Sem referência',
                    'opcao': str(end_in.get('opcao') or '').strip()[:200]}
        origem_end = 'cliente'
    else:
        if len(cfg['end_cep']) != 8:
            raise pl.Falha(503, 'endereço padrão não configurado (CREDITO_END_CEP)')
        endereco = {'cep': cfg['end_cep'], 'numero': cfg['end_numero'], 'complemento': '',
                    'referencia': cfg['end_referencia'] or 'Centro'}
        origem_end = 'padrao'
    c_in = b.get('contato') or None
    if c_in and (cr.so_digitos(c_in.get('celular')) or c_in.get('email')):
        cel = cr.so_digitos(c_in.get('celular'))
        email = str(c_in.get('email') or '').strip()
        if len(cel) not in (10, 11) or '@' not in email:
            raise pl.Falha(400, 'contato do cliente precisa de celular com DDD e e-mail')
        contato = {'celular': cel, 'email': email}
    else:
        if not cfg['contato_celular'] or '@' not in cfg['contato_email']:
            raise pl.Falha(503, 'contato padrão não configurado (CREDITO_CONTATO_*)')
        contato = {'celular': cfg['contato_celular'], 'email': cfg['contato_email']}

    with TRAVA_JOBS:
        _limpar_jobs()
        job_id = uuid.uuid4().hex
        base = {'id': job_id, 'criado': time.time(), 'cpf_mascara': cr.cpf_mascara(cpf),
                'origem': str(b.get('origem') or '')[:40] or None}
        hit = CACHE.get(chave)
        if hit and time.time() - hit[0] < CACHE_TTL:
            res = dict(hit[1], cache=True)
            JOBS[job_id] = {**base, 'estado': 'pronto', 'resultado': res, 'etapa_atual': res.get('etapa_parada')}
            log_credito(job_id, origem_end, res['resultado'], 0, res.get('etapa_parada'), cache=True)
            return 200, _publico(JOBS[job_id])
        if sum(1 for j in JOBS.values() if j['estado'] == 'fila' and j.get('modo') != 'os') >= FILA_MAX:
            raise pl.Falha(429, f'fila cheia ({FILA_MAX}) — tente em alguns minutos')
        t = time.time()
        if sum(1 for x in INICIOS if t - x < 3600) >= cfg['limite_hora']:
            raise pl.Falha(429, f'limite de {cfg["limite_hora"]} consultas por hora')
        if len(INICIOS) >= cfg['limite_dia']:
            raise pl.Falha(429, f'limite de {cfg["limite_dia"]} consultas por dia')
        INICIOS.append(t)
        JOBS[job_id] = {**base, 'estado': 'fila', 'etapa_atual': 0}
        params = {'cpf': cpf, 'endereco': endereco, 'contato': contato, 'origem_endereco': origem_end, 'chave': chave}
        _rodar_job(job_id, params, cfg)
        return 202, _publico(JOBS[job_id])


def novo_job_duplicidade(b):
    """12/11 (Mari): só a duplicidade de pedido — Etapas 0–3 com o ENDEREÇO PADRÃO e o CPF; para antes do contato e do crédito
    (sem Serasa). Resultado pedido_em_andamento | sem_pedido_em_andamento | erro_receita | nao_classificado | erro.
    Cache 24 h por CPF (hash com sal); teto próprio DUP_LIMITE_HORA (padrão 20) e a mesma fila do navegador."""
    cfg = cfg_credito()
    cpf = cr.so_digitos(b.get('cpf'))
    if not cr.cpf_valido(cpf):
        raise pl.Falha(400, 'CPF inválido')
    if len(cfg['end_cep']) != 8:
        raise pl.Falha(503, 'endereço padrão não configurado (CREDITO_END_CEP)')
    endereco = {'cep': cfg['end_cep'], 'numero': cfg['end_numero'], 'complemento': '',
                'referencia': cfg['end_referencia'] or 'Centro'}
    chave = 'd:' + cr.cpf_chave(cpf, cfg['sal'])
    with TRAVA_JOBS:
        _limpar_jobs()
        job_id = uuid.uuid4().hex
        base = {'id': job_id, 'criado': time.time(), 'cpf_mascara': cr.cpf_mascara(cpf), 'modo': 'duplicidade',
                'origem': str(b.get('origem') or '')[:40] or None}
        hit = CACHE.get(chave)
        if hit and time.time() - hit[0] < CACHE_TTL:
            res = dict(hit[1], cache=True)
            JOBS[job_id] = {**base, 'estado': 'pronto', 'resultado': res, 'etapa_atual': res.get('etapa_parada')}
            log_credito(job_id, 'duplicidade', res['resultado'], 0, res.get('etapa_parada'), cache=True)
            return 200, _publico(JOBS[job_id])
        if sum(1 for j in JOBS.values() if j['estado'] == 'fila' and j.get('modo') != 'os') >= FILA_MAX:
            raise pl.Falha(429, f'fila cheia ({FILA_MAX}) — tente em alguns minutos')
        t = time.time()
        while DUP_INICIOS and t - DUP_INICIOS[0] > 3600:
            DUP_INICIOS.popleft()
        if len(DUP_INICIOS) >= cfg['dup_limite_hora']:
            raise pl.Falha(429, f'limite de {cfg["dup_limite_hora"]} consultas de duplicidade por hora')
        DUP_INICIOS.append(t)
        JOBS[job_id] = {**base, 'estado': 'fila', 'etapa_atual': 0}
        params = {'cpf': cpf, 'endereco': endereco, 'contato': None, 'origem_endereco': 'padrao',
                  'modo': 'duplicidade', 'chave': chave}
        _rodar_job(job_id, params, cfg)
        return 202, _publico(JOBS[job_id])


def novo_job_viabilidade(b):
    """Só viabilidade (Etapas 0–2): sem CPF, sem contato, sem Receita. Endereço do cliente obrigatório."""
    cfg = cfg_credito()
    e = b.get('endereco') or {}
    cep = cr.so_digitos(e.get('cep'))
    if len(cep) != 8:
        raise pl.Falha(400, 'CEP com 8 dígitos')
    endereco = {'cep': cep, 'numero': str(e.get('numero') or '').strip()[:20],
                'complemento': str(e.get('complemento') or '').strip()[:60],
                'referencia': str(e.get('referencia') or '').strip()[:80] or 'Sem referência',
                'opcao': str(e.get('opcao') or '').strip()[:200]}
    # 12/11 00h10: a chave guarda o TEXTO do complemento. Antes passava por cpf_chave (só dígitos) e "Casa A" virava "" —
    # caía no cache da consulta sem complemento e voltava "escolha a unidade" mesmo depois de tocar na unidade.
    chave = 'v:' + chave_viab(endereco, cfg['sal'])
    with TRAVA_JOBS:
        _limpar_jobs()
        job_id = uuid.uuid4().hex
        base = {'id': job_id, 'criado': time.time(), 'cpf_mascara': None, 'modo': 'viabilidade',
                'origem': str(b.get('origem') or '')[:40] or None}
        hit = CACHE.get(chave)
        if hit and time.time() - hit[0] < VIAB_TTL:
            res = dict(hit[1], cache=True)
            JOBS[job_id] = {**base, 'estado': 'pronto', 'resultado': res, 'etapa_atual': res.get('etapa_parada')}
            log_credito(job_id, 'viabilidade', res['resultado'], 0, res.get('etapa_parada'), cache=True)
            return 200, _publico(JOBS[job_id])
        if sum(1 for j in JOBS.values() if j['estado'] == 'fila' and j.get('modo') != 'os') >= FILA_MAX:
            raise pl.Falha(429, f'fila cheia ({FILA_MAX}) — tente em alguns minutos')
        if len(VIAB_INICIOS) >= cfg['viab_limite_hora']:
            raise pl.Falha(429, f'limite de {cfg["viab_limite_hora"]} viabilidades por hora')
        VIAB_INICIOS.append(time.time())
        JOBS[job_id] = {**base, 'estado': 'fila', 'etapa_atual': 0}
        params = {'cpf': None, 'endereco': endereco, 'contato': None, 'origem_endereco': 'cliente',
                  'modo': 'viabilidade', 'chave': chave}
        _rodar_job(job_id, params, cfg)
        return 202, _publico(JOBS[job_id])


def novo_job_os(b):
    """13/11 (etapa 3): leitura de acompanhamento da OS. Crédito, duplicidade e viabilidade têm prioridade: se o navegador
    está ocupado ou há alguém na fila, não entra (429) — a rotina tenta de novo na próxima volta."""
    cfg = cfg_credito()
    doc = cr.so_digitos(b.get('cpf'))
    if not (cr.cpf_valido(doc) or len(doc) == 14):
        raise pl.Falha(400, 'CPF/CNPJ inválido')
    num = cr.so_digitos(b.get('os'))
    if len(num) != 8:
        raise pl.Falha(400, 'número da OS com 8 dígitos')
    chave = 'o:' + hashlib.sha256((str(cfg['sal']) + '|' + num).encode()).hexdigest()
    with TRAVA_JOBS:
        _limpar_jobs()
        job_id = uuid.uuid4().hex
        base = {'id': job_id, 'criado': time.time(), 'cpf_mascara': None, 'modo': 'os',
                'origem': str(b.get('origem') or '')[:40] or None}
        hit = CACHE.get(chave)
        if hit and time.time() - hit[0] < OS_TTL:
            JOBS[job_id] = {**base, 'estado': 'pronto', 'resultado': dict(hit[1], cache=True)}
            return 200, _publico(JOBS[job_id])
        if any(j['estado'] in ('fila', 'rodando') for j in JOBS.values()):
            raise pl.Falha(429, 'operador ocupado (crédito e viabilidade primeiro) — tente na próxima volta')
        t = time.time()
        while OS_INICIOS and t - OS_INICIOS[0] > 3600:
            OS_INICIOS.popleft()
        if len(OS_INICIOS) >= cfg['os_limite_hora']:
            raise pl.Falha(429, f'limite de {cfg["os_limite_hora"]} leituras de OS por hora')
        OS_INICIOS.append(t)
        JOBS[job_id] = {**base, 'estado': 'fila'}
        params = {'cpf': doc, 'os': num, 'criada_em': str(b.get('criada_em') or '')[:10]}

    def tarefa(op):
        j = JOBS[job_id]
        j['estado'] = 'rodando'
        try:
            out = op.consultar_os(params)
        except pl.Falha as f:
            out = {'resultado': 'erro', 'motivo': cr.sem_pii(f), 'ms': 0}
        except cr.TravaAcionada as e:
            out = {'resultado': 'erro', 'motivo': str(e)[:200], 'trava': True, 'ms': 0}
        except Exception as e:  # noqa: BLE001
            out = {'resultado': 'erro', 'motivo': f'{type(e).__name__}: {cr.sem_pii(e)}'[:900], 'ms': 0}
        out.update(consultado_em=agora_br(), cache=False)
        j['resultado'] = out
        j['estado'] = 'erro' if out['resultado'] == 'erro' else 'pronto'
        if out['resultado'] == 'lida':
            CACHE[chave] = (time.time(), out)
        # Log sem CPF e sem número da OS: só o resultado e o tempo.
        log_credito(job_id, 'os', out['resultado'], out.get('ms'), None,
                    extra=(out.get('motivo') or '')[:120] if out['resultado'] == 'erro' else '')
        return None
    FILA.put(Tarefa(tarefa))
    return 202, _publico(JOBS[job_id])


# ------------------------------------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = 'niogen-portal'

    def log_message(self, fmt, *args):  # silencia o log padrão (tem query string)
        pass

    def _resp(self, code, obj):
        corpo = json.dumps(obj, ensure_ascii=False, default=str).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(corpo)))
        self.end_headers()
        self.wfile.write(corpo)

    def _autorizado(self):
        dado = self.headers.get('X-Portal-Secret') or ''
        return bool(SEGREDO) and hmac.compare_digest(dado.encode(), SEGREDO.encode())

    def _json(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n > 20000:
            raise pl.Falha(9, 'corpo grande demais')
        if not n:
            return {}
        bruto = self.rfile.read(n) or b'{}'
        try:
            return json.loads(bruto.decode('utf-8'))
        except UnicodeDecodeError:          # curl no terminal do Windows manda cp1252 (visto em 11/11)
            return json.loads(bruto.decode('cp1252'))

    def _rota(self, metodo):
        t0 = time.time()
        rota = self.path.split('?')[0].rstrip('/') or '/'
        rota_log = ('/credito/print/<job>' if rota.startswith('/credito/print/') else '/credito/<job>' if rota.startswith('/credito/')
                    else '/os/<job>' if rota.startswith('/os/') else rota)
        if not self._autorizado():
            self._resp(401, {'ok': False, 'erro': 'segredo inválido'})
            pl.log(f'{metodo} {rota_log} → 401 (segredo)')
            return
        estado = OP.estado if OP else {'logado': False}
        try:
            if metodo == 'GET' and rota == '/saude':
                with TRAVA_JOBS:
                    _limpar_jobs()
                    cred = {'fila': sum(1 for j in JOBS.values() if j['estado'] == 'fila'),
                            'rodando': sum(1 for j in JOBS.values() if j['estado'] == 'rodando'),
                            'ultima_hora': sum(1 for x in INICIOS if time.time() - x < 3600),
                            'ultimas_24h': len(INICIOS)}
                self._resp(200, {'ok': True, **estado, 'credito': cred})
            elif metodo == 'POST' and rota == '/renovar':
                b = self._json()
                r = no_navegador(lambda op: op.renovar(bool(b.get('forcar'))))
                self._resp(200, {**r, **OP.estado})
            elif metodo == 'POST' and rota == '/chamar':
                b = self._json()
                r = no_navegador(lambda op: op.chamar(b.get('metodo', 'GET'), str(b.get('caminho') or ''),
                                                      b.get('corpo')))
                self._resp(200, {'ok': True, **r})
                pl.log(f'chamar {str(b.get("metodo", "GET")).upper()} {str(b.get("caminho") or "").split("?")[0][:60]}'
                       f' → {r.get("status")} ({time.time() - t0:.1f} s{", renovou" if r.get("renovou") else ""})')
                return
            elif metodo == 'POST' and rota == '/credito/duplicidade':
                code, r = novo_job_duplicidade(self._json())
                self._resp(code, r)
                return
            elif metodo == 'POST' and rota == '/credito/viabilidade':
                code, r = novo_job_viabilidade(self._json())
                self._resp(code, r)
                return
            elif metodo == 'POST' and rota == '/credito':
                code, r = novo_job_credito(self._json())
                self._resp(code, r)
                return
            elif metodo == 'POST' and rota in ('/os', '/credito/os'):
                code, r = novo_job_os(self._json())
                self._resp(code, r)
                return
            elif metodo == 'GET' and rota.startswith('/os/'):
                jid = rota.split('/os/', 1)[1][:64]
                with TRAVA_JOBS:
                    j = JOBS.get(jid)
                    r = _publico(j) if j and j.get('modo') == 'os' else None
                if not r:
                    self._resp(404, {'ok': False, 'erro': 'job inexistente ou expirado (30 min)'})
                else:
                    self._resp(200, r)
                return
            elif metodo == 'GET' and rota.startswith('/credito/print/'):
                arq = _arquivo_print(cfg_credito()['amostras'], rota.split('/credito/print/', 1)[1])
                if not arq or not os.path.isfile(arq):
                    self._resp(404, {'ok': False, 'erro': 'print inexistente ou expirado (7 dias)'})
                else:
                    with open(arq, 'rb') as f:
                        self._resp(200, {'ok': True, 'tipo': 'image/jpeg', 'base64': base64.b64encode(f.read()).decode(),
                                         'em': datetime.datetime.fromtimestamp(os.path.getmtime(arq)).strftime('%d/%m %H:%M')})
                return
            elif metodo == 'GET' and rota.startswith('/credito/'):
                jid = rota.split('/credito/', 1)[1][:64]
                with TRAVA_JOBS:
                    j = JOBS.get(jid)
                    r = _publico(j) if j else None
                if not r:
                    self._resp(404, {'ok': False, 'erro': 'job inexistente ou expirado (30 min)'})
                else:
                    self._resp(200, r)
                return
            else:
                self._resp(404, {'ok': False, 'erro': 'rota inexistente'})
        except pl.Falha as f:
            code = {429: 429, 9: 403, 400: 400, 503: 503}.get(f.codigo, 502)
            self._resp(code, {'ok': False, 'codigo': f.codigo, 'erro': str(f), **(OP.estado if OP else {})})
            pl.log(f'{metodo} {rota_log} → {code} ({f.codigo}: {cr.sem_pii(f)})')
            return
        except Exception as e:  # noqa: BLE001
            self._resp(500, {'ok': False, 'erro': type(e).__name__})
            pl.log(f'{metodo} {rota_log} → 500 ({type(e).__name__})')
            return
        pl.log(f'{metodo} {rota_log} ({time.time() - t0:.1f} s)')

    def do_GET(self):
        self._rota('GET')

    def do_POST(self):
        self._rota('POST')


def main():
    if len(SEGREDO) < 24:
        raise SystemExit('NIO_PORTAL_SERVICO_SECRET ausente ou curto (mín. 24) — serviço não sobe sem ele.')
    pl.credenciais()  # falha cedo se faltar usuário/senha
    pasta = cfg_credito()['amostras']
    try:
        os.makedirs(pasta, exist_ok=True)
        os.chmod(pasta, 0o700)
    except OSError:
        pass
    n = cr.limpar_amostras(pasta)
    if n:
        pl.log(f'amostras: {n} com mais de 7 dias apagadas')
    threading.Thread(target=thread_navegador, name='navegador', daemon=True).start()
    OP_PRONTO.wait(120)
    pl.log(f'niogen-portal ouvindo na porta {PORTA}')
    ThreadingHTTPServer(('0.0.0.0', PORTA), Handler).serve_forever()


if __name__ == '__main__':
    main()
