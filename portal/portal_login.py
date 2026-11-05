#!/usr/bin/env python3
# NIOGEN | portal/portal_login.py | 05/11/2026 — Claude Code (prompt nº 16, Parte A-bis)
# Login do portal PAP da Nio (perfil BO) por navegador: Chromium headless (Playwright) segue o SSO Microsoft
# (tt837725@vtalcorp.onmicrosoft.com, sem MFA, tela "Continuar conectado?" = Sim), volta ao portal e deixa a página
# aberta. As consultas de viabilidade rodam DENTRO da página (Plano B, decisão do Ricardo 05/11): o Authorization vem
# da função do próprio front (_getAuthorizationToken), capturada por um gancho de inicialização — o script não
# reproduz o sufixo cifrado nem guarda token fora do navegador.
#
# Onde roda: VPS no Brasil (o front bloqueia IP de fora do país — 403 na VPS de Nova Jersey em 05/11), dentro do
# container niogen-portal (imagem oficial do Playwright; ver Dockerfile). Nunca no PC do Ricardo.
#
# Segredos: NIO_PORTAL_USER / NIO_PORTAL_PASS só do ambiente do container. Nada disso é impresso, logado ou gravado.
# Captura de tela só em ERRO, em NIO_PORTAL_ERROS_DIR (fora do repo).
#
# CLI (dentro do container):
#   python portal_login.py diagnostico   # login + GET /api/portal/permissoes pela página; não grava nada
#
# Códigos de falha: 2 ambiente · 3 usuário recusado · 4 senha recusada · 5 tela inesperada/timeout ·
#                   6 sem token/sem front · 8 API recusou · 9 caminho fora do nível A

import datetime
import json
import os
import re
import sys
import time
import urllib.parse

PORTAL_SAML = 'https://pap-api.niointernet.com.br/auth/saml/login?origem=bo'
PORTAL_HOST = 'https://pap.niointernet.com.br'
API = 'https://pap-api.niointernet.com.br'
ERROS_DIR = os.environ.get('NIO_PORTAL_ERROS_DIR', '/opt/niogen/portal/erros')
JWT = re.compile(r'^eyJ[\w-]+\.[\w-]+\.[\w-]+$')

# Nível A (viabilidade) e nada mais. Nível C (pedido, crédito, biometria, OS, checkout, cadastro) é PROIBIDO:
# qualquer caminho fora desta lista é recusado antes de sair do navegador.
PERMITIDOS = [
    re.compile(r'^api/portal/permissoes$'),
    re.compile(r'^api/portal/novafibra/endereco$'),                                   # POST: cria o interesse
    re.compile(r'^api/portal/novafibra/endereco/consultaEnderecos/[\w-]+$'),
    re.compile(r'^api/portal/novafibra/endereco/[\w-]+/selecionar/[\w-]+$'),
    re.compile(r'^api/portal/novafibra/endereco/tipos/complementos/[\w-]+$'),
    re.compile(r'^api/portal/novafibra/endereco/[\w-]+$'),                            # GET polling / PATCH referência
    re.compile(r'^api/portal/novafibra/complementos/[\w-]+$'),
    re.compile(r'^api/portal/viabilidades/v2/[\w-]+$'),
    re.compile(r'^api/portal/novafibra/posseSalesforce/address/[\w-]+$'),
]
PROIBIDOS = re.compile(r'analiseCredito|propostaCredito|biometria|aberturaos|checkout|cadastroCliente|'
                       r'consultaReceita|pagamento|dadosBancarios|portabilidade|vendas|duplicidadepedido', re.I)

# Gancho: o webpack do portal registra cada exportação com Object.defineProperty(exports, nome, {get}).
# Guardamos o getter de _getAuthorizationToken quando ele passa — é a função do próprio front.
GANCHO_JS = r"""
(() => {
  const orig = Object.defineProperty;
  Object.defineProperty = function (obj, prop, desc) {
    try {
      if (prop === '_getAuthorizationToken' && desc && typeof desc.get === 'function' && !window.__ngAuthGetter) {
        window.__ngAuthGetter = desc.get;
      }
    } catch (e) {}
    return orig.call(this, obj, prop, desc);
  };
})();
"""

CHAMAR_JS = r"""
async ({ api, metodo, caminho, corpo }) => {
  if (!window.__ngAuthGetter) return { status: 0, erro: 'sem_gancho' };
  const auth = window.__ngAuthGetter()();
  const init = { method: metodo, headers: { Origem: 'BO', 'Content-Type': 'application/json', Authorization: auth } };
  if (corpo !== null && corpo !== undefined && metodo !== 'GET') init.body = JSON.stringify(corpo);
  const r = await fetch(api + '/' + caminho, init);
  const t = await r.text();
  let j = null; try { j = JSON.parse(t); } catch (e) {}
  return { status: r.status, json: j, texto: j === null ? t.slice(0, 300) : null };
}
"""


