#!/usr/bin/env python
# NIOGEN | tests/fluxos/portao.py | 17/11/2026 — Claude Code
# Resumo: o PORTÃO DOS FLUXOS. Roda cada cenário de tests/fluxos/cenarios/*.sql numa cópia descartável do banco local
# (montada por tests/fluxos/copia_local.sh), com o simulador de tests/fluxos/sim.sql, e diz o que passou e o que falhou.
# Não abre conexão com a produção. Regra de ouro 9: nada que toca estado sobe sem esta bateria verde.
#
# Uso:  python tests/fluxos/portao.py            # todos os cenários
#       python tests/fluxos/portao.py A1 C8      # só esses
#       python tests/fluxos/portao.py --trilha C8   # mostra o passo a passo do cenário
#       python tests/fluxos/portao.py --manter C8   # deixa o banco do cenário (niogen_cenario) de pé para investigar
#       python tests/fluxos/portao.py supabase/migrations/0250_x.sql   # roda tudo COM a migration aplicada por cima da cópia
# A TRAVA (regra de ouro 9): scripts/aplicar_migration.py só sobe uma migration na produção se houver aqui uma rodada completa,
# com aquela migration (mesmo sha256), sem nenhum cenário "atual" vermelho, nas últimas PORTAO_HORAS horas.
# Cenário "regra_nova" vermelho não barra (é decisão ainda não construída); ao ficar verde, troque o tipo para "atual".
# Saída: tabela no terminal + ~/niogen_sim/resultados/portao_<data>.json (fora do repo e do Drive).
#
# A TRAVA DA CÓPIA (19/11/2026): só UMA rodada por vez nesta máquina. Todas usam os mesmos bancos (niogen_sim, niogen_teste,
# niogen_cenario, porta 54329) — duas ao mesmo tempo apagam o banco uma da outra ("template database niogen_teste does not
# exist", "duplicate key … pg_database_datname_index"). Ao começar, o portão cria ~/niogen_sim/portao.lock (criação atômica,
# com PID, hora e comando). Se ela já existe e o PID está vivo, ele ESPERA, avisando "esperando a rodada de <pid>, começada
# às HH:MM", até PORTAO_ESPERA_MIN minutos (padrão 60; depois desiste com erro). Trava de PID que não existe mais (rodada
# morta à força) é apagada sozinha. A trava some ao terminar, com erro ou com Ctrl+C. tests/fluxos/copia_local.sh usa a
# MESMA trava (não remonta a cópia no meio de uma rodada, e o portão espera a cópia ficar pronta). Cópia deste script em
# scratchpad (ex.: portao_r.py) feita antes de 19/11 NÃO respeita a trava: recopie, ou rode este.
#
# Cada cenário é um .sql com cabeçalho:
#   -- id: C8
#   -- titulo: Time devolve para a Mari
#   -- tipo: atual | regra_nova      (atual = já deveria funcionar hoje · regra_nova = decisão de 17/11 ainda não construída)
# e passos que chamam sim.* e as funções de verdade. No fim o portão confere as regras gerais (sim.invariantes) em toda
# conversa do cenário.
import atexit, ctypes, hashlib, json, os, re, socket, subprocess, sys, datetime, pathlib, time

AQUI = pathlib.Path(__file__).resolve().parent
BIN = pathlib.Path(os.environ.get('PG_SERVER_BIN', pathlib.Path.home() / 'tools/pgsql17_server/pgsql/bin'))
SIM = pathlib.Path(os.environ.get('NIOGEN_SIM_DIR', pathlib.Path.home() / 'niogen_sim'))
BASE, TESTE, CEN, PORTA = 'niogen_sim', 'niogen_teste', 'niogen_cenario', '54329'
PORTAO_HORAS = 6
# Regras gerais que o desenho de hoje quebra de propósito (a conversa de quem saiu fica "ativa" para a Mari responder se ele
# voltar). Aparecem no relatório, mas não deixam o cenário vermelho — viram bloqueio quando a situação única existir.
AVISOS = {'S4', 'R9', 'R10', 'R14'}   # R14 (0293): situação gravada × calculada — aviso enquanto a gravada está em sombra
#   # R9/R10: divergência da sombra (passo 4) — viram bloqueio quando a situação mandar (passo 5)
PSQL = [str(BIN / 'psql.exe'), '-h', '127.0.0.1', '-p', PORTA, '-U', 'postgres', '-X', '-q', '-At']

