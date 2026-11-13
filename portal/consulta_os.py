#!/usr/bin/env python3
# NIOGEN | portal/consulta_os.py | 13/11/2026 — Claude Code (docs/Prompt_operador_os_etapa3_131126_0300.md, etapas 3b e 3d)
# OPERADOR DE OS — leitura de acompanhamento na Consulta OS do portal PAP (regra 5 do CLAUDE.md, linha de 13/11/2026).
# Levantamento: docs/LEVANTAMENTO_consulta_os_131126_0955.md (Drive).
#
# O que o robô faz: abre /administrativo/consulta-os, abre "Filtros", preenche CPF/CNPJ e Número OS da VENDA REGISTRADA,
# clica "Filtrar" e lê a resposta da própria página (GET consultastatusos). Só isso.
#
# TRAVAS (testadas em portal/testar_travas.py, seção 6 — vermelho no teste: não roda):
#   • Clique: LISTA BRANCA. Só "Filtros" e "Filtrar". Qualquer outro texto levanta TravaAcionada ANTES do clique
#     (Detalhar, Atualizar o status da OS, Enviar/Reenviar link de pagamento, Agendar instalação, reagendar, cancelar…).
#   • Rede: LISTA BRANCA na API do portal. Passa só a leitura consultastatusos (GET) e as chamadas de sessão que toda
#     página do portal faz ao abrir. Qualquer outra chamada à API — e todo método que não seja GET — é abortada.
#   • Dado pessoal: da resposta só sai o que está em CAMPOS (lista fechada). E-mail, telefone e PDV do cliente nunca saem
#     daqui — nem para o log, nem para o resultado.
# Não reproduz o sufixo cifrado do front: a chamada é a que a página faz sozinha ao clicar em "Filtrar".

import re
import time

import credito as cr   # TravaAcionada, SessaoCaida, so_digitos, cpf_valido, sem_pii

PORTAL_HOST = 'https://pap.niointernet.com.br'
API_HOST = 'pap-api.niointernet.com.br'
ROTA_TELA = '/administrativo/consulta-os'

# ----------------------------------------------------------------------------------------------- travas de clique
CLIQUES = ('filtros', 'filtrar')        # LISTA BRANCA — texto inteiro do alvo, sem caixa e sem espaços repetidos


def conferir_clique(texto):
    """Levanta TravaAcionada se o texto do alvo não é EXATAMENTE um dos permitidos."""
    t = re.sub(r'\s+', ' ', str(texto or '')).strip().lower()
    if t not in CLIQUES:
        raise cr.TravaAcionada(f'clique recusado na Consulta OS (fora da lista branca): "{t[:40]}"')


def clicar(loc):
    """ÚNICO caminho de clique do operador de OS: lê o texto do alvo, confere a lista branca e só então clica."""
    conferir_clique(cr._texto_do(loc))
    loc.click(timeout=15000)


# ----------------------------------------------------------------------------------------------- travas de rede
# Chamadas à API do portal que podem passar. Tudo GET, menos o loginbo (a página confere a sessão ao abrir; não grava nada).
REDE_LEITURA = re.compile(r'^api/portal/novafibra/consultastatusos$')
REDE_SESSAO = (
    re.compile(r'^manutencao$'),
    re.compile(r'^auth/user/info$'),
    re.compile(r'^api/portal/permissoes(/skills)?$'),
    re.compile(r'^api/portal/loginbo$'),
)
TIPOS_VIGIADOS = cr.TIPOS_VIGIADOS


def _host(url):
    m = re.match(r'^[a-z]+://([^/?#]+)', str(url or ''), re.I)
    return (m.group(1) if m else '').lower()


