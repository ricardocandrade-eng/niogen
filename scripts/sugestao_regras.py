#!/usr/bin/env python
# NIOGEN | scripts/sugestao_regras.py | 18/11/2026 — Claude Code (Opus 5.5)
# Resumo: gera supabase/functions/sugerir-resposta/regras.ts a partir do prompt da Mari (mari/prompt_mari_v7.md), para o botão
# ✨ Sugerir resposta obedecer as MESMAS regras de conteúdo (preço, objeções, guard-rails, desvios/cliente Nio/golpe).
# Uma fonte só (regra 12): mudou o prompt da Mari → rode este script e publique a função de novo:
#   python scripts/sugestao_regras.py && npx supabase@3.0.0 functions deploy sugerir-resposta --use-api
# Uso: python scripts/sugestao_regras.py [--conferir]   (--conferir: só diz se o regras.ts está igual ao prompt de hoje)
import json, pathlib, re, sys

RAIZ = pathlib.Path(__file__).resolve().parent.parent
FONTE = RAIZ / 'mari' / 'prompt_mari_v7.md'
DESTINO = RAIZ / 'supabase' / 'functions' / 'sugerir-resposta' / 'regras.ts'
BLOCOS = ['## BLOCO 4 ', '## BLOCO 4b', '## BLOCO 5 ', '## BLOCO 7 ']   # preço · objeções · guard-rails · desvios


def extrair():
    txt = FONTE.read_text(encoding='utf-8')
    partes = re.split(r'(?m)^(?=## )', txt)
    achados = []
    for ini in BLOCOS:
        bloco = next((p for p in partes if p.startswith(ini)), None)
        if not bloco:
            sys.exit(f'Bloco não encontrado no prompt da Mari: {ini.strip()}')
        # linhas "# DECISÃO PENDENTE" são notas internas do prompt, não regra para o modelo
        achados.append('\n'.join(l for l in bloco.rstrip().splitlines() if not l.startswith('# ')))
    return '\n\n'.join(achados)


def gerar():
    corpo = extrair()
    return ('// NIOGEN | supabase/functions/sugerir-resposta/regras.ts — GERADO por scripts/sugestao_regras.py; não edite à mão.\n'
            f'// Fonte: mari/prompt_mari_v7.md, blocos {", ".join(b.replace("## ", "").strip() for b in BLOCOS)}.\n'
            f'export const REGRAS_MARI = {json.dumps(corpo, ensure_ascii=False)};\n')


if __name__ == '__main__':
    novo = gerar()
    atual = DESTINO.read_text(encoding='utf-8') if DESTINO.exists() else ''
    if '--conferir' in sys.argv:
        print('OK: regras.ts igual ao prompt da Mari' if atual == novo else 'DIFERENTE: rode python scripts/sugestao_regras.py e publique a função')
        sys.exit(0 if atual == novo else 1)
    DESTINO.parent.mkdir(parents=True, exist_ok=True)
    DESTINO.write_text(novo, encoding='utf-8', newline='\n')
    print(f'regras.ts gerado ({len(novo)} caracteres)' if atual != novo else 'regras.ts já estava igual')
