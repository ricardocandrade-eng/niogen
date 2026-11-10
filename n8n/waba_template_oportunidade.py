#!/usr/bin/env python3
# NIOGEN | n8n/waba_template_oportunidade.py | 10/11/2026 — Claude Code (conserto do prompt Prompt_mari_ao_vivo_oportunidades_101126_1400)
# Submete na WABA Nio o template da 🔥 oportunidade (uso = 'oportunidade' em config_templates_waba, migration 0110) e grava
# meta_id/status no banco. O texto vem do BANCO (fonte única; o mesmo de docs/TEMPLATES_WABA_Nio_031126_1430.md, lote E).
# Sem marca: assinado pelo primeiro nome de quem manda ({{2}}), nunca "Dharma" nem Nio (Ricardo, 10/11 16h16) — aprova só na Meta.
#
# Token: variável de ambiente WABA_NIO_TOKEN (system user Nio_API). Nunca em arquivo. WABA Nio 1419511943295487 (nunca a da Vero).
# CLI do Supabase fixo em 3.0.0 (o 3.1.0 é bloqueado pelo Controle de Aplicativo do Windows).
#
# Uso:  python n8n/waba_template_oportunidade.py             # dry-run: mostra o payload
#       python n8n/waba_template_oportunidade.py --enviar    # submete (só se ainda não tem meta_id)
#       python n8n/waba_template_oportunidade.py --status    # lê o status na Meta e atualiza o banco (APPROVED liga o canal "template")

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
EXEMPLO = ['Ana', 'Ricardo']   # {{1}} nome do cliente · {{2}} primeiro nome de quem manda


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
    p = subprocess.run([NPX, 'supabase@3.0.0', 'db', 'query', '--remote', '--yes', ' '.join(q.split())],
                       cwd=REPO, capture_output=True, text=True, encoding='utf-8')
    out = p.stdout
    i = out.find('{')
    if p.returncode != 0 or i < 0:
        raise SystemExit(f'sql falhou: {(p.stderr or out)[-400:]}')
    return json.loads(out[i:]).get('rows', [])


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
    comps = [{'type': 'BODY', 'text': t['corpo'], 'example': {'body_text': [EXEMPLO]}}]
    if t.get('rodape'):
        comps.append({'type': 'FOOTER', 'text': t['rodape']})
    if t.get('botoes'):
        comps.append({'type': 'BUTTONS', 'buttons': [{'type': 'QUICK_REPLY', 'text': b} for b in t['botoes']]})
    return {'name': t['nome'], 'language': t['idioma'] or 'pt_BR', 'category': t['categoria'], 'components': comps}


def main():
    linhas = sql("select nome, categoria, idioma, corpo, botoes, rodape, meta_id, status from public.config_templates_waba "
                 "where uso = 'oportunidade' order by nome")
    if not linhas:
        raise SystemExit("Nenhum template com uso = 'oportunidade' (aplique a migration 0110).")
    for t in linhas:
        if isinstance(t['botoes'], str):
            t['botoes'] = json.loads(t['botoes'])
        corpo = t['corpo'] or ''
        if any(x in corpo for x in ('Dharma', 'Nio')):
            raise SystemExit(f"{t['nome']}: o texto cita empresa/marca — a regra é assinar só com o primeiro nome.")

    if '--status' in sys.argv:
        r = graph('GET', f'/{WABA_NIO}/message_templates?fields=name,status,id,category&limit=200')
        nomes = {t['nome'] for t in linhas}
        for m in r.get('data', []):
            if m['name'] in nomes:
                sql(f"update public.config_templates_waba set status = '{m['status']}', meta_id = '{m['id']}', "
                    f"categoria = '{m['category']}', atualizado_em = now() where nome = '{m['name']}'")
                print(f"{m['name']}: {m['status']} ({m['category']}, id {m['id']})")
        if 'erro' in r:
            print(r)
        return

    for t in linhas:
        if t['meta_id']:
            print(f"{t['nome']}: já submetido (id {t['meta_id']}, {t['status']}) — pulei")
            continue
        if '--enviar' not in sys.argv:
            print(f"[dry-run] {json.dumps(payload(t), ensure_ascii=False)}")
            continue
        r = graph('POST', f'/{WABA_NIO}/message_templates', payload(t))
        if r.get('id'):
            st = r.get('status', 'PENDING')
            st = st if st in ('PENDING', 'APPROVED', 'REJECTED', 'PAUSED', 'DISABLED') else 'PENDING'
            sql(f"update public.config_templates_waba set meta_id = '{r['id']}', status = '{st}', "
                f"categoria = '{r.get('category', t['categoria'])}', atualizado_em = now() where nome = '{t['nome']}'")
        print(f"{t['nome']}: {r}")


if __name__ == '__main__':
    main()
