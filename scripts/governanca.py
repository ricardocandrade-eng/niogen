# NIOGEN | scripts/governanca.py | 23/11/2026 23:58 — Claude Code / Opus 5.5
# Histórico dos documentos de governança no repo PRIVADO ricardocandrade-eng/niogen-governanca (Ricardo, 23/11/2026:
# "Repo privado separado"). Os arquivos continuam na pasta do Drive — o Cowork, a tarefa agendada do Agente de Tráfego
# e o Code leem lá; a pasta do git fica FORA do Drive (Documents\GitHub\niogen-governanca.git, core.worktree = pasta
# do Drive) para o Drive não corromper o git. Só entram os itens da lista branca (info/exclude do git dir).
# O hook pre-commit barra segredo (scripts/varrer_segredos.py).
#
#   python scripts/governanca.py status               # o que mudou e não foi commitado
#   python scripts/governanca.py commit "mensagem"    # add da lista branca + commit + push
#   python scripts/governanca.py log [n]              # últimos commits
import os
import subprocess
import sys

GIT_DIR = os.environ.get('NIOGEN_GOV_GIT', r'C:\Users\ricar\Documents\GitHub\niogen-governanca.git')
CO_AUTOR = 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'


def git(*args, check=True):
    r = subprocess.run(['git', '--git-dir', GIT_DIR, '-c', 'core.quotepath=false'] + list(args),
                       capture_output=True, text=True, encoding='utf-8')
    if check and r.returncode != 0:
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        raise SystemExit(r.returncode)
    return r


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    if not os.path.isdir(GIT_DIR):
        raise SystemExit('git dir da governança não encontrado: %s (INFRA §2)' % GIT_DIR)
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'status'
    if cmd == 'status':
        out = git('status', '--short').stdout
        print(out.strip() or 'governança: nada a commitar')
    elif cmd == 'commit':
        if len(sys.argv) < 3 or not sys.argv[2].strip():
            raise SystemExit('uso: governanca.py commit "mensagem"')
        git('add', '-A')
        if not git('diff', '--cached', '--name-only').stdout.strip():
            print('governança: nada a commitar')
            return 0
        r = git('commit', '-m', sys.argv[2].strip() + '\n\n' + CO_AUTOR, check=False)
        sys.stdout.write(r.stdout + r.stderr)
        if r.returncode != 0:
            git('reset', '-q')
            print('governança: commit recusado (ver acima) — nada foi commitado')
            return r.returncode
        p = git('push', '-q', 'origin', 'main', check=False)
        if p.returncode != 0:
            print('governança: commit feito, PUSH FALHOU — rode de novo mais tarde:\n' + p.stderr)
            return p.returncode
        print('governança: commit %s com push' % git('log', '--oneline', '-1').stdout.strip())
    elif cmd == 'log':
        n = sys.argv[2] if len(sys.argv) > 2 else '10'
        print(git('log', '--oneline', '-' + n).stdout)
    else:
        raise SystemExit('comandos: status | commit "mensagem" | log [n]')
    return 0


if __name__ == '__main__':
    sys.exit(main())