class Falha(Exception):
    def __init__(self, codigo, msg):
        super().__init__(msg)
        self.codigo = codigo


def log(msg):
    print(f'[{datetime.datetime.now().strftime("%d/%m %H:%M:%S")}] {msg}', flush=True)


def credenciais():
    usuario = (os.environ.get('NIO_PORTAL_USER') or '').strip()
    senha = (os.environ.get('NIO_PORTAL_PASS') or '').strip()
    if not usuario or not senha:
        raise Falha(2, 'NIO_PORTAL_USER/NIO_PORTAL_PASS ausentes')
    # o .env guarda só a matrícula; o SSO quer o UPN do tenant da V.tal (domínio não é segredo)
    dominio = (os.environ.get('NIO_PORTAL_DOMINIO') or '').strip()
    if '@' not in usuario and dominio:
        usuario = f'{usuario.lower()}@{dominio}'
    return usuario, senha


def captura_erro(page, etapa):
    """Captura de tela SÓ em erro. A senha nunca aparece: o campo da Microsoft é mascarado e é limpo antes."""
    try:
        os.makedirs(ERROS_DIR, exist_ok=True)
        nome = os.path.join(ERROS_DIR, f'{datetime.datetime.now().strftime("%d%m%y_%H%M%S")}_{etapa}.png')
        page.screenshot(path=nome, full_page=True)
        log(f'captura de erro: {nome}')
    except Exception as e:  # noqa: BLE001
        log(f'sem captura ({type(e).__name__})')


def _erro_ms(page, seletores):
    for sel in seletores:
        try:
            el = page.query_selector(sel)
            if el and el.is_visible():
                t = (el.inner_text() or '').strip()
                if t:
                    return t[:200]
        except Exception:  # noqa: BLE001
            pass
    return ''


def _enviar(page):
    """Botão principal da tela da Microsoft (Avançar / Entrar / Sim)."""
    for sel in ('#idSIButton9', 'input[type=submit]', 'button[type=submit]'):
        for el in page.query_selector_all(sel):
            if el.is_visible():
                el.click()
                return
    page.keyboard.press('Enter')


def _mascara(url):
    partes = url.split('?')[0].split('/', 3)
    resto = '/'.join('<jwt>' if JWT.match(urllib.parse.unquote(x)) else x
                     for x in (partes[3] if len(partes) > 3 else '').split('/'))
    return f'{partes[2] if len(partes) > 2 else url}/{resto}'[:90]


def novo_contexto(navegador):
    ctx = navegador.new_context(locale='pt-BR', timezone_id='America/Sao_Paulo')
    ctx.add_init_script(GANCHO_JS)
    return ctx


