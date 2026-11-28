#!/usr/bin/env python
# NIOGEN | scripts/aplicar_migration.py | 17/11/2026 — Claude Code
# Resumo: a ÚNICA porta para subir uma migration na produção (regra de ouro 9: nada sobe sem o portão dos fluxos verde).
#   1) Trava: exige uma rodada do portão (tests/fluxos/portao.py) COMPLETA, APROVADA (nenhum cenário "atual" vermelho),
#      feita COM esta migration (mesmo sha256) nas últimas 6 h — lida de ~/niogen_sim/resultados/portao_*.json.
#   2) Ensaio na produção: roda o arquivo com o "commit;" final trocado por "rollback;" (transação desfeita).
#   3) Só então aplica de verdade.
#   4) Registra a migration em supabase_migrations.schema_migrations (28/11/2026): versão, nome e o texto do arquivo — é o
#      que o banco e o painel do Supabase mostram como "migrations aplicadas". Se o registro falhar, a migration JÁ ESTÁ
#      aplicada: o script avisa e diz o comando para registrar depois (scripts/registrar_migrations.py). Número repetido
#      (outro arquivo já registrado com o mesmo NNNN) também só avisa — a chave da tabela é a versão.
#
# Uso:  python scripts/aplicar_migration.py supabase/migrations/0250_x.sql
#       python scripts/aplicar_migration.py supabase/migrations/0250_x.sql --so-ensaio      # só o passo 2 (não precisa de portão)
#       python scripts/aplicar_migration.py supabase/migrations/0250_x.sql --sem-portao "motivo"   # emergência: pula o passo 1,
#             grava o motivo em ~/niogen_sim/resultados/sem_portao.log e avisa — vira pendência (regra 17).
# A migration precisa começar com "begin;" e terminar com "commit;".
import datetime, hashlib, json, pathlib, re, shutil, subprocess, sys, tempfile

PORTAO_HORAS = 6
RAIZ = pathlib.Path(__file__).resolve().parent.parent
RES = pathlib.Path.home() / 'niogen_sim' / 'resultados'


def sha(arq):
    return hashlib.sha256(pathlib.Path(arq).read_bytes().replace(b'\r\n', b'\n')).hexdigest()


def supabase(arq):
    npx = shutil.which('npx') or shutil.which('npx.cmd')
    if not npx:
        sys.exit('npx não encontrado.')
    r = subprocess.run([npx, '--yes', 'supabase@3.0.0', 'db', 'query', '--remote', '--yes', '-f', str(arq)],
                       cwd=RAIZ, capture_output=True, text=True, encoding='utf-8', errors='replace')
    return r.returncode, (r.stdout + '\n' + r.stderr).strip()


def sql_registro(arq, texto):
    """SQL que grava a linha da migration no registro do banco; devolve (número, nome, sql) ou None se o nome foge do padrão."""
    m = re.match(r'^(\d{4})_(.+)\.sql$', arq.name)
    if not m:
        return None
    num, nome = m.group(1), m.group(2)
    tag = '$reg$'
    while tag in texto:
        tag = tag[:-1] + 'x$'
    return num, nome, ('begin;\n'
                       'insert into supabase_migrations.schema_migrations (version, name, statements)\n'
                       f"values ('{num}', '{nome}', array[{tag}{texto}{tag}]::text[])\n"
                       'on conflict (version) do nothing;\n'
                       'commit;\n'
                       f"select name as registrada_como from supabase_migrations.schema_migrations where version = '{num}';\n")


def registrar(arq, texto):
    """Grava a linha da migration no registro do banco. Devolve (ok, aviso)."""
    r = sql_registro(arq, texto)
    if not r:
        return False, 'nome fora do padrão NNNN_nome.sql — não registrada'
    num, nome, sql = r
    with tempfile.NamedTemporaryFile('w', suffix='.sql', delete=False, encoding='utf-8', newline='\n') as t:
        t.write(sql)
    rc, out = supabase(t.name)
    pathlib.Path(t.name).unlink(missing_ok=True)
    if rc or '"_tag":"Error"' in out:
        return False, 'o registro falhou: ' + out[-600:]
    if f'"{nome}"' not in out:
        return False, f'o número {num} já estava registrado com outro nome (número repetido) — esta não entrou no registro'
    return True, f'{num} · {nome}'


