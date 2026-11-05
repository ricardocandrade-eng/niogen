#!/usr/bin/env python3
# NIOGEN | portal/servico.py | 05/11/2026 — Claude Code (prompt nº 16, Plano B)
# "Operador" do portal PAP: mantém UM Chromium logado no portal (VPS no Brasil) e executa, dentro da página, só as
# chamadas de viabilidade (nível A) que o n8n pedir. O n8n nunca vê token nem senha; recebe status + JSON da API.
#
# Rotas (todas exigem o header X-Portal-Secret = NIO_PORTAL_SERVICO_SECRET; sem ele, 401):
#   GET  /saude                         → {ok, logado, plano, obtido_em, ultimo_uso, ultimo_erro}
#   POST /renovar  {forcar?: bool}      → confere a sessão (GET permissoes); se caiu ou forcar, faz login de novo
#   POST /chamar   {metodo, caminho, corpo?} → chamada à API do portal pela página; 401 = renova UMA vez e repete
#
# Limites: um pedido por vez (servidor de 1 thread — o Playwright síncrono exige), até 40 chamadas/min (freio de
# segurança contra laço), nível C recusado em portal_login.caminho_permitido. Log sem corpo (endereço é dado pessoal).

import datetime
import hmac
import json
import os
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, HTTPServer

import portal_login as pl

PORTA = int(os.environ.get('NIO_PORTAL_PORTA', '8090'))
SEGREDO = (os.environ.get('NIO_PORTAL_SERVICO_SECRET') or '').strip()
LIMITE_MIN = 40


def agora():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


class Operador:
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
            self.nav = self.pw.chromium.launch(headless=True, args=['--no-sandbox', '--disable-dev-shm-usage'])
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


OP = None


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
        return json.loads(self.rfile.read(n) or b'{}') if n else {}

    def _rota(self, metodo):
        t0 = time.time()
        rota = self.path.split('?')[0]
        if not self._autorizado():
            self._resp(401, {'ok': False, 'erro': 'segredo inválido'})
            pl.log(f'{metodo} {rota} → 401 (segredo)')
            return
        try:
            if metodo == 'GET' and rota == '/saude':
                self._resp(200, {'ok': True, **OP.estado})
            elif metodo == 'POST' and rota == '/renovar':
                b = self._json()
                self._resp(200, {**OP.renovar(bool(b.get('forcar'))), **OP.estado})
            elif metodo == 'POST' and rota == '/chamar':
                b = self._json()
                r = OP.chamar(b.get('metodo', 'GET'), str(b.get('caminho') or ''), b.get('corpo'))
                self._resp(200, {'ok': True, **r})
                pl.log(f'chamar {str(b.get("metodo", "GET")).upper()} {str(b.get("caminho") or "").split("?")[0][:60]}'
                       f' → {r.get("status")} ({time.time() - t0:.1f} s{", renovou" if r.get("renovou") else ""})')
                return
            else:
                self._resp(404, {'ok': False, 'erro': 'rota inexistente'})
        except pl.Falha as f:
            code = 429 if f.codigo == 429 else 403 if f.codigo == 9 else 502
            self._resp(code, {'ok': False, 'codigo': f.codigo, 'erro': str(f), **OP.estado})
            pl.log(f'{metodo} {rota} → {code} ({f.codigo}: {f})')
            return
        except Exception as e:  # noqa: BLE001
            self._resp(500, {'ok': False, 'erro': type(e).__name__})
            pl.log(f'{metodo} {rota} → 500 ({type(e).__name__})')
            return
        pl.log(f'{metodo} {rota} ({time.time() - t0:.1f} s)')

    def do_GET(self):
        self._rota('GET')

    def do_POST(self):
        self._rota('POST')


def main():
    global OP
    if len(SEGREDO) < 24:
        raise SystemExit('NIO_PORTAL_SERVICO_SECRET ausente ou curto (mín. 24) — serviço não sobe sem ele.')
    pl.credenciais()  # falha cedo se faltar usuário/senha
    OP = Operador()
    try:
        OP.login()
    except pl.Falha as f:
        pl.log(f'login inicial falhou ({f.codigo}: {f}) — o serviço sobe e tenta de novo no próximo pedido')
    pl.log(f'niogen-portal ouvindo na porta {PORTA}')
    HTTPServer(('0.0.0.0', PORTA), Handler).serve_forever()


if __name__ == '__main__':
    main()