def rede_bloqueada(url, metodo='GET', tipo='fetch'):
    """Devolve o caminho barrado (str) ou None. Regra única do page.route e do teste das travas.
    API do portal: só o que está na lista branca. Front do portal: só GET. Outros hosts (telemetria): não gravam no portal;
    passam, a não ser que casem com o que o crédito já barra sempre (pagamento, checkout, biometria…)."""
    metodo = str(metodo or 'GET').upper()
    c = cr.caminho_de(url)
    h = _host(url)
    if h == API_HOST:
        if metodo == 'GET' and REDE_LEITURA.match(c):
            return None
        if any(p.match(c) for p in REDE_SESSAO) and (metodo == 'GET' or c == 'api/portal/loginbo'):
            return None
        return c or '(raiz da api)'
    if h.endswith('niointernet.com.br'):
        return None if metodo == 'GET' else (c or '(front)')
    if tipo in TIPOS_VIGIADOS and cr.REDE_SEMPRE.search('/' + c):
        return c
    return None


# ----------------------------------------------------------------------------------------------- leitura da resposta
# LISTA FECHADA do que sai da resposta. O resto (clientEmail, clientPhoneWhatsapp, attendancePdv, ids internos) fica.
CAMPOS = {
    'statusOS': 'status_ordem',
    'statusAgendamento': 'status_agendamento',
    'agendamento': 'agendamento',
    'pendencia': 'pendencia',
    'caseNumber': 'caso',
    'numeroBA': 'numero_ba',
}
CAMPOS_MOTIVO = ('motivoCancelamento', 'subMotivoCancelamento')
VAZIOS = ('', '-', 'null', 'none')


def _txt(v):
    s = re.sub(r'\s+', ' ', str(v if v is not None else '')).strip()
    return None if s.lower() in VAZIOS else s[:300]


def ler_resposta(corpo, numero_os):
    """Corpo JSON da consultastatusos → {resultado: 'lida'|'nao_encontrada'|'erro', leitura?}. Sem dado pessoal."""
    if not isinstance(corpo, dict) or not isinstance(corpo.get('data'), list):
        return {'resultado': 'erro', 'motivo': 'resposta fora do formato esperado'}
    alvo = cr.so_digitos(numero_os)
    linha = next((x for x in corpo['data'] if isinstance(x, dict) and cr.so_digitos(x.get('numeroOS')) == alvo), None)
    if linha is None:
        return {'resultado': 'nao_encontrada', 'linhas': len(corpo['data'])}
    leitura = {}
    for origem, destino in CAMPOS.items():
        v = _txt(linha.get(origem))
        if v is not None:
            leitura[destino] = v
    motivo = ' · '.join(x for x in (_txt(linha.get(k)) for k in CAMPOS_MOTIVO) if x)
    if motivo:
        leitura['motivo_cancelamento'] = motivo
    if not leitura.get('status_ordem'):
        return {'resultado': 'erro', 'motivo': 'a resposta veio sem o status da OS'}
    return {'resultado': 'lida', 'leitura': leitura}


