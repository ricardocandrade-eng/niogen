#!/usr/bin/env python3
# NIOGEN | tests/mari_v7_teste_real.py | 06/11/2026 — Claude Code (prompt 26 D: teste no celular do Ricardo, rota de ENSAIO)
# Libera UM número no ensaio ("tel real") e conduz uma conversa até o Passo 3; só o passo marcado com enviar_real manda
# de verdade (Graph API) o carrossel/botões para esse número. Os balões de texto NÃO saem (rota de teste). Depois limpa.
# Uso: python tests/mari_v7_teste_real.py <55DDDNUMERO> [carrossel|botoes|limpar]
import json
import sys
import time
import urllib.request

sys.path.insert(0, __file__.rsplit('\\', 1)[0] if '\\' in __file__ else __file__.rsplit('/', 1)[0])
import mari_v7_bateria as b  # noqa: E402

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')


def post(body):
    req = urllib.request.Request(b.URL, data=json.dumps(body).encode(), method='POST',
                                 headers={'X-Mari-Secret': b.SEGREDO, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode() or '{}')


def diz(tel, texto, real=False):
    time.sleep(1.5)
    r = post({'telefone': tel, 'nome': 'Ricardo (teste real)', 'texto': texto, 'origem': 'meta_ads', 'enviar_real': real})
    it = r.get('interativo') or {}
    print(f'> {texto}\n  Mari: {(r.get("resposta") or "")[:160]!r}\n  interativo: {it.get("tipo")} {it.get("chave") or ""}{"  (ENVIADO DE VERDADE)" if real and it else ""}')
    return r


if __name__ == '__main__':
    tel = sys.argv[1]
    modo = sys.argv[2] if len(sys.argv) > 2 else 'carrossel'
    if modo == 'limpar':
        print(post({'admin': 'tel real off'}))
        print(b.sql(f"select public.mari_limpar_teste('{tel}') as r", escrita=True))
        sys.exit(0)
    b.sql(f"select public.mari_limpar_teste('{tel}') as r", escrita=True)
    print(post({'admin': f'tel real {tel}'}))
    diz(tel, 'Oi! Vi o anúncio e quero saber se a Nio chega na minha rua.')
    r = diz(tel, '36036-233, número 155', real=(modo == 'botoes'))
    if (r.get('interativo') or {}).get('chave') == 'sim_nao' or '?' in (r.get('resposta') or ''):
        diz(tel, 'Sim')
    diz(tel, 'Não tem complemento. Referência: em frente à padaria')
    diz(tel, 'Uso a Claro', real=(modo == 'carrossel'))
