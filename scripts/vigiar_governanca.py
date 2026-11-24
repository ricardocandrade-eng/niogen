# NIOGEN | scripts/vigiar_governanca.py | 23/11/2026 23:40 — Claude Code / Opus 5.5
# Vigia da governança (só leitura). Prompt: docs/Prompt_governanca_retrato_registro_231126_2320.md, Parte A5 (pasta do Drive).
# O Diário é RETRATO (editado no lugar, uma "Última atualização" só) e o REGISTRO é linha acrescentada no fim de
# diario/AAAA-Sww.md. Este script não move nada: avisa o que saiu do formato, para a sessão corrigir.
#
#   python scripts/vigiar_governanca.py            # relata; sai 0 mesmo com aviso
#   python scripts/vigiar_governanca.py --estrito  # sai 1 se houver aviso
import argparse
import datetime as dt
import os
import re
import sys

PASTA_PADRAO = r'C:\Users\ricar\Meu Drive\Projetos Claude\dharmapro-nio'
DIARIO = 'ESTADO ATUAL — Diário de Bordo.md'
CAIXA = 'Diário — caixa de entrada do Cowork.md'
INFRA = 'INFRA.md'
DIARIO_MAX_KB = 15
SECAO_REGISTRO = '## Registro'

RE_ULTIMA = re.compile(r'^>?\s*Última atualização:')
RE_ANTERIOR = re.compile(r'^>?\s*Anterior:')
RE_INFRA_LOG = re.compile(r'^>\s*(Revisão anterior|Revisão|Anterior):')
RE_REGISTRO = re.compile(r'^- \*\*(\d{2})/(\d{2}) (\d{1,2})h(\d{2}) \((.+)')


def ler(caminho):
    with open(caminho, encoding='utf-8', newline='') as f:
        return f.read()


def semana(d):
    a, s, _ = d.isocalendar()
    return '%d-S%02d' % (a, s)