# ----------------------------------------------------------------------------------------------- a consulta
class ConsultaOS:
    """Uma leitura = uma página nova no contexto logado. Use rodar(); a página é sempre fechada no fim."""

    def __init__(self, ctx, params, log=print):
        self.ctx = ctx
        self.p = params            # {cpf, os, criada_em? (AAAA-MM-DD)}
        self.log = log
        self.page = None
        self.trava = None

    def _rota(self, route, request):
        try:
            barrado = rede_bloqueada(request.url, request.method, request.resource_type)
        except Exception:  # noqa: BLE001
            barrado = '(erro na trava)'
        if barrado:
            if not self.trava:
                self.trava = f'{request.method} {barrado}'
            return route.abort()
        return route.continue_()

    def _checar_trava(self):
        if self.trava:
            raise cr.TravaAcionada(f'trava de rede acionada na Consulta OS: {self.trava}')

    def _botao(self, nome):
        loc = self.page.get_by_role('button', name=re.compile(rf'^\s*{nome}\s*$', re.I))
        for i in range(min(loc.count(), 6)):
            b = loc.nth(i)
            try:
                if b.is_visible() and b.is_enabled():
                    return b
            except Exception:  # noqa: BLE001
                pass
        return None

    def _esperar(self, cond, segundos):
        fim = time.time() + segundos
        while time.time() < fim:
            self._checar_trava()
            v = cond()
            if v:
                return v
            self.page.wait_for_timeout(400)
        self._checar_trava()
        return None

    def rodar(self):
        t0 = time.time()
        out = {'resultado': 'erro', 'ms': 0}
        try:
            self.page = self.ctx.new_page()
            self.page.route('**/*', self._rota)
            self.page.goto(PORTAL_HOST + ROTA_TELA, wait_until='domcontentloaded', timeout=45000)
            abrir = self._esperar(lambda: self._botao('Filtros'), 25)
            if not abrir:
                if ROTA_TELA not in self.page.url:
                    raise cr.SessaoCaida('portal pediu login')
                raise RuntimeError('botão Filtros não apareceu')
            clicar(abrir)
            campo_cpf = self._esperar(lambda: self._campo('Digite o CPF/CNPJ'), 10)
            campo_os = self._campo('Digite o número de OS')
            if not campo_cpf or not campo_os:
                raise RuntimeError('campos do filtro não apareceram')
            self._preencher(campo_cpf, cr.so_digitos(self.p['cpf']))
            self._preencher(campo_os, cr.so_digitos(self.p['os']))
            # O filtro abre com os últimos 30 dias. OS mais antiga: recua a data "De" (digitação no campo, sem clique novo).
            de = self._data_de()
            if de:
                self._preencher(self._campos_data()[0], de)
            filtrar = self._botao('Filtrar')
            if not filtrar:
                raise RuntimeError('botão Filtrar não apareceu')
            with self.page.expect_response(lambda r: 'consultastatusos' in r.url, timeout=40000) as espera:
                clicar(filtrar)
            resp = espera.value
            self._checar_trava()
            if resp.status == 401:
                raise cr.SessaoCaida('portal recusou a sessão na consulta')
            if resp.status != 200:
                out = {'resultado': 'erro', 'motivo': f'o portal respondeu {resp.status} na consulta'}
            else:
                out = ler_resposta(resp.json(), self.p['os'])
        except (cr.SessaoCaida, cr.TravaAcionada):
            raise
        except Exception as e:  # noqa: BLE001
            self._checar_trava()
            out = {'resultado': 'erro', 'motivo': f'{type(e).__name__}: {cr.sem_pii(e)}'[:200]}
        finally:
            try:
                if self.page:
                    self.page.close()
            except Exception:  # noqa: BLE001
                pass
        out['ms'] = int((time.time() - t0) * 1000)
        return out

    # ---------------------------------------------------------------- utilidades
    def _campo(self, placeholder):
        loc = self.page.get_by_placeholder(re.compile(re.escape(placeholder), re.I))
        try:
            return loc.first if loc.count() > 0 and loc.first.is_visible() else None
        except Exception:  # noqa: BLE001
            return None

    def _campos_data(self):
        loc = self.page.locator('input[type="text"]')
        achados = []
        for i in range(min(loc.count(), 12)):
            try:
                if re.match(r'^\d{2}/\d{2}/\d{4}$', loc.nth(i).input_value(timeout=1000) or ''):
                    achados.append(loc.nth(i))
            except Exception:  # noqa: BLE001
                pass
        return achados

    def _data_de(self):
        """Data "De" (DD/MM/AAAA) quando a OS foi criada há mais de 25 dias; senão None (o padrão da tela serve)."""
        m = re.match(r'^(\d{4})-(\d{2})-(\d{2})', str(self.p.get('criada_em') or ''))
        if not m or len(self._campos_data()) < 2:
            return None
        import datetime
        criada = datetime.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        if (datetime.date.today() - criada).days <= 25:
            return None
        return (criada - datetime.timedelta(days=2)).strftime('%d/%m/%Y')

    def _preencher(self, loc, valor):
        loc.focus(timeout=10000)          # foco sem clique: o único clique do operador de OS é clicar(), com lista branca
        loc.fill('')
        loc.press_sequentially(str(valor), delay=35)
