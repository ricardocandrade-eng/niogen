#!/usr/bin/env python3
# NIOGEN | tests/mari_conversar.py | 04/11/2026 — Claude Code
# Conversa com a Mari pela rota de teste (modo teste). Lê MARI_TESTE_SECRET do ambiente; nunca imprime.
# Uso: python tests/mari_conversar.py [telefone]   (padrão 5500000000500 — prefixo de teste, limpo pelo mari_limpar_teste)
# Comandos: /audio (manda um áudio), /novo (troca de telefone = conversa nova), /sair
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mari_cenarios import SEGREDO, enviar  # noqa: E402

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stdin.reconfigure(encoding='utf-8', errors='replace')

if not SEGREDO:
    raise SystemExit('MARI_TESTE_SECRET ausente.')

tel = sys.argv[1] if len(sys.argv) > 1 else '5500000000500'
print(f'Conversando como {tel}. /audio · /novo · /sair\n')
while True:
    try:
        msg = input('👤 ').strip()
    except (EOFError, KeyboardInterrupt):
        break
    if not msg:
        continue
    if msg == '/sair':
        break
    if msg == '/novo':
        tel = str(int(tel) + 1)
        print(f'(conversa nova: {tel})\n')
        continue
    r = enviar(tel, None, midia='audio') if msg == '/audio' else enviar(tel, msg, nome='Ricardo')
    if r.get('resposta'):
        print('🤖 ' + r['resposta'].replace('\n', '\n   '))
    else:
        print('🤖 (sem resposta) ' + json.dumps({k: v for k, v in r.items() if k != '_seg'}, ensure_ascii=False))
    if r.get('handoff'):
        h = r['handoff']
        print(f"   → handoff {h.get('motivo')}" + (f" · venda {h.get('venda_id')}" if h.get('venda_id') else '')
              + (f" · venda recusada: {h.get('motivo_recusa')}" if h.get('motivo_recusa') else ''))
    print(f"   ({r.get('_seg')} s · etapa {r.get('etapa')})\n")
