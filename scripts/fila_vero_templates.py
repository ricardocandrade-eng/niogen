#!/usr/bin/env python3
# NIOGEN | scripts/fila_vero_templates.py | 16/11/2026 — Claude Code (prompt docs/Prompt_fila_vero_piloto100_161126_1640.md)
# Submete os 3 templates da Fila Vero (nio_fv_a1, nio_fv_a2, nio_fv_b1) na WABA do número do disparo
# (974428375341104, "Apoio Nio") e consulta o status. Texto do prompt v2 (Drive), rodapé e botões de 16/11 17h35.
# A2 e B1 ganharam "Oi, " na frente: a Meta não aceita variável no início do texto (erro 2388299, 16/11).
# O status e o id ficam em config_regras.fila_vero_templates (--status grava).
#
# Token: variável de usuário do Windows WABA_NIO_TOKEN (system user Nio_API). Nunca em arquivo.
#
# Uso:  python scripts/fila_vero_templates.py            # dry-run
#       python scripts/fila_vero_templates.py --enviar   # submete os que ainda não existem na WABA
#       python scripts/fila_vero_templates.py --status   # status na Meta (e grava no banco, se a tabela existir)
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NPX = 'npx.cmd' if sys.platform == 'win32' else 'npx'
WABA_FILA = '974428375341104'
GRAPH = 'https://graph.facebook.com/v21.0'
RODAPE = 'Revendedor autorizado Nio · Responda SAIR para não receber'


# A Meta não aceita link direto para o WhatsApp no botão (erro 2388081, 16/11): o botão abre docs/fv.html, que conta o
# clique e leva ao wa.me da Mari com o texto "Quero ver a oferta Nio com preço congelado até 2030 (FV-A1-<código>)".
# {{1}} do botão = código curto da linha da fila_vero (fila_vero.codigo).
def link(codigo):
    return f'https://niogen.dharmatelecom.com.br/fv.html?t={codigo}&c={{{{1}}}}'


TEMPLATES = [
    {'nome': 'nio_fv_a1', 'codigo': 'A1',
     'corpo': 'Oi, {{1}}! A fibra da Nio chegou {{2}} 🚀\n'
              '1 Giga de internet + chip com 20 GB de internet 5G por R$ 155/mês no cartão, com preço fixo até 2030. '
              'Sem reajuste no meio do caminho.\n'
              'Quer que eu veja se compensa trocar? É rapidinho.'},
    {'nome': 'nio_fv_a2', 'codigo': 'A2',
     'corpo': 'Oi, {{1}}! Quanto você paga hoje na internet de casa? 👀\n'
              'Já tem fibra Nio {{2}}: 600 Mega por R$ 95/mês no cartão (R$ 110 no boleto), com preço fixo até 2030.\n'
              'Toque no botão que eu te mostro em 2 minutos.'},
    {'nome': 'nio_fv_b1', 'codigo': 'B1',
     'corpo': 'Oi, {{1}}! Sua internet fibra ainda não chegou? 📡\n'
              'Boa notícia: a fibra da Nio já chegou {{2}}. De 600 Mega a 1 Giga, a partir de R$ 95/mês no cartão, '
              'com preço fixo até 2030.\n'
              'Quer que eu confira o seu endereço e te passe as opções?'},
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
        return {'erro': e.code, 'detalhe': e.read().decode()[:800]}


def payload(t):
    return {'name': t['nome'], 'language': 'pt_BR', 'category': 'MARKETING',
            'components': [
                {'type': 'BODY', 'text': t['corpo'],
                 'example': {'body_text': [['Ana', 'na Rua Santa Terezinha']]}},
                {'type': 'FOOTER', 'text': RODAPE},
                {'type': 'BUTTONS', 'buttons': [
                    {'type': 'URL', 'text': 'Quero ver a oferta', 'url': link(t['codigo']),
                     'example': [link(t['codigo']).replace('{{1}}', 'k3x9ab')]},
                    {'type': 'QUICK_REPLY', 'text': 'Não tenho interesse'}]}]}


def sql(q):
    p = subprocess.run([NPX, 'supabase', 'db', 'query', '--linked', '-o', 'json', q],
                       cwd=REPO, capture_output=True, text=True, encoding='utf-8')
    return p.returncode == 0


def main():
    atuais = {m['name']: m for m in graph('GET', f'/{WABA_FILA}/message_templates?fields=name,status,id,category,'
                                                 'rejected_reason&limit=100').get('data', [])}
    if '--status' in sys.argv:
        estado = {}
        for t in TEMPLATES:
            m = atuais.get(t['nome'])
            print(f"{t['nome']}: {m['status'] if m else 'não existe'}"
                  + (f" · id {m['id']} · {m.get('category')} · motivo {m.get('rejected_reason')}" if m else ''))
            if m:
                estado[t['nome']] = {'id': m['id'], 'status': m['status'], 'codigo': f"FV-{t['codigo']}"}
        if estado:
            j = json.dumps(estado).replace("'", "''")
            sql(f"update public.config_regras set valor = '{j}'::jsonb, atualizado_em = now() "
                f"where chave = 'fila_vero_templates'")
        return
    for t in TEMPLATES:
        if t['nome'] in atuais:
            print(f"{t['nome']}: já existe ({atuais[t['nome']]['status']}) — pulei")
            continue
        if '--enviar' not in sys.argv:
            print(f"[dry-run] {json.dumps(payload(t), ensure_ascii=False)}")
            continue
        print(f"{t['nome']}: {graph('POST', f'/{WABA_FILA}/message_templates', payload(t))}")


if __name__ == '__main__':
    main()
