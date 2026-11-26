#!/usr/bin/env python3
# NIOGEN | portal/dashboard_sessao.py | 25/11/2026 — Claude Code / Opus 5.5
# Login de gestão do Dashboard com MFA/chave de acesso, feito UMA vez pelo Ricardo no PC, e a sessão levada para a VPS BR.
# Exceção da regra 5 do CLAUDE.md (Ricardo, 25/11/2026: "Vamos pelo terceiro caminho"): a sessão fica SÓ na VPS
# (/opt/niogen/portal/sessao/dash.json, chmod 600). Aqui no PC ela existe só alguns segundos, num arquivo temporário apagado
# logo depois da cópia. Nada é impresso: nem cookie, nem token, nem senha. Este arquivo não guarda segredo nenhum.
#
# Uso (PC do Ricardo, IP do Brasil):
#   python portal/dashboard_sessao.py
# Abre uma janela do Chrome no login da Microsoft. Você entra com o login de gestão e a chave de acesso (celular), marca
# "Continuar conectado" e espera o Dashboard aparecer. O script percebe sozinho, guarda a sessão e copia para a VPS.

import os
import subprocess
import sys
import tempfile
import time

PORTAL_SAML = 'https://pap-api.niointernet.com.br/auth/saml/login?origem=bo'
DASH = 'https://pap.niointernet.com.br/administrativo/dashboard'
VPS = 'root@216.128.168.202'
CHAVE = os.path.expanduser('~/.ssh/id_ed25519_vero')
DESTINO_DIR = '/opt/niogen/portal/sessao'
ESPERA_MIN = 10


def log(m):
    print(f'[{time.strftime("%H:%M:%S")}] {m}', flush=True)


def ssh(cmd, entrada=None):
    return subprocess.run(['ssh', '-i', CHAVE, '-o', 'BatchMode=yes', VPS, cmd], input=entrada,
                          capture_output=True, timeout=60)


def main():
    from playwright.sync_api import sync_playwright
    with sync_playwright() as pw:
        nav = pw.chromium.launch(headless=False, channel='chrome')
        ctx = nav.new_context(locale='pt-BR', timezone_id='America/Sao_Paulo', viewport={'width': 1400, 'height': 860})
        page = ctx.new_page()
        page.goto(PORTAL_SAML, wait_until='domcontentloaded')
        log('Janela aberta. Entre com o login de gestão e a chave de acesso do celular; marque "Continuar conectado".')
        log(f'Espero até {ESPERA_MIN} min pelo portal.')
        t0 = time.time()
        ultimo = ''
        while time.time() - t0 < ESPERA_MIN * 60:
            # A Microsoft pode abrir outra aba/janela no meio do caminho: olha todas as páginas do contexto.
            no_portal = [pg for pg in ctx.pages if not pg.is_closed()
                         and pg.url.startswith('https://pap.niointernet.com.br/administrativo') and 'login-callback' not in pg.url]
            onde = ' | '.join(sorted({pg.url.split('/')[2] for pg in ctx.pages if not pg.is_closed() and '://' in pg.url}))
            if onde != ultimo:
                log(f'janela em: {onde or "(nenhuma)"}')
                ultimo = onde
            if no_portal:
                page = no_portal[0]
                page.wait_for_timeout(3000)   # deixa o front gravar o cookie
                break
            if not any(not pg.is_closed() for pg in ctx.pages):
                log('A janela foi fechada. Nada foi guardado.')
                sys.exit(3)
            page.wait_for_timeout(1000)   # pausa que deixa o Playwright receber os eventos (time.sleep não deixa)
        else:
            log('O login não chegou ao portal a tempo. Nada foi guardado.')
            sys.exit(3)
        log('Login ok. Abrindo o Dashboard para conferir…')
        page.goto(DASH, wait_until='domcontentloaded')
        ok = False
        for _ in range(40):
            if page.query_selector('iframe[src*="powerbi"]'):
                ok = True
                break
            page.wait_for_timeout(1000)
        log('Dashboard com o painel do Power BI: ' + ('sim' if ok else 'NÃO (este login vê o Dashboard?)'))
        if not ok:
            sys.exit(4)
        fd, tmp = tempfile.mkstemp(suffix='.json')
        os.close(fd)
        try:
            ctx.storage_state(path=tmp)
            with open(tmp, 'rb') as f:
                dados = f.read()
        finally:
            try:
                os.remove(tmp)
            except OSError:
                pass
        ctx.close()
        nav.close()
    # O container roda como pwuser (uid 1000 na imagem do Playwright): a pasta é dele, só ele lê.
    r = ssh(f'mkdir -p {DESTINO_DIR} && chmod 700 {DESTINO_DIR} && umask 077 && cat > {DESTINO_DIR}/dash.json '
            f'&& chmod 600 {DESTINO_DIR}/dash.json && chown -R 1000:1000 {DESTINO_DIR} && stat -c "%s bytes" {DESTINO_DIR}/dash.json',
            entrada=dados)
    del dados
    if r.returncode != 0:
        log('Falhou a cópia para a VPS: ' + r.stderr.decode(errors='replace')[-200:])
        sys.exit(5)
    log('Sessão guardada na VPS (' + r.stdout.decode().strip() + '). Pode fechar. No PC não ficou cópia.')


if __name__ == '__main__':
    main()
