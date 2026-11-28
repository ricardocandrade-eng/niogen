#!/usr/bin/env python
# NIOGEN | scripts/registrar_migrations.py | 28/11/2026 — Claude Code
# Resumo: o banco registra as migrations aplicadas em supabase_migrations.schema_migrations, mas só até a 0249:
# desde a 0250 elas sobem por scripts/aplicar_migration.py (db query -f), que aplica e não registra. Este script
# escreve o SQL que registra as que faltam (version, name, statements = o texto do arquivo) e, só com --aplicar,
# roda esse SQL na produção. Não reaplica migration nenhuma: grava apenas a linha do registro.
#
# Uso:  python scripts/registrar_migrations.py --ate 0437 --fora 0420            # só escreve o SQL e mostra o resumo
#       python scripts/registrar_migrations.py --ate 0437 --fora 0420 --saida x.sql
#       python scripts/registrar_migrations.py --ate 0437 --fora 0420 --aplicar  # grava na produção (pede o OK do Ricardo antes)
#   --ate NNNN   última migration que JÁ ESTÁ na produção (obrigatório: quem roda afirma isso, o script não adivinha)
#   --fora A,B   números que NÃO estão na produção (ficam sem registro)
#   --par NNNN=nome_do_arquivo_sem_numero   escolhe qual arquivo fica com o número quando há dois com o mesmo
#
# Números repetidos (dois arquivos com o mesmo NNNN): a chave da tabela é a versão, só cabe uma linha por número.
# Sem --par para aquele número, o script NÃO registra nenhum dos dois e avisa — a escolha (ou renumerar um deles) é decisão.
# Seguro para rodar de novo: "on conflict (version) do nothing".
import pathlib, re, shutil, subprocess, sys, tempfile

RAIZ = pathlib.Path(__file__).resolve().parent.parent
MIG = RAIZ / 'supabase' / 'migrations'
PRIMEIRA = 250   # até a 0249 o registro existe


def arg(nome, padrao=None):
    if nome in sys.argv:
        i = sys.argv.index(nome)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return padrao


def dolar(texto, n):
    tag = f'$mig{n}$'
    while tag in texto:
        tag = tag[:-1] + 'x$'
    return f'{tag}{texto}{tag}'


def montar(ate, fora, pares):
    por_num = {}
    for f in sorted(MIG.glob('*.sql')):
        m = re.match(r'^(\d{4})_(.+)\.sql$', f.name)
        if m:
            por_num.setdefault(m.group(1), []).append((m.group(2), f))
    linhas, pulados, repetidos = [], [], []
    for num in sorted(por_num):
        n = int(num)
        if n < PRIMEIRA or n > ate:
            continue
        if num in fora:
            pulados.append(num)
            continue
        arqs = por_num[num]
        if len(arqs) > 1:
            escolha = [a for a in arqs if a[0] == pares.get(num)]
            if not escolha:
                repetidos.append((num, [a[0] for a in arqs]))
                continue
            arqs = escolha
        nome, f = arqs[0]
        texto = f.read_text(encoding='utf-8').replace('\r\n', '\n')
        linhas.append((num, nome, texto))
    return linhas, pulados, repetidos, por_num


LOTE_KB = 300   # tamanho de cada pedido à API, em KB de texto de migration


def sql_de(linhas):
    partes = ['begin;',
              "do $chk$ begin\n"
              "  if not exists (select 1 from supabase_migrations.schema_migrations where version = '0249') then\n"
              "    raise exception 'registro inesperado: a 0249 não está em schema_migrations';\n"
              "  end if;\nend $chk$;"]
    for i, (num, nome, texto) in enumerate(linhas):
        partes.append('insert into supabase_migrations.schema_migrations (version, name, statements)\n'
                      f"values ('{num}', '{nome}', array[{dolar(texto, i)}]::text[])\n"
                      'on conflict (version) do nothing;')
    partes.append('commit;')
    partes.append("select count(*) as registradas, max(version) as ultima from supabase_migrations.schema_migrations;")
    return '\n\n'.join(partes) + '\n'


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    ate = arg('--ate')
    if not ate or not ate.isdigit():
        sys.exit('Diga até qual migration a produção já tem: --ate NNNN')
    fora = {x.strip().zfill(4) for x in (arg('--fora', '') or '').split(',') if x.strip()}
    pares = {}
    for i, a in enumerate(sys.argv):
        if a == '--par' and i + 1 < len(sys.argv) and '=' in sys.argv[i + 1]:
            k, v = sys.argv[i + 1].split('=', 1)
            pares[k.zfill(4)] = v
    linhas, pulados, repetidos, por_num = montar(int(ate), fora, pares)
    faltam_no_repo = [f'{n:04d}' for n in range(PRIMEIRA, int(ate) + 1) if f'{n:04d}' not in por_num]
    sql = sql_de(linhas)
    saida = pathlib.Path(arg('--saida') or (pathlib.Path(tempfile.gettempdir()) / 'registrar_migrations.sql'))
    saida.write_text(sql, encoding='utf-8', newline='\n')
    print(f'{len(linhas)} migration(s) a registrar: {linhas[0][0]} … {linhas[-1][0]}' if linhas else 'nada a registrar')
    print(f'fora (não estão na produção): {", ".join(sorted(pulados)) or "nenhuma"}')
    print(f'números sem arquivo no repo (pulados na numeração): {", ".join(faltam_no_repo) or "nenhum"}')
    for num, nomes in repetidos:
        print(f'NÚMERO REPETIDO {num}: {" · ".join(nomes)} — nenhum registrado (use --par {num}=<nome> ou renumere um)')
    print(f'SQL em {saida} ({len(sql) // 1024} KB)')
    if '--aplicar' not in sys.argv:
        print('Nada foi gravado. Para gravar na produção: repita com --aplicar (só com o OK do Ricardo).')
        return
    npx = shutil.which('npx') or shutil.which('npx.cmd')
    if not npx:
        sys.exit('npx não encontrado.')
    # Em lotes: a API recusa pedido grande ("413 request entity too large" com o arquivo inteiro, 3,7 MB, em 28/11/2026).
    # Cada lote é uma transação; "on conflict do nothing" deixa repetir sem risco se um lote falhar no meio.
    lotes, atual, tam = [], [], 0
    for l in linhas:
        if atual and tam + len(l[2]) > LOTE_KB * 1024:
            lotes.append(atual)
            atual, tam = [], 0
        atual.append(l)
        tam += len(l[2])
    if atual:
        lotes.append(atual)
    for n, lote in enumerate(lotes, 1):
        arq = saida.with_name(f'{saida.stem}_lote{n:02d}.sql')
        arq.write_text(sql_de(lote), encoding='utf-8', newline='\n')
        r = subprocess.run([npx, '--yes', 'supabase@3.0.0', 'db', 'query', '--remote', '--yes', '-f', str(arq)],
                           cwd=RAIZ, capture_output=True, text=True, encoding='utf-8', errors='replace')
        fim = (r.stdout + '\n' + r.stderr).strip()
        if r.returncode != 0 or '"_tag":"Error"' in fim:
            print(fim[-1500:])
            sys.exit(f'PAROU no lote {n} de {len(lotes)} ({lote[0][0]} … {lote[-1][0]}). Os lotes anteriores ficaram gravados; repetir é seguro.')
        print(f'lote {n} de {len(lotes)} gravado: {lote[0][0]} … {lote[-1][0]} ({len(lote)})', flush=True)


if __name__ == '__main__':
    main()
