#!/usr/bin/env python3
# NIOGEN | tests/mari_tela_dados.py | 04/11/2026 — Claude Code (prompt nº 12)
# Gera as 6 conversas de teste da validação da tela Mari pela rota /webhook/mari-teste (nada sai para WhatsApp):
# JF qualificada · BTU qualificada · fora de área · já cliente · desconto → humano · parou na coleta.
# NÃO limpa no fim (a tela precisa delas). Limpar depois: python tests/mari_tela_dados.py --limpar
import concurrent.futures as cf
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mari_cenarios as mc  # noqa: E402

if '--limpar' in sys.argv:
    print('teardown:', mc.teardown())
    sys.exit(0)


def coleta():
    log = mc.conversar(mc.PREFIXO + '020', mc.P(nome='Paula Teste Rocha'),
                       parar=lambda r, log: (r.get('etapa') == 'coleta') or (r.get('upd') or {}).get('etapa') == 'coleta')
    return [('parou na coleta', (mc.ultimo(log).get('etapa') or (mc.ultimo(log).get('upd') or {}).get('etapa')) == 'coleta')], log, 'regular'


TAREFAS = {'JF qualificada': mc.c1, 'BTU qualificada': mc.c2, 'fora de área': mc.c3, 'já cliente': mc.c4,
           'desconto → humano': mc.c6, 'parou na coleta': coleta}

if __name__ == '__main__':
    mc.carregar_planos()
    print('teardown inicial:', mc.teardown())
    with cf.ThreadPoolExecutor(max_workers=6) as pool:
        futs = {pool.submit(fn): nome for nome, fn in TAREFAS.items()}
        for f in cf.as_completed(futs):
            nome = futs[f]
            try:
                checks, log, _ = f.result()
                r = mc.ultimo(log)
                print(f"{nome}: {len(log)} turnos · etapa={r.get('etapa')} · handoff={(r.get('handoff') or {}).get('motivo')} · "
                      f"checks={[c for c, b in checks if not b] or 'ok'}")
            except Exception as e:  # noqa: BLE001
                print(f'{nome}: ERRO {e}')