def vigiar(pasta, hoje):
    avisos = []
    ok = []

    # 1. Diário = retrato
    p = os.path.join(pasta, DIARIO)
    tx = ler(p)
    ls = tx.split('\n')
    kb = len(tx.encode('utf-8')) / 1024
    ult = [i + 1 for i, t in enumerate(ls) if RE_ULTIMA.match(t)]
    ant = [i + 1 for i, t in enumerate(ls) if RE_ANTERIOR.match(t)]
    if len(ult) != 1:
        avisos.append('Diário: %d linhas "Última atualização" (tem de ser 1) — linhas %s' % (len(ult), ult[:10]))
    if ant:
        avisos.append('Diário: %d linha(s) de registro "Anterior:" (linhas %s) — registro vai para o fim de diario/%s.md'
                      % (len(ant), ant[:10], semana(hoje)))
    if kb > DIARIO_MAX_KB:
        avisos.append('Diário: %.0f KB (limite %d KB) — o retrato está virando log' % (kb, DIARIO_MAX_KB))
    if len(ult) == 1 and not ant and kb <= DIARIO_MAX_KB:
        ok.append('Diário: retrato com 1 "Última atualização", %.0f KB' % kb)

    # 2. Caixa do Cowork aposentada: nada além do cabeçalho
    pc = os.path.join(pasta, CAIXA)
    if os.path.exists(pc):
        lc = ler(pc).split('\n')
        try:
            ini = lc.index('<!-- entradas abaixo desta linha -->') + 1
        except ValueError:
            ini = len(lc)
        resto = [t for t in lc[ini:] if t.strip() and not t.startswith('_(')]
        if resto:
            avisos.append('Caixa do Cowork (aposentada): %d linha(s) escrita(s) — passar para o fim de diario/%s.md. 1ª: %s'
                          % (len(resto), semana(hoje), resto[0][:90]))
        else:
            ok.append('Caixa do Cowork: vazia')

    # 3. Registro da semana: no fim, em ordem, com hora e quem
    pw = os.path.join(pasta, 'diario', semana(hoje) + '.md')
    if not os.path.exists(pw):
        avisos.append('Registro: diario/%s.md não existe (nasce na 1ª mudança da semana, com o cabeçalho da regra 4)' % semana(hoje))
    else:
        lw = ler(pw).split('\n')
        try:
            sec = next(i for i, t in enumerate(lw) if t.startswith(SECAO_REGISTRO))
        except StopIteration:
            sec = None
            avisos.append('Registro: diario/%s.md sem a seção "%s (mais antigo em cima, mais novo embaixo)"' % (semana(hoje), SECAO_REGISTRO))
        if sec is not None:
            fim = next((i for i in range(sec + 1, len(lw)) if lw[i].startswith('## ')), len(lw))
            ano = int(semana(hoje)[:4])
            anterior = None
            n = 0
            for i in range(sec + 1, fim):
                t = lw[i]
                if not t.strip() or t.startswith('>') or t.startswith('  '):
                    continue  # vazio, nota da seção ou continuação indentada
                m = RE_REGISTRO.match(t)
                if not m:
                    avisos.append('Registro %s linha %d fora do formato "- **DD/MM HHhMM (quem…)** — …": %s'
                                  % (semana(hoje), i + 1, t[:90]))
                    continue
                n += 1
                try:
                    quando = dt.datetime(ano, int(m.group(2)), int(m.group(1)), int(m.group(3)), int(m.group(4)))
                except ValueError:
                    avisos.append('Registro %s linha %d: data/hora inválida' % (semana(hoje), i + 1))
                    continue
                if anterior and quando < anterior:
                    avisos.append('Registro %s linha %d fora de ordem (%s depois de %s) — a nova vai sempre embaixo'
                                  % (semana(hoje), i + 1, quando.strftime('%d/%m %Hh%M'), anterior.strftime('%d/%m %Hh%M')))
                anterior = max(anterior, quando) if anterior else quando
            ok.append('Registro: diario/%s.md com %d linha(s) no formato' % (semana(hoje), n))

    # 4. INFRA: uma linha de log no cabeçalho
    pi = os.path.join(pasta, INFRA)
    li = ler(pi).split('\n')
    sec1 = next((i for i, t in enumerate(li) if t.startswith('## ')), len(li))
    logs = [t for t in li[:sec1] if RE_INFRA_LOG.match(t)]
    if len(logs) > 1:
        avisos.append('INFRA: %d linhas de log no cabeçalho (tem de ser 1 "> Revisão:", sobrescrita) — o histórico é o registro da semana'
                      % len(logs))
    else:
        ok.append('INFRA: cabeçalho com %d linha de log' % len(logs))

    # 5. Cópias de conflito do Drive
    conflitos = []
    for raiz, dirs, arqs in os.walk(pasta):
        dirs[:] = [d for d in dirs if not d.startswith('.') and d not in ('node_modules', 'backups')]
        conflitos += [os.path.relpath(os.path.join(raiz, a), pasta) for a in arqs if re.search(r' \(\d+\)\.md$', a)]
    if conflitos:
        avisos.append('Cópias de conflito do Drive: %s — comparar com o original e tirar da pasta' % ', '.join(conflitos[:6]))
    else:
        ok.append('Sem cópias de conflito (* (1).md)')
    return avisos, ok


def main():
    ap = argparse.ArgumentParser(description='Vigia da governança (só leitura).')
    ap.add_argument('--pasta', default=os.environ.get('NIOGEN_PASTA', PASTA_PADRAO))
    ap.add_argument('--hoje', help='DD/MM/AAAA (teste)')
    ap.add_argument('--estrito', action='store_true', help='sai 1 se houver aviso')
    a = ap.parse_args()
    sys.stdout.reconfigure(encoding='utf-8')
    hoje = dt.datetime.strptime(a.hoje, '%d/%m/%Y').date() if a.hoje else dt.date.today()
    avisos, ok = vigiar(a.pasta, hoje)
    print('vigiar_governanca — %s — %s' % (hoje.strftime('%d/%m/%Y'), 'TUDO CERTO' if not avisos else '%d AVISO(S)' % len(avisos)))
    for x in ok:
        print('  ok  ' + x)
    for x in avisos:
        print('  !!  ' + x)
    return 1 if (avisos and a.estrito) else 0


if __name__ == '__main__':
    sys.exit(main())
