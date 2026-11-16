#!/usr/bin/env python3
# NIOGEN | scripts/fila_vero_piloto.py | 16/11/2026 — Claude Code (prompt docs/Prompt_fila_vero_piloto100_161126_1640.md)
# PILOTO da Fila Vero: até 100 mensagens HOJE, só até 21h, 1 a cada 20–40 s, pelo número do disparo
# (+55 32 2888-0150, phone_number_id 1124589070738034 — nunca o da Mari, nunca Evolution/chip).
# Público: fila_vero status 'apto', faixa A (endereço confirmado na DFV), Juiz de Fora, celular, sem toque anterior.
#   · nao_instalou/churn → nio_fv_b1 (todos os aptos, contando dentro dos 100)
#   · instalado → 50/50 entre nio_fv_a1 e nio_fv_a2
# Cada envio: fila_vero_registrar_envio (contatos_cliente + fila_vero_mudar → 'enviado'). Falha: fila_vero_registrar_falha
# (131050 → opt_out). Para NA HORA se: qualidade do número diferente de GREEN/UNKNOWN, erro de política/spam/limite
# (368, 131048, 131056, 130472, 80007), 3 falhas seguidas ou 21h.
# Texto livre que chegar no número do disparo recebe 1 resposta curta com o link da Mari (dentro da janela de 24 h).
# Log: só contadores e id da linha — nunca nome ou telefone.
#
# Uso:  python scripts/fila_vero_piloto.py --ensaio     # mostra o plano (quantos de cada template), não envia
#       python scripts/fila_vero_piloto.py --enviar     # dispara
import datetime
import glob
import json
import os
import random
import subprocess
import sys
import time
import urllib.error
import urllib.request

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace', line_buffering=True)
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GRAPH = 'https://graph.facebook.com/v21.0'
PHONE_FILA = '1124589070738034'
TETO = 100
FIM = datetime.time(21, 0)
PARAR_CODIGOS = {'368', '131048', '131056', '130472', '80007', '131031', '132015', '132016'}
TEMPLATE_COD = {'nio_fv_a1': 'A1', 'nio_fv_a2': 'A2', 'nio_fv_b1': 'B1'}


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


def supabase_exe():
    if sys.platform != 'win32':
        return 'supabase'
    c = glob.glob(os.path.expanduser('~/AppData/Local/npm-cache/_npx/*/node_modules/@supabase/cli-windows-x64/bin/supabase.exe'))
    if not c:
        raise SystemExit('supabase.exe não encontrado.')
    return max(c, key=os.path.getmtime)


EXE = supabase_exe()
TOKEN = env_usuario('WABA_NIO_TOKEN')


def sql(q):
    for tentativa in range(3):
        p = subprocess.run([EXE, 'db', 'query', '--remote', '--yes', '-o', 'json', q], cwd=REPO, capture_output=True)
        out = p.stdout.decode('utf-8', 'replace')
        if p.returncode == 0:
            return json.loads(out[out.find('{'):]).get('rows', [])
        time.sleep(3)
    raise RuntimeError(f'sql falhou: {p.stderr.decode("utf-8", "replace")[-300:]}')


def lit(s):
    return "'" + str(s).replace("'", "''") + "'"


