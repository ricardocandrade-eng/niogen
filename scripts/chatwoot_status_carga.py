# NIOGEN | scripts/chatwoot_status_carga.py | 06/11/2026 — Claude Code (prompt 27, B2)
# Carga do status do Chatwoot nas conversas da Mari (mari_conversas.chatwoot_*, migration 0048).
# Lê TODAS as conversas da caixa da Mari (conta 195428, caixa 153431) pela API do Chatwoot e grava status, agente, time e
# etiquetas pela função service-role mari_chatwoot_sync — a mesma que o n8n chama a cada evento quando o gancho estiver no ar.
# Pode rodar de novo quando quiser (é idempotente). Nada de dado de cliente na saída: só nº da conversa, status e contagens.
#
# Token: variável CHATWOOT_NIO_TOKEN (ambiente ou variável de usuário do Windows) — nunca em arquivo.
# Uso:   python scripts/chatwoot_status_carga.py            (só mostra o que leu, não grava)
#        python scripts/chatwoot_status_carga.py --aplicar  (grava no Supabase Nio pelo CLI: db query --remote --yes)
import json
import os
import shutil
import subprocess
import sys
import urllib.request

CONTA = '195428'
CAIXA = 153431
BASE = 'https://app.chatwoot.com'
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NPX = shutil.which('npx.cmd') or shutil.which('npx') or 'npx'


def ler_var(nome):
    v = os.environ.get(nome)
    if v:
        return v.strip()
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as h:
            return winreg.QueryValueEx(h, nome)[0].strip()
    except Exception:
        return None


def api(caminho, token):
    req = urllib.request.Request(f'{BASE}{caminho}', headers={'api_access_token': token, 'Accept': 'application/json'})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode('utf-8'))


def conversas(token):
    pagina, todas = 1, []
    while True:
        d = api(f'/api/v1/accounts/{CONTA}/conversations?inbox_id={CAIXA}&status=all&assignee_type=all&page={pagina}', token)
        lote = ((d.get('data') or {}).get('payload')) or []
        if not lote:
            break
        todas.extend(c for c in lote if c.get('inbox_id') == CAIXA)
        if len(lote) < 25:
            break
        pagina += 1
    return todas


def lit(x):
    if x is None:
        return 'null'
    return "'" + str(x).replace("'", "''") + "'"


def main():
    token = ler_var('CHATWOOT_NIO_TOKEN')
    if not token:
        sys.exit('Falta a variável CHATWOOT_NIO_TOKEN (ambiente ou variável de usuário do Windows).')
    lista = conversas(token)
    linhas = []
    for c in lista:
        meta = c.get('meta') or {}
        agente = (meta.get('assignee') or {}).get('name')
        time = (meta.get('team') or {}).get('name')
        etiquetas = c.get('labels') or []
        arr = 'array[' + ','.join(lit(e) for e in etiquetas) + ']::text[]' if etiquetas else "'{}'::text[]"
        linhas.append(f"select mari_chatwoot_sync({lit(c.get('id'))}, {lit(c.get('status'))}, {lit(agente)}, {lit(time)}, {arr}) as n")
        print(f"#{c.get('id')}: {c.get('status')} · {'com ' + ' · '.join(x for x in [agente, time] if x) if (agente or time) else 'ninguém atribuído'} · {len(etiquetas)} etiqueta(s)")
    print(f'{len(lista)} conversa(s) lidas da caixa {CAIXA}.')
    if '--aplicar' not in sys.argv or not linhas:
        print('Nada gravado (use --aplicar).')
        return
    sql = 'select sum(n)::int as gravadas from (' + ' union all '.join(linhas) + ') x'
    p = subprocess.run([NPX, 'supabase', 'db', 'query', '--remote', '--yes', '-o', 'json', sql],
                       cwd=REPO, capture_output=True, text=True, encoding='utf-8')
    if p.returncode != 0:
        sys.exit(f'Erro ao gravar: {p.stderr.strip() or p.stdout.strip()}')
    print('Gravado:', p.stdout.strip()[-300:])


if __name__ == '__main__':
    main()