def portao_ok(arq):
    h, nome = sha(arq), arq.name
    limite = datetime.datetime.now() - datetime.timedelta(hours=PORTAO_HORAS)
    ultima = None
    for f in sorted(RES.glob('portao_*.json'), key=lambda p: p.stat().st_mtime, reverse=True):
        try:
            d = json.loads(f.read_text(encoding='utf-8'))
        except Exception:
            continue
        if d.get('migrations', {}).get(nome) != h:
            continue
        ultima = ultima or (f, d)
        if d.get('aprovado') and datetime.datetime.fromisoformat(d['quando']) > limite:
            return f, d
    if ultima:
        f, d = ultima
        motivo = ('rodada parcial' if not d.get('completa') else
                  'cenários atuais vermelhos: ' + ', '.join(d.get('atuais_vermelhos', [])) if not d.get('aprovado') else
                  f'mais velha que {PORTAO_HORAS} h ({d["quando"]})')
        sys.exit(f'PORTÃO FECHADO — {nome} não subiu. Última rodada com este arquivo ({f.name}): {motivo}.\n'
                 f'  Rode: python tests/fluxos/portao.py {arq.relative_to(RAIZ).as_posix()}')
    sys.exit(f'PORTÃO FECHADO — {nome} não subiu: nenhuma rodada do portão com esta versão do arquivo (sha {h[:12]}).\n'
             f'  Rode: python tests/fluxos/portao.py {arq.relative_to(RAIZ).as_posix()}')


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    alvo = [a for a in sys.argv[1:] if a.endswith('.sql')]
    if len(alvo) != 1:
        sys.exit(__doc__ or 'Uso: python scripts/aplicar_migration.py supabase/migrations/NNNN_x.sql')
    arq = pathlib.Path(alvo[0]).resolve()
    if arq.parent != RAIZ / 'supabase' / 'migrations' or not arq.exists():
        sys.exit('Só migrations de supabase/migrations/.')
    texto = arq.read_text(encoding='utf-8')
    corpo = re.sub(r'(?m)^\s*--.*$', '', texto).strip()
    if not re.match(r'(?is)^begin\s*;', corpo) or not re.search(r'(?is)commit\s*;\s*$', corpo):
        sys.exit('A migration precisa começar com "begin;" e terminar com "commit;".')

    so_ensaio = '--so-ensaio' in sys.argv
    motivo = None
    if '--sem-portao' in sys.argv:
        i = sys.argv.index('--sem-portao')
        motivo = sys.argv[i + 1].strip() if i + 1 < len(sys.argv) else ''
        if len(motivo) < 10:
            sys.exit('--sem-portao precisa de um motivo entre aspas.')
    if not so_ensaio:
        if motivo:
            RES.mkdir(parents=True, exist_ok=True)
            with open(RES / 'sem_portao.log', 'a', encoding='utf-8') as g:
                g.write(f'{datetime.datetime.now().isoformat(timespec="seconds")}\t{arq.name}\t{sha(arq)[:12]}\t{motivo}\n')
            print(f'⚠️  PORTÃO PULADO (--sem-portao): {motivo} — avise o Ricardo e registre a pendência.')
        else:
            f, d = portao_ok(arq)
            print(f'portão aberto: {f.name} · {d["verdes"]}/{d["total"]} verdes · cópia de {d.get("copia_de")}')

    # ensaio: transação desfeita na produção
    i = texto.lower().rfind('commit;')
    with tempfile.NamedTemporaryFile('w', suffix='.sql', delete=False, encoding='utf-8', newline='') as t:
        t.write(texto[:i] + 'rollback;' + texto[i + len('commit;'):])
    rc, out = supabase(t.name)
    pathlib.Path(t.name).unlink(missing_ok=True)
    if rc:
        sys.exit(f'ENSAIO FALHOU na produção (nada mudou):\n{out[-2000:]}')
    print('ensaio ok (transação desfeita na produção)')
    if so_ensaio:
        return

    rc, out = supabase(arq)
    if rc:
        sys.exit(f'APLICAÇÃO FALHOU:\n{out[-2000:]}')
    print(f'APLICADA: {arq.name}')
    ok, aviso = registrar(arq, texto.replace('\r\n', '\n'))
    if ok:
        print(f'registrada em schema_migrations: {aviso}')
    else:
        print(f'⚠️  APLICADA, MAS NÃO REGISTRADA — {aviso}\n'
              f'    A migration está no ar. Para registrar depois: python scripts/registrar_migrations.py --ate {arq.name[:4]} --aplicar '
              '(com --fora para as que não subiram).')


if __name__ == '__main__':
    main()