# No fim de todo cenário: 20 minutos sem ninguém fazer nada (para as ordens agendadas e as varreduras rodarem) e as regras gerais.
FIM = r"""
select sim.como('servico');
select sim.espera(c.id, '20 minutes') from public.mari_conversas c where c.chatwoot_conversation_id in (select conv from sim.cw);
select sim.invariantes(c.id) from public.mari_conversas c where c.chatwoot_conversation_id in (select conv from sim.cw);
"""
DESPEJO = r"""
select jsonb_build_object(
  'checagens', coalesce((select jsonb_agg(jsonb_build_object('tipo', tipo, 'nome', nome, 'ok', ok, 'detalhe', detalhe) order by n) from sim.checagens), '[]'::jsonb),
  'trilha', coalesce((select jsonb_agg(quem || ': ' || o_que order by n) from sim.trilha), '[]'::jsonb));
"""


def psql(db, sql=None, arquivo=None, parar=True):
    cmd = PSQL + ['-d', db] + (['-v', 'ON_ERROR_STOP=1'] if parar else [])
    if arquivo:
        cmd += ['-f', str(arquivo)]
    else:
        cmd += ['-c', sql]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace',
                       env={**os.environ, 'PGCLIENTENCODING': 'UTF8'})   # sem isto o Windows lê os .sql como WIN1252
    return r.returncode, r.stdout, r.stderr


def cabecalho(texto):
    d = {}
    for l in texto.splitlines()[:12]:
        m = re.match(r'--\s*(id|titulo|tipo|regra)\s*:\s*(.+)', l)
        if m:
            d[m.group(1)] = m.group(2).strip()
    return d


def sha(arq):
    return hashlib.sha256(pathlib.Path(arq).read_bytes().replace(b'\r\n', b'\n')).hexdigest()


def rodar(arq, modelo):
    texto = arq.read_text(encoding='utf-8')
    cab = cabecalho(texto)
    psql('postgres', f'drop database if exists {CEN} with (force)')
    rc, _, err = psql('postgres', f'create database {CEN} template {modelo} strategy file_copy')
    if rc:
        sys.exit('Não consegui clonar a cópia local: ' + err.strip() + '\nRode antes: tests/fluxos/copia_local.sh')
    tmp = SIM / 'cenario_atual.sql'
    tmp.write_text("set client_min_messages = warning;\nselect sim.como('servico');\n" + texto + '\n' + FIM, encoding='utf-8')
    rc, out, err = psql(CEN, arquivo=tmp)
    erro = None
    if rc:
        erro = next((l for l in err.splitlines() if 'ERROR' in l or 'ERRO' in l), err.strip()[:300])
        erro = re.sub(r'^psql:[^ ]+ ', '', erro)
    _, out2, _ = psql(CEN, DESPEJO, parar=False)
    try:
        d = json.loads(out2.strip().splitlines()[-1])
    except Exception:
        d = {'checagens': [], 'trilha': []}
    return {'id': cab.get('id', arq.stem), 'titulo': cab.get('titulo', ''), 'tipo': cab.get('tipo', 'atual'),
            'erro': erro, 'checagens': d['checagens'], 'trilha': d['trilha']}


TRAVA = SIM / 'portao.lock'
ESPERA_MIN = float(os.environ.get('PORTAO_ESPERA_MIN', '60'))


def pid_vivo(pid):
    """No Windows os.kill(pid, 0) MATA o processo — por isso OpenProcess + GetExitCodeProcess."""
    if pid <= 0:
        return False
    if os.name != 'nt':
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
    k = ctypes.windll.kernel32
    h = k.OpenProcess(0x1000, False, pid)   # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return k.GetLastError() == 5         # acesso negado = o processo existe
    try:
        codigo = ctypes.c_ulong()
        return bool(k.GetExitCodeProcess(h, ctypes.byref(codigo))) and codigo.value == 259   # STILL_ACTIVE
    finally:
        k.CloseHandle(h)


def ler_trava():
    try:
        d = dict(l.split('=', 1) for l in TRAVA.read_text(encoding='utf-8').splitlines() if '=' in l)
        d['pid'] = int(d.get('pid', '0'))
        return d
    except FileNotFoundError:
        return None
    except Exception:
        return {'pid': 0}   # ilegível (meio escrita ou estragada): vira velha se continuar assim por 10 s


