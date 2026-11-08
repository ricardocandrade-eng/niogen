# NIOGEN | scripts/publicar_guia.py | 08/11/2026 — Claude Code (docs/Prompt_pendencias_venda_081126_0005.md, Parte 2)
# Publica o Guia do Backoffice no Supabase Nio (tabela conteudos, chave 'guia_backoffice', migration 0065) para a tela guia.html.
# Fonte ÚNICA: o arquivo do Drive docs/BACKOFFICE_chatwoot_com_a_mari_051126_1045.md (o repo é público: o TEXTO nunca entra aqui).
# O script tira o bloco de cabeçalho <!-- … -->, lê a última linha "rev." dele, calcula o sha256 do texto e SÓ PUBLICA SE MUDOU.
# Grava pelo CLI do Supabase (projeto linkado no clone; `db query --remote --yes`) — nenhuma chave em arquivo.
#
# Uso:  python scripts/publicar_guia.py              publica se o texto mudou (idempotente) — todo deploy do front roda isto
#       python scripts/publicar_guia.py --conferir   só compara arquivo × publicado (início de sessão do Code); não grava
#       --arquivo <caminho>                          outro caminho do guia (padrão: variável NIOGEN_GUIA ou o caminho do Drive)
# Saída: 0 = publicado agora ou já igual · 1 = erro · 3 = (--conferir) diferente do publicado
import argparse
import getpass
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NPX = shutil.which('npx.cmd') or shutil.which('npx') or 'npx'
CHAVE = 'guia_backoffice'
PADRAO = os.environ.get('NIOGEN_GUIA') or r'C:\Users\ricar\Meu Drive\Projetos Claude\dharmapro-nio\docs\BACKOFFICE_chatwoot_com_a_mari_051126_1045.md'
# Nada que pareça segredo vai para o banco (o guia é lido por todo usuário logado).
PROIBIDO = [r'sk-ant-[A-Za-z0-9]', r'sb_secret_', r'eyJhbGciOi', r'service_role"\s*:\s*"ey', r'EAA[A-Za-z0-9]{40,}']


def ler_guia(caminho):
    with open(caminho, encoding='utf-8-sig') as f:
        bruto = f.read().replace('\r\n', '\n')
    m = re.match(r'\s*<!--(.*?)-->\s*', bruto, re.S)
    cab = m.group(1) if m else ''
    texto = (bruto[m.end():] if m else bruto).strip() + '\n'
    revs = re.findall(r'rev\.\s*([^\n]+)', cab)
    rev = None
    if revs:
        rev = revs[-1].strip()
        m2 = re.match(r'(\d{2}/\d{2}[^()]*\([^)]*\))', rev)   # "08/11 01:30 (Claude Code): …" → "08/11 01:30 (Claude Code)"
        rev = m2.group(1).strip() if m2 else rev
        rev = rev[:120]
    tit = re.search(r'^#\s+(.+)$', texto, re.M)
    return {
        'markdown': texto, 'rev': rev, 'titulo': (tit.group(1).strip() if tit else 'Guia do Backoffice')[:120],
        'hash': hashlib.sha256(texto.encode('utf-8')).hexdigest(),
    }


def cli(args, sql_arquivo=None):
    cmd = [NPX, 'supabase', 'db', 'query', '--remote'] + args
    if sql_arquivo:
        cmd += ['-f', sql_arquivo]
    r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, encoding='utf-8')
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout or '').strip()[-800:])
    return r.stdout


def publicado():
    out = cli(['--read-only', '-o', 'json', f"select hash, rev, publicado_em from public.conteudos where chave = '{CHAVE}'"])
    linhas = json.loads(out[out.index('{'):]).get('rows') or []
    return linhas[0] if linhas else None


def lit(x):
    if x is None:
        return 'null'
    return "'" + str(x).replace("'", "''") + "'"


def publicar(g):
    tag = 'g' + secrets.token_hex(6)
    while f'${tag}$' in g['markdown']:
        tag = 'g' + secrets.token_hex(6)
    quem = f"{getpass.getuser()} (publicar_guia.py)"
    sql = (f"insert into public.conteudos (chave, titulo, markdown, rev, hash, publicado_em, publicado_por)\n"
           f"values ('{CHAVE}', {lit(g['titulo'])}, ${tag}${g['markdown']}${tag}$, {lit(g['rev'])}, '{g['hash']}', now(), {lit(quem)})\n"
           f"on conflict (chave) do update set titulo = excluded.titulo, markdown = excluded.markdown, rev = excluded.rev,\n"
           f"  hash = excluded.hash, publicado_em = excluded.publicado_em, publicado_por = excluded.publicado_por\n"
           f"  where public.conteudos.hash is distinct from excluded.hash;\n")
    fd, tmp = tempfile.mkstemp(suffix='.sql', prefix='niogen_guia_')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(sql)
        cli(['--yes', '-o', 'json'], tmp)
    finally:
        os.remove(tmp)


def main():
    ap = argparse.ArgumentParser(description='Publica o Guia do Backoffice no NIOGEN (só se mudou).')
    ap.add_argument('--conferir', action='store_true', help='só compara arquivo × publicado, não grava')
    ap.add_argument('--arquivo', default=PADRAO)
    a = ap.parse_args()
    if not os.path.isfile(a.arquivo):
        print(f'ERRO: guia não encontrado em {a.arquivo}')
        return 1
    g = ler_guia(a.arquivo)
    for p in PROIBIDO:
        if re.search(p, g['markdown']):
            print(f'ERRO: o guia tem algo que parece segredo ({p}). Nada foi publicado.')
            return 1
    try:
        atual = publicado()
    except Exception as e:  # noqa: BLE001
        print(f'ERRO ao ler o publicado: {e}')
        return 1
    igual = bool(atual) and atual.get('hash') == g['hash']
    resumo = f"arquivo rev. {g['rev'] or '—'} · {len(g['markdown'])} caracteres · sha256 {g['hash'][:12]}"
    if atual:
        resumo += f" | publicado rev. {atual.get('rev') or '—'} em {str(atual.get('publicado_em'))[:16]} · sha256 {str(atual.get('hash'))[:12]}"
    else:
        resumo += ' | nada publicado ainda'
    if igual:
        print(f'OK: o guia publicado já é igual ao arquivo. {resumo}')
        return 0
    if a.conferir:
        print(f'DIFERENTE: o guia do NIOGEN está desatualizado — rode sem --conferir para publicar. {resumo}')
        return 3
    try:
        publicar(g)
        novo = publicado()
    except Exception as e:  # noqa: BLE001
        print(f'ERRO ao publicar: {e}')
        return 1
    if not novo or novo.get('hash') != g['hash']:
        print('ERRO: publiquei, mas o hash lido de volta não bate.')
        return 1
    print(f"PUBLICADO: guia rev. {g['rev'] or '—'} no NIOGEN ({str(novo.get('publicado_em'))[:16]}). {resumo}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