def graph(method, path, body=None):
    req = urllib.request.Request(f'{GRAPH}/{path}', method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Authorization': f'Bearer {TOKEN}', 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode())
        except Exception:
            return {'error': {'code': e.code, 'message': 'HTTP'}}


def qualidade():
    r = graph('GET', f'{PHONE_FILA}?fields=quality_rating,status,messaging_limit_tier')
    return r.get('quality_rating'), r.get('status')


def agora():
    return datetime.datetime.now()


def publico():
    # nao_instalou/churn primeiro (todos), o resto com instalado; ordem embaralhada no fim
    rows = sql("""
      select id, codigo, telefone, initcap(lower(split_part(btrim(nome), ' ', 1))) as nome1, lugar, segmento
        from public.fila_vero
       where status = 'apto' and faixa = 'endereco' and cidade like 'JUIZ DE FORA%' and toques = 0
         and lugar is not null and telefone ~ '^55\\d{2}9\\d{8}$'
         and length(split_part(btrim(coalesce(nome, '')), ' ', 1)) >= 2
       order by (segmento = 'instalado'), md5(codigo)
       limit """ + str(TETO))
    a = 0
    for r in rows:
        if r['segmento'] == 'instalado':
            r['template'] = 'nio_fv_a1' if a % 2 == 0 else 'nio_fv_a2'
            a += 1
        else:
            r['template'] = 'nio_fv_b1'
    random.shuffle(rows)
    return rows


def enviar(r):
    corpo = {'messaging_product': 'whatsapp', 'to': r['telefone'], 'type': 'template',
             'template': {'name': r['template'], 'language': {'code': 'pt_BR'}, 'components': [
                 {'type': 'body', 'parameters': [{'type': 'text', 'text': r['nome1']}, {'type': 'text', 'text': r['lugar']}]},
                 {'type': 'button', 'sub_type': 'url', 'index': '0', 'parameters': [{'type': 'text', 'text': r['codigo']}]}]}}
    return graph('POST', f'{PHONE_FILA}/messages', corpo)


def auto_respostas():
    for r in sql('select * from public.fila_vero_auto_respostas()'):
        cod = TEMPLATE_COD.get(r.get('template') or '', 'A1')
        link = f'https://niogen.dharmatelecom.com.br/fv.html?t={cod}&c={r["codigo"]}'
        texto = ('Oi! Quem te atende é a Mari, da nossa equipe, pelo WhatsApp da Nio. Toque no link para falar com ela '
                 f'agora: {link}\nSe não quiser mais receber, responda SAIR.')
        res = graph('POST', f'{PHONE_FILA}/messages', {'messaging_product': 'whatsapp', 'to': r['telefone'], 'type': 'text',
                                                       'text': {'body': texto, 'preview_url': False}})
        if res.get('messages'):
            sql(f'select public.fila_vero_auto_respondida({int(r["id"])})')
            print(f'{agora():%H:%M:%S} auto-resposta enviada (fila {r["id"]})')


def main():
    if not TOKEN:
        raise SystemExit('WABA_NIO_TOKEN ausente.')
    rows = publico()
    plano = {}
    for r in rows:
        plano[r['template']] = plano.get(r['template'], 0) + 1
    q, st = qualidade()
    print(f'{agora():%H:%M:%S} público {len(rows)} · por template {plano} · qualidade {q} · número {st}')
    if '--enviar' not in sys.argv:
        return
    enviados, falhas, seguidas, codigos = 0, 0, 0, {}
    for i, r in enumerate(rows):
        if agora().time() >= FIM:
            print(f'{agora():%H:%M:%S} 21h — parei.'); break
        if enviados >= TETO:
            break
        if i % 10 == 0:
            q, st = qualidade()
            if q not in ('GREEN', 'UNKNOWN', None) or st not in ('CONNECTED', None):
                print(f'{agora():%H:%M:%S} PAREI: qualidade {q} · número {st}'); break
            auto_respostas()
        res = enviar(r)
        if res.get('messages'):
            wamid = res['messages'][0]['id']
            sql(f"select public.fila_vero_registrar_envio({int(r['id'])}, {lit(r['template'])}, {lit(wamid)})")
            enviados += 1
            seguidas = 0
            print(f'{agora():%H:%M:%S} #{enviados} enviado (fila {r["id"]}, {r["template"]})')
        else:
            e = res.get('error', {})
            cod = str(e.get('code', '?'))
            msg = (e.get('error_data', {}) or {}).get('details') or e.get('message', '')
            para = sql(f"select public.fila_vero_registrar_falha({int(r['id'])}, {lit(r['template'])}, {lit(cod)}, {lit(msg[:250])}) p")[0]['p']
            falhas += 1
            seguidas += 1
            codigos[cod] = codigos.get(cod, 0) + 1
            print(f'{agora():%H:%M:%S} FALHA (fila {r["id"]}, {r["template"]}) Meta {cod}: {msg[:160]} → {para}')
            if cod in PARAR_CODIGOS:
                print(f'{agora():%H:%M:%S} PAREI: código {cod} é de política/limite.'); break
            if seguidas >= 3:
                print(f'{agora():%H:%M:%S} PAREI: 3 falhas seguidas.'); break
        time.sleep(random.uniform(20, 40))
    auto_respostas()
    print(f'{agora():%H:%M:%S} FIM · enviados {enviados} · falhas {falhas} {codigos}')
    print(json.dumps(sql('select public.fila_vero_resumo() r')[0]['r'], ensure_ascii=False))


if __name__ == '__main__':
    main()
