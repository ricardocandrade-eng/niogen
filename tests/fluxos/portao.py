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
# Saída: tabela no terminal + ~/niogen_sim/resultados/portao_<data>.json (fora do repo e do Drive).
#
# Cada cenário é um .sql com cabeçalho:
#   -- id: C8
#   -- titulo: Time devolve para a Mari
#   -- tipo: atual | regra_nova      (atual = já deveria funcionar hoje · regra_nova = decisão de 17/11 ainda não construída)
# e passos que chamam sim.* e as funções de verdade. No fim o portão confere as regras gerais (sim.invariantes) em toda
# conversa do cenário.
import json, os, re, subprocess, sys, datetime, pathlib

AQUI = pathlib.Path(__file__).resolve().parent
BIN = pathlib.Path(os.environ.get('PG_SERVER_BIN', pathlib.Path.home() / 'tools/pgsql17_server/pgsql/bin'))
SIM = pathlib.Path(os.environ.get('NIOGEN_SIM_DIR', pathlib.Path.home() / 'niogen_sim'))
BASE, CEN, PORTA = 'niogen_sim', 'niogen_cenario', '54329'
# Regras gerais que o desenho de hoje quebra de propósito (a conversa de quem saiu fica "ativa" para a Mari responder se ele
# voltar). Aparecem no relatório, mas não deixam o cenário vermelho — viram bloqueio quando a situação única existir.
AVISOS = {'S4'}
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
    r = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    return r.returncode, r.stdout, r.stderr


def cabecalho(texto):
    d = {}
    for l in texto.splitlines()[:12]:
        m = re.match(r'--\s*(id|titulo|tipo|regra)\s*:\s*(.+)', l)
        if m:
            d[m.group(1)] = m.group(2).strip()
    return d


def rodar(arq):
    texto = arq.read_text(encoding='utf-8')
    cab = cabecalho(texto)
    psql('postgres', f'drop database if exists {CEN} with (force)')
    rc, _, err = psql('postgres', f'create database {CEN} template {BASE} strategy file_copy')
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


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    trilha = '--trilha' in sys.argv
    if not (SIM / 'pgdata').exists():
        sys.exit('Cópia local não existe. Rode antes: tests/fluxos/copia_local.sh')
    rc, _, err = psql(BASE, arquivo=AQUI / 'sim.sql')
    if rc:
        sys.exit('Erro ao instalar o simulador na cópia local:\n' + err)
    arqs = sorted((AQUI / 'cenarios').glob('*.sql'), key=lambda p: (p.stem[0], int(re.sub(r'\D', '', p.stem.split('_')[0]) or 0)))
    if args:
        arqs = [a for a in arqs if a.stem.split('_')[0] in args]
    res = [rodar(a) for a in arqs]
    if '--manter' not in sys.argv:
        psql('postgres', f'drop database if exists {CEN} with (force)')

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
    print('\nRegras gerais (conferidas no fim de todo cenário):')
    for k in sorted(por_regra):
        t = por_regra[k]
        print(f"  {k:<3} {t['ok']:>2} ok · {t['falha']:>2} falha  {t['nome']}" + (f"   → {', '.join(t['onde'])}" if t['onde'] else ''))
    (SIM / 'resultados').mkdir(exist_ok=True)
    saida = SIM / 'resultados' / f"portao_{datetime.datetime.now():%d%m%y_%H%M}.json"
    saida.write_text(json.dumps({'quando': datetime.datetime.now().isoformat(timespec='minutes'), 'verdes': verdes, 'total': len(res),
                                 'regras': por_regra, 'cenarios': res}, ensure_ascii=False, indent=1), encoding='utf-8')
    print(f'\nDetalhe: {saida}')
    sys.exit(0 if verdes == len(res) else 1)


if __name__ == '__main__':
    main()
