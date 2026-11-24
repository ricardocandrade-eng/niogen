# NIOGEN | scripts/varrer_segredos.py | 23/11/2026 23:55 — Claude Code / Opus 5.5
# Portão contra segredo do repo privado niogen-governanca (hook pre-commit). Recusa o commit se algum arquivo
# preparado (staged) tiver token, chave ou senha com valor. Prompt: docs/Prompt_governanca_retrato_registro_231126_2320.md
# (Parte C reduzida a segredo, porque o Ricardo escolheu repo privado em 23/11/2026).
#
#   python scripts/varrer_segredos.py --git-dir <dir>      # usado pelo hook: varre o que está preparado
#   python scripts/varrer_segredos.py arquivo [arquivo…]   # varre arquivos soltos (teste)
# Nunca imprime o valor encontrado: só arquivo, linha, tipo e os 4 primeiros caracteres.
import argparse
import re
import subprocess
import sys

PADROES = [
    ('token da Meta', re.compile(r'\bEAA[A-Za-z0-9]{30,}')),
    ('chave Anthropic', re.compile(r'\bsk-ant-[A-Za-z0-9_-]{20,}')),
    ('chave sk-', re.compile(r'\bsk-(?:proj-)?[A-Za-z0-9]{32,}')),
    ('token do GitHub', re.compile(r'\bgh[pousr]_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{30,}')),
    ('JWT (chave Supabase, sessão)', re.compile(r'\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}')),
    ('chave secreta Supabase', re.compile(r'\bsb_secret_[A-Za-z0-9_-]{20,}')),
    ('chave Google', re.compile(r'\bAIza[0-9A-Za-z_-]{35}')),
    ('chave privada', re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----')),
    ('senha/segredo com valor', re.compile(
        r'(?i)\b(senha|password|passwd|secret|api[_-]?key|token)\b\s*[:=]\s*[`\'"]?(?=[^\s`\'"]*\d)(?=[^\s`\'"]*[A-Za-z])[A-Za-z0-9!@#$%^&+/=-]{12,}')),
]


def varrer_texto(nome, texto):
    achados = []
    for n, linha in enumerate(texto.split('\n'), 1):
        for tipo, rx in PADROES:
            m = rx.search(linha)
            if m:
                achados.append('%s:%d: %s (%s…)' % (nome, n, tipo, m.group(0)[:4]))
    return achados


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--git-dir')
    ap.add_argument('arquivos', nargs='*')
    a = ap.parse_args()
    sys.stdout.reconfigure(encoding='utf-8')
    achados = []
    if a.git_dir:
        git = ['git', '--git-dir', a.git_dir]
        nomes = subprocess.run(git + ['diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z'],
                               capture_output=True, check=True).stdout.decode('utf-8').split('\0')
        for nome in [x for x in nomes if x]:
            blob = subprocess.run(git + ['show', ':' + nome], capture_output=True, check=True).stdout
            achados += varrer_texto(nome, blob.decode('utf-8', 'replace'))
    for arq in a.arquivos:
        with open(arq, encoding='utf-8', errors='replace') as f:
            achados += varrer_texto(arq, f.read())
    if achados:
        print('PORTÃO: commit recusado — segredo no texto (tire o valor, deixe só o nome da variável e onde ela vive — regra 5):')
        for x in achados[:50]:
            print('  ' + x)
        return 1
    print('portão contra segredo: nada encontrado')
    return 0


if __name__ == '__main__':
    sys.exit(main())