def entrar(ctx, exigir_front=True):
    """Faz o login numa página nova do contexto e a devolve aberta no portal. Devolve (page, info).
    info só tem metadados. exigir_front=False aceita o caso da VPS fora do Brasil (front 403, sem gancho)."""
    usuario, senha = credenciais()
    info = {'usuario_formato': 'matricula@dominio' if '@' in usuario else 'matricula', 'kmsi': False, 'telas': []}
    page = ctx.new_page()
    trilha = []
    page.on('response', lambda r: trilha.append(f'{r.request.method} {_mascara(r.url)} → {r.status}')
            if 'niointernet.com.br' in r.url else None)
    t_ini = time.time()
    try:
        page.goto(PORTAL_SAML, wait_until='domcontentloaded', timeout=45000)
        page.wait_for_url(lambda u: 'login.microsoftonline.com' in u, wait_until='domcontentloaded', timeout=45000)
        info['telas'].append('microsoft')

        page.wait_for_selector('input[name=loginfmt]', timeout=30000)
        page.fill('input[name=loginfmt]', usuario)
        _enviar(page)
        t0 = time.time()
        while time.time() - t0 < 30:
            time.sleep(0.5)
            err = _erro_ms(page, ('#usernameError', '#error', '.alert-error'))
            if err:
                captura_erro(page, 'usuario')
                raise Falha(3, f'Microsoft recusou o usuário ({info["usuario_formato"]}): {err}')
            if 'login.microsoftonline.com' not in page.url:
                captura_erro(page, 'idp_federado')
                raise Falha(5, f'o login foi para outro provedor ({page.url.split("/")[2]})')
            if page.is_visible('input[name=passwd]'):
                time.sleep(0.8)
                break
        else:
            captura_erro(page, 'sem_campo_senha')
            raise Falha(5, 'o campo de senha não apareceu em 30 s')

        page.fill('input[name=passwd]', senha)
        _enviar(page)
        t0 = time.time()
        while time.time() - t0 < 45:
            url = page.url
            if url.startswith(PORTAL_HOST):
                break
            if 'login.microsoftonline.com' in url:
                err = _erro_ms(page, ('#passwordError',))
                if err:
                    page.fill('input[name=passwd]', '')
                    captura_erro(page, 'senha')
                    raise Falha(4, f'Microsoft recusou a senha: {err}')
                if page.query_selector('#KmsiCheckboxField') or page.query_selector('#KmsiDescription') \
                        or 'kmsi' in url.lower():
                    info['kmsi'] = True
                    _enviar(page)
                    time.sleep(1)
                    continue
                for sel, nome in (('#idDiv_SAOTCS_Proofs', 'mfa'), ('#idTxtBx_SAOTCC_OTC', 'mfa_codigo'),
                                  ('input[name=NewPassword]', 'trocar_senha'), ('#ProofUpDescription', 'cadastro_mfa')):
                    if page.query_selector(sel):
                        captura_erro(page, nome)
                        raise Falha(5, f'tela inesperada na Microsoft: {nome}')
            time.sleep(0.5)
        else:
            captura_erro(page, 'nao_voltou')
            raise Falha(5, 'a Microsoft não devolveu ao portal em 45 s')
        info['telas'].append('portal')

        # O front grava o token no cookie e carrega o bundle (o gancho pega a função de autorização).
        t0 = time.time()
        while time.time() - t0 < 40:
            tem_gancho = page.evaluate('() => !!window.__ngAuthGetter')
            tem_cookie = any(c['name'] == 'token' and c['value'] for c in ctx.cookies(PORTAL_HOST + '/administrativo'))
            if tem_gancho and tem_cookie:
                info['plano'] = 'B'
                break
            if not exigir_front and any('pap.niointernet.com.br' in t and '→ 403' in t for t in trilha):
                info['plano'] = 'sem_front'
                info['front_403'] = True
                break
            time.sleep(0.5)
        else:
            captura_erro(page, 'sem_front')
            for t in trilha[-8:]:
                log('  ' + t)
            raise Falha(6, 'voltou ao portal mas o front não carregou (sem cookie/sem função de autorização)')
        info['segundos'] = round(time.time() - t_ini, 1)
        return page, info
    except Falha:
        page.close()
        raise
    except Exception as e:  # noqa: BLE001
        host = page.url.split('/')[2] if '://' in page.url else page.url[:40]
        captura_erro(page, 'excecao')
        for t in trilha[-8:]:
            log('  ' + t)
        page.close()
        raise Falha(5, f'{type(e).__name__} em {host} (telas: {info["telas"]})') from None


def caminho_permitido(caminho):
    c = caminho.lstrip('/').split('?')[0]
    if PROIBIDOS.search(c):
        return False
    return any(p.match(c) for p in PERMITIDOS)


def chamar(page, metodo, caminho, corpo=None):
    """Chamada à API do portal DENTRO da página (headers do próprio front). Só nível A."""
    metodo = (metodo or 'GET').upper()
    if metodo not in ('GET', 'POST', 'PATCH', 'PUT'):
        raise Falha(9, f'método {metodo} não permitido')
    if not caminho_permitido(caminho):
        raise Falha(9, f'caminho fora do nível A: {caminho.split("?")[0][:80]}')
    return page.evaluate(CHAMAR_JS, {'api': API, 'metodo': metodo, 'caminho': caminho.lstrip('/'), 'corpo': corpo})


def resumo(r):
    j = r.get('json') if isinstance(r, dict) else None
    if isinstance(j, dict):
        return {k: j.get(k) for k in ('codigo', 'code', 'mensagem', 'message') if k in j}
    return {'texto': (r.get('texto') or '')[:80]} if isinstance(r, dict) else {}


def main():
    modo = sys.argv[1] if len(sys.argv) > 1 else 'diagnostico'
    if modo != 'diagnostico':
        log('uso: python portal_login.py diagnostico')
        sys.exit(2)
    from playwright.sync_api import sync_playwright  # só existe dentro do container
    try:
        with sync_playwright() as pw:
            nav = pw.chromium.launch(headless=True, args=['--no-sandbox', '--disable-dev-shm-usage'])
            ctx = novo_contexto(nav)
            page, info = entrar(ctx, exigir_front=False)
            log('login ok — ' + json.dumps(info, ensure_ascii=False))
            if info.get('plano') == 'B':
                r = chamar(page, 'GET', 'api/portal/permissoes')
                log(f'API pela página: HTTP {r.get("status")} {resumo(r)}')
            else:
                log('front bloqueado neste IP (403): rodar na VPS do Brasil')
            for proibido in ('api/portal/novafibra/analiseCredito', 'api/portal/aberturaos/checkout/enviar'):
                log(f'trava do nível C ({proibido}): permitido={caminho_permitido(proibido)}')
            ctx.close()
            nav.close()
    except Falha as f:
        log(f'ERRO {f.codigo}: {f}')
        sys.exit(f.codigo)
    log('diagnóstico: nada gravado')


if __name__ == '__main__':
    main()