def pegar_trava():
    """Cria a trava (atômico: O_EXCL) ou espera a rodada que está com ela. Ver o cabeçalho."""
    SIM.mkdir(parents=True, exist_ok=True)
    conteudo = (f"pid={os.getpid()}\nhost={socket.gethostname()}\ninicio={datetime.datetime.now().isoformat(timespec='seconds')}\n"
                f"quem=portao.py {' '.join(sys.argv[1:])}\n")
    limite = time.monotonic() + ESPERA_MIN * 60
    avisado, avisado_em, ilegivel_desde = None, 0.0, None
    while True:
        try:
            fd = os.open(TRAVA, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            d = ler_trava()
            if d is None:
                continue                                               # sumiu entre o open e a leitura: tenta de novo
            if 'inicio' not in d:
                ilegivel_desde = ilegivel_desde or time.monotonic()
                velha = time.monotonic() - ilegivel_desde > 10         # 10 s para quem está escrevendo terminar
            else:
                ilegivel_desde = None
                velha = d.get('host', socket.gethostname()) == socket.gethostname() and not pid_vivo(d['pid'])
            if velha:
                # tira a trava velha por rename (atômico: se dois veem a mesma trava morta, só um tira) e confere que tirou
                # a mesma que leu; se pegou a trava nova de outro no meio do caminho, devolve
                fora = TRAVA.with_name(f'portao.lock.velha.{os.getpid()}')
                try:
                    os.replace(TRAVA, fora)
                except FileNotFoundError:
                    continue
                try:
                    texto = fora.read_text(encoding='utf-8')
                except Exception:
                    texto = ''
                if 'inicio' not in d or f"pid={d['pid']}\n" in texto:
                    print(f"(trava velha da rodada {d['pid'] or '?'}, começada {d.get('inicio', '?')}, que não existe mais: apagada)",
                          flush=True)
                    fora.unlink(missing_ok=True)
                else:
                    try:
                        os.rename(fora, TRAVA)
                    except FileExistsError:
                        fora.unlink(missing_ok=True)
                continue
            if time.monotonic() > limite:
                sys.exit(f"Desisti: a rodada {d['pid']} ({d.get('quem', '?')}), começada {d.get('inicio', '?')}, ainda está "
                         f"ativa depois de {ESPERA_MIN:g} min de espera. Trava: {TRAVA}")
            if avisado != d['pid'] or time.monotonic() - avisado_em > 300:
                print(f"esperando a rodada de {d['pid']}, começada às {d.get('inicio', '?')[11:16] or '?'} "
                      f"({d.get('quem', '?')}) — espero até {ESPERA_MIN:g} min", flush=True)
                avisado, avisado_em = d['pid'], time.monotonic()
            time.sleep(3)
            continue
        with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as f:
            f.write(conteudo)
        atexit.register(soltar_trava)
        return


def soltar_trava():
    d = ler_trava()
    if d and d['pid'] == os.getpid():
        TRAVA.unlink(missing_ok=True)


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    args = [a for a in sys.argv[1:] if not a.startswith('--') and not a.endswith('.sql')]
    migs = [pathlib.Path(a).resolve() for a in sys.argv[1:] if a.endswith('.sql')]
    trilha = '--trilha' in sys.argv
    pegar_trava()
    try:
        rodada(args, migs, trilha)
    finally:
        soltar_trava()


def rodada(args, migs, trilha):
    if not (SIM / 'pgdata').exists():
        sys.exit('Cópia local não existe. Rode antes: tests/fluxos/copia_local.sh')
    rc, _, err = psql(BASE, arquivo=AQUI / 'sim.sql')
    if rc:
        sys.exit('Erro ao instalar o simulador na cópia local:\n' + err)
    modelo = BASE
    if migs:
        # a cópia-base fica intacta: as migrations entram num clone, e cada cenário clona esse clone
        psql('postgres', f'drop database if exists {TESTE} with (force)')
        rc, _, err = psql('postgres', f'create database {TESTE} template {BASE} strategy file_copy')
        if rc:
            sys.exit('Não consegui clonar a cópia local: ' + err.strip())
        for m in migs:
            rc, _, err = psql(TESTE, arquivo=m)
            if rc:
                sys.exit(f'A migration {m.name} falhou na cópia local (nada rodou):\n' + err.strip()[-1500:])
            print(f'migration aplicada na cópia: {m.name}')
        modelo = TESTE
    arqs = sorted((AQUI / 'cenarios').glob('*.sql'), key=lambda p: (p.stem[0], int(re.sub(r'\D', '', p.stem.split('_')[0]) or 0)))
    if args:
        arqs = [a for a in arqs if a.stem.split('_')[0] in args]
    res = [rodar(a, modelo) for a in arqs]
    if '--manter' not in sys.argv:
        psql('postgres', f'drop database if exists {CEN} with (force)')
        psql('postgres', f'drop database if exists {TESTE} with (force)')

    verdes = 0
    por_regra = {}
    for r in res:
        proprias = [c for c in r['checagens'] if c['tipo'] == 'cenario']
        gerais = [c for c in r['checagens'] if c['tipo'] != 'cenario']
        avisos = [c for c in r['checagens'] if not c['ok'] and c['tipo'] in AVISOS]
        falhas = [c for c in r['checagens'] if not c['ok'] and c['tipo'] not in AVISOS]
        for c in gerais:
            t = por_regra.setdefault(c['tipo'], {'nome': c['nome'], 'ok': 0, 'falha': 0, 'onde': []})
            t['ok' if c['ok'] else 'falha'] += 1
            if not c['ok']:
                t['onde'].append(r['id'])
        r['verde'] = not r['erro'] and not falhas and bool(proprias)
        verdes += r['verde']
        marca = 'VERDE   ' if r['verde'] else 'VERMELHO'
        print(f"{marca} {r['id']:<4} {r['titulo']}" + ('   [regra nova]' if r['tipo'] == 'regra_nova' else ''))
        if r['erro']:
            print(f"           ! o cenário parou: {r['erro']}")
        if not proprias and not r['erro']:
            print('           ! cenário sem conferência própria')
        for c in falhas:
            print(f"           x {c['tipo'] if c['tipo'] != 'cenario' else '·'} {c['nome']}" + (f" — {c['detalhe']}" if c['detalhe'] else ''))
        for c in avisos:
            print(f"           ~ {c['tipo']} (contradição conhecida do desenho de hoje, não conta) {c['nome']}")
        if trilha:
            for t in r['trilha']:
                print('             ' + t)
    print()
    print(f'{verdes} de {len(res)} cenários verdes')
    atuais_vermelhos = [r['id'] for r in res if r['tipo'] != 'regra_nova' and not r['verde']]
    completa = not args
    aprovado = completa and not atuais_vermelhos
    if aprovado:
        print(f'PORTÃO ABERTO por {PORTAO_HORAS} h' + (f" para: {', '.join(m.name for m in migs)}" if migs else ' (sem migration)'))
    else:
        print('PORTÃO FECHADO — ' + ('rodada parcial (só alguns cenários)' if not completa else
                                     'cenários atuais vermelhos: ' + ', '.join(atuais_vermelhos)))
    print('\nRegras gerais (conferidas no fim de todo cenário):')
    for k in sorted(por_regra):
        t = por_regra[k]
        print(f"  {k:<3} {t['ok']:>2} ok · {t['falha']:>2} falha  {t['nome']}" + (f"   → {', '.join(t['onde'])}" if t['onde'] else ''))
    (SIM / 'resultados').mkdir(exist_ok=True)
    saida = SIM / 'resultados' / f"portao_{datetime.datetime.now():%d%m%y_%H%M%S}.json"
    origem = (SIM / 'pacote_origem.txt').read_text().strip() if (SIM / 'pacote_origem.txt').exists() else None
    saida.write_text(json.dumps({'quando': datetime.datetime.now().isoformat(timespec='seconds'), 'verdes': verdes, 'total': len(res),
                                 'completa': completa, 'aprovado': aprovado, 'atuais_vermelhos': atuais_vermelhos,
                                 'copia_de': origem, 'migrations': {m.name: sha(m) for m in migs},
                                 'regras': por_regra, 'cenarios': res}, ensure_ascii=False, indent=1), encoding='utf-8')
    print(f'\nDetalhe: {saida}')
    sys.exit(0 if verdes == len(res) else 1)


if __name__ == '__main__':
    main()
