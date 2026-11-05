#!/usr/bin/env python3
# NIOGEN | n8n/waba_templates_lote_c.py | 05/11/2026 — Claude Code (prompt nº 15, parte D)
# Submete os 3 templates do LOTE C (venda remota) na WABA Nio pela Graph API e grava meta_id/status em
# config_templates_waba. Texto EXATO de docs/TEMPLATES_WABA_Nio_031126_1430.md (Drive), lote C — o mesmo que a
# migration 0025 gravou no banco (o script confere antes de enviar e para se divergir).
#
# Token: variável de ambiente WABA_NIO_TOKEN (system user Nio_API / app Renata Digital). Nunca em arquivo.
# WABA Nio: 1419511943295487 (nunca a da Vero). Lotes A e B não são tocados; nio_confirmacao_visita fica como está.
#
# Uso:  python n8n/waba_templates_lote_c.py            # dry-run: mostra o que mandaria
#       python n8n/waba_templates_lote_c.py --enviar   # submete (só os que ainda não têm meta_id)
#       python n8n/waba_templates_lote_c.py --status   # consulta o status na Meta e atualiza o banco
#       python n8n/waba_templates_lote_c.py --reenviar nio_lembrete_biometria   # edita um template rejeitado (mesmo id)

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NPX = 'npx.cmd' if sys.platform == 'win32' else 'npx'
WABA_NIO = '1419511943295487'
GRAPH = 'https://graph.facebook.com/v21.0'

LOTE_C = [
    {'nome': 'nio_lembrete_biometria',
     # 0026: rejeitado com o link no corpo (INCORRECT_CATEGORY) → corpo sem link + botão de URL dinâmico (Ricardo, 05/11).
     'corpo': 'Oi, {{1}}! É a Mari, da Nio 👋\n\nSeu pedido de internet está quase pronto: só falta a biometria pelo celular, que leva uns 2 minutos. É só tocar em "Fazer a biometria" aqui embaixo.\n\nSe tiver qualquer dificuldade, me chama por aqui que o nosso time ajuda 😊',
     'exemplo': ['Ana'],
     'botao_url': {'texto': 'Fazer a biometria', 'url': 'https://ged360.niointernet.com.br/brprontopdv/pdv-mobile/biometria/login/{{1}}',
                   'exemplo': 'https://ged360.niointernet.com.br/brprontopdv/pdv-mobile/biometria/login/11uugb2uoh3k8s'},
     'botoes': ['Preciso de ajuda']},
    {'nome': 'nio_instalacao_agendada',
     'corpo': 'Oi, {{1}}! É a Mari, da Nio. Sua instalação está agendada:\n\nDia: {{2}}\nPeríodo: {{3}}\nEndereço: {{4}}\n\nO técnico da Nio vai até aí; é importante ter alguém maior de idade em casa. Se precisar remarcar, me avisa por aqui 😊',
     'exemplo': ['Ana', 'sexta-feira, 07/11', 'manhã, 8h às 12h', 'Rua Halfeld, 500, Centro'],
     'botoes': ['Confirmo', 'Preciso remarcar']},
    {'nome': 'nio_lembrete_instalacao',
     'corpo': 'Oi, {{1}}! Lembrete da Mari, da Nio: a instalação da sua internet é amanhã, {{2}}, no período da {{3}}. Fica alguém em casa pra receber o técnico? Se algo mudou, me avisa por aqui 😊',
     'exemplo': ['Ana', '07/11', 'manhã'],
     'botoes': ['Tudo certo', 'Preciso remarcar']},
]


def env_usuario(nome):
    v = os.environ.get(nome)
    if v or sys.platform != 'win32':
        return v
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as h:
            return winreg.QueryValueEx(h, nome)[0]
    except OSError:
        return None


def sql(q):
    p = subprocess.run([NPX, 'supabase', 'db', 'query', '--remote', '-o', 'json', '--yes', ' '.join(q.split())],
                       cwd=REPO, capture_output=True, text=True, encoding='utf-8')
    if p.returncode != 0:
        raise SystemExit(f'sql falhou: {p.stderr[-400:]}')
    out = p.stdout
    d = json.loads(out[out.find('{'):])
    return d.get('rows', [])


def graph(method, path, body=None):
    tok = env_usuario('WABA_NIO_TOKEN')
    if not tok:
        raise SystemExit('WABA_NIO_TOKEN ausente.')
    req = urllib.request.Request(f'{GRAPH}{path}', method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Authorization': f'Bearer {tok}', 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        return {'erro': e.code, 'detalhe': e.read().decode()[:600]}


def payload(t):
    botoes = []
    if t.get('botao_url'):
        u = t['botao_url']
        botoes.append({'type': 'URL', 'text': u['texto'], 'url': u['url'], 'example': [u['exemplo']]})
    botoes += [{'type': 'QUICK_REPLY', 'text': b} for b in t['botoes']]
    return {'name': t['nome'], 'language': 'pt_BR', 'category': 'UTILITY',
            'components': [{'type': 'BODY', 'text': t['corpo'], 'example': {'body_text': [t['exemplo']]}},
                           {'type': 'BUTTONS', 'buttons': botoes}]}


def main():
    banco = {r['nome']: r for r in sql("select nome, corpo, meta_id, status from public.config_templates_waba "
                                       "where nome in ('nio_lembrete_biometria', 'nio_instalacao_agendada', 'nio_lembrete_instalacao')")}
    for t in LOTE_C:
        b = banco.get(t['nome'])
        if not b:
            raise SystemExit(f"{t['nome']} não está em config_templates_waba (aplique a migration 0025 antes).")
        if b['corpo'] != t['corpo']:
            raise SystemExit(f"{t['nome']}: texto do banco diverge do script — corrigir antes (regra 12).")

    if '--status' in sys.argv:
        r = graph('GET', f'/{WABA_NIO}/message_templates?fields=name,status,id,category&limit=200')
        for m in r.get('data', []):
            if m['name'] in banco:
                sql(f"update public.config_templates_waba set status = '{m['status']}', meta_id = '{m['id']}', "
                    f"atualizado_em = now() where nome = '{m['name']}'")
                print(f"{m['name']}: {m['status']} ({m['category']}, id {m['id']})")
        return

    for t in LOTE_C:
        b = banco[t['nome']]
        if b['meta_id'] and '--reenviar' in sys.argv and t['nome'] in sys.argv:
            # template rejeitado: edita o mesmo id (a Meta aceita editar REJECTED) com o texto novo do banco
            corpo = {k: v for k, v in payload(t).items() if k in ('category', 'components')}
            r = graph('POST', f"/{b['meta_id']}", corpo)
            print(f"{t['nome']} (reenvio do id {b['meta_id']}): {r}")
            continue
        if banco[t['nome']]['meta_id']:
            print(f"{t['nome']}: já submetido (id {banco[t['nome']]['meta_id']}, {banco[t['nome']]['status']}) — pulei")
            continue
        if '--enviar' not in sys.argv:
            print(f"[dry-run] {t['nome']}: {json.dumps(payload(t), ensure_ascii=False)[:200]}…")
            continue
        r = graph('POST', f'/{WABA_NIO}/message_templates', payload(t))
        if r.get('id'):
            sql(f"update public.config_templates_waba set meta_id = '{r['id']}', status = '{r.get('status', 'PENDING')}', "
                f"atualizado_em = now() where nome = '{t['nome']}'")
        print(f"{t['nome']}: {r}")


if __name__ == '__main__':
    main()
