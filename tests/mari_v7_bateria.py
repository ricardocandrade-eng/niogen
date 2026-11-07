#!/usr/bin/env python3
# NIOGEN | tests/mari_v7_bateria.py | 06/11/2026 — Claude Code (prompts 26 + 27 unificados, Mari v7)
# Bateria da v7 no ENSAIO (workflow mari_principal_v3, rota POST /webhook/mari-teste-v3, telefones 5500000003xxx).
# Conversas roteirizadas (o lead manda sempre as mesmas falas) + checagens:
#   GLOBAL (todas as respostas): nada de promessa de cobertura ("a Nio atende aí", "tem cobertura", "chega na sua rua"),
#   nada de prazo para o pedido ("em até N horas", "hoje ainda"), nenhum handoff ja_cliente_nio, sem asterisco.
#   POR CENÁRIO: (a) conversa do Edson — rua divergente, referência, operadora, carrossel, CPF mascarado, botões no
#   resumo, despedida sem prazo; (c) só rua → opções com CEP; (d) DFV viável e (e) não encontrado → fala igual;
#   (g) Nio ativa aqui → handoff humano; (h) "tinha Oi" → segue com a pista; (i) "Detalhes Fibra" → texto fixo;
#   (j) cidade BTU → lista em texto, sem carrossel.
# Segredo: MARI_TESTE_SECRET (variável de usuário; nunca impresso). Teardown: mari_limpar_teste('5500000003').
# Uso: python tests/mari_v7_bateria.py [a c d e g h i j] [--sem-teardown]
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
import urllib.request

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
URL = 'https://n8n.ofertasverointernet.com.br/webhook/mari-teste-v3'
PREFIXO = '5500000003'
NPX = 'npx.cmd' if sys.platform == 'win32' else 'npx'


def env(nome):
    v = os.environ.get(nome)
    if v or sys.platform != 'win32':
        return v
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as h:
        return winreg.QueryValueEx(h, nome)[0]


SEGREDO = env('MARI_TESTE_SECRET')
norm = lambda s: unicodedata.normalize('NFD', str(s or '').lower()).encode('ascii', 'ignore').decode()


def sql(q, escrita=False):
    args = [NPX, 'supabase', 'db', 'query', '--remote', '-o', 'json'] + (['--yes'] if escrita else ['--read-only'])
    p = subprocess.run(args + [' '.join(q.split())], cwd=REPO, capture_output=True, text=True, encoding='utf-8')
    out = p.stdout.strip()
    if p.returncode != 0:
        raise RuntimeError(p.stderr[-300:] + out[-300:])
    d = json.loads(out[out.find('{'):])
    return d.get('rows', [])


def falar(tel, texto, nome='Teste V7'):
    body = json.dumps({'telefone': tel, 'nome': nome, 'texto': texto, 'origem': 'auto'}).encode()
    req = urllib.request.Request(URL, data=body, method='POST', headers={'X-Mari-Secret': SEGREDO, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode() or '{}')


GLOBAL = [
    (r'\b(atende|chega|tem cobertura|tem fibra)\s+(a[ií]\b|na sua rua|no seu endereco|na sua casa)', 'prometeu cobertura no endereço'),
    (r'\btem cobertura\b|boa noticia', 'falou "tem cobertura"/"boa notícia"'),
    (r'em ate \d+\s*(h\b|hora|min)|hoje ainda|ainda hoje', 'prometeu prazo'),
]


class Conversa:
    def __init__(self, cid, n):
        self.cid, self.tel, self.falhas, self.log = cid, f'{PREFIXO}{n:03d}', [], []

    def diz(self, texto):
        time.sleep(1.5)
        r = falar(self.tel, texto)
        resp = r.get('resposta') or ''
        it = r.get('interativo')
        self.log.append({'lead': texto, 'mari': resp, 'interativo': it, 'handoff': r.get('handoff'), 'erro': r.get('erro'), 'tags': r.get('tags')})
        alvo = norm(resp + '\n' + ((it or {}).get('corpo') or ''))
        # Igual ao filtro do 7 · Extrair: pergunta ou condicional ("pra eu ver se chega aí?") não é promessa.
        afirm = ' '.join(f for f in re.split(r'(?<=[.?!\n])', alvo)
                         if '?' not in f and not re.search(r'\b(ver|saber|confirmar|checar|conferir|olhar) se\b|\bse (a nio |a fibra |ela |a gente )?(chega|atende)\b', f))
        for rx, rot in GLOBAL:
            if re.search(rx, afirm if 'cobertura' in rot or 'boa' in rot else alvo):
                self.falha(f'{rot}: «{resp[:120]}»')
        if '*' in re.sub(r'\d{3}\.\*{3}\.\*{3}-\d{2}', '', resp):   # o CPF mascarado (123.***.***-30) é esperado
            self.falha('asterisco')
        if (r.get('handoff') or {}).get('motivo') == 'ja_cliente_nio':
            self.falha('encerrou por já é cliente')
        if r.get('erro'):
            self.falha(f'erro: {r.get("erro")}')
        return r

    def falha(self, msg):
        self.falhas.append(msg)

    def exige(self, cond, msg):
        if not cond:
            self.falha(msg)


def cen_a(c):   # conversa do Edson (rua divergente, referência, operadora, carrossel, resumo, despedida)
    c.diz('Oi! Vi o anúncio e quero saber se a Nio chega na minha rua.')
    c.diz('E novo triunfo 2')
    c.diz('Rua Sebastião Antônio da Silva')
    r = c.diz('36092-272')
    c.exige('pedro' in norm(r.get('resposta')) and 'antonio' in norm(r.get('resposta')), '(a) não perguntou qual rua (CEP da Sebastião Pedro × Sebastião Antônio)')
    r = c.diz('É essa mesma do CEP, número 2')
    if (r.get('interativo') or {}).get('chave') == 'sim_nao' or 'endereco e' in norm(r.get('resposta')):
        r = c.diz('Sim')
    c.exige('referencia' in norm(r.get('resposta')) + norm((r.get('interativo') or {}).get('corpo')), '(a) não pediu o ponto de referência')
    r = c.diz('Não tem complemento. Referência: perto da escola estadual')
    c.exige('operadora' in norm(r.get('resposta')), '(a) não perguntou a operadora atual')
    r = c.diz('Uso a Claro, cai toda hora')
    it = r.get('interativo') or {}
    c.exige(it.get('tipo') == 'carrossel', '(a) não mandou o carrossel (Varejo Regular)')
    c.exige('disponibilidade exata' in norm(r.get('resposta')), '(a) sem a frase "a disponibilidade exata na sua rua o nosso time confirma"')
    r = c.diz('Quero o Fibra')
    c.diz('Edson Teste da Silva, CPF 529.982.247-25')
    r = c.diz('O telefone é esse mesmo do WhatsApp')
    r = c.diz('edson.teste@exemplo.com')
    if (r.get('interativo') or {}).get('chave') != 'pagamento':
        c.falha('(a) forma de pagamento sem os botões')
    r = c.diz('Cartão de crédito')
    r = c.diz('De manhã')
    txt = (r.get('resposta') or '') + '\n' + ((r.get('interativo') or {}).get('corpo') or '')
    c.exige('529.***.***-25' in txt, f'(a) CPF não mascarado no resumo: «{txt[:200]}»')
    c.exige('referencia' in norm(txt), '(a) resumo sem a referência')
    c.exige((r.get('interativo') or {}).get('chave') == 'resumo', '(a) resumo sem os botões')
    r = c.diz('Sim, está certo')
    c.exige((r.get('handoff') or {}).get('motivo') == 'dados_completos', '(a) sem handoff dados_completos')
    c.exige('confere tudo no sistema da nio' in norm(r.get('resposta')), '(a) despedida sem "confere tudo no sistema da Nio"')


def cen_c(c):   # só rua, sem CEP → opções numeradas com CEP
    c.diz('Oi! Vi o anúncio e quero saber se a Nio chega na minha rua.')
    r = c.diz('Moro na Rua Sebastião Pedro da Silva, número 2')
    c.exige(re.search(r'\d{5}-?\d{3}', r.get('resposta') or ''), f'(c) não ofereceu a rua com o CEP: «{(r.get("resposta") or "")[:160]}»')
    r = c.diz('1')
    rows = sql(f"select cep from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1")
    c.exige(rows and str(rows[0].get('cep') or '').replace('-', '') == '36092272', f'(c) a escolha "1" não virou o CEP da opção: {rows}')


def ate_planos(c, cep, num, operadora='Uso a Vivo'):
    c.diz('Oi! Vi o anúncio e quero saber se a Nio chega na minha rua.')
    r = c.diz(f'{cep}, número {num}')
    if (r.get('interativo') or {}).get('chave') == 'sim_nao' or '?' in (r.get('resposta') or ''):
        r = c.diz('Sim')
    r = c.diz('Não tem complemento. Referência: em frente à padaria')
    return c.diz(operadora)


def cen_d(c):   # DFV viável → fala igual (sem promessa)
    r = ate_planos(c, '36036-233', '155')
    rows = sql(f"select dfv_resultado from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1")
    c.exige(rows and rows[0].get('dfv_resultado') in ('viavel', 'viavel_predio'), f'(d) DFV não consultado como viável: {rows}')


def cen_e(c):   # DFV não encontrado → fala igual
    ate_planos(c, '36092-272', '2')
    rows = sql(f"select dfv_resultado from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1")
    c.exige(rows and rows[0].get('dfv_resultado'), f'(e) DFV não consultado na hora do endereço: {rows}')


def cen_g(c):   # Nio ativa nesta unidade → humano com time
    r = ate_planos(c, '36036-233', '175', 'Uso a Nio')
    c.exige('ativa' in norm(r.get('resposta')) + norm((r.get('interativo') or {}).get('corpo')), '(g) não perguntou se a Nio está ativa')
    r = c.diz('Sim, tá ativa aqui no meu nome')
    c.exige((r.get('handoff') or {}).get('motivo') == 'pedido_humano', f'(g) sem handoff pedido_humano: {r.get("handoff")}')
    c.exige('melhor forma de te atender' in norm(r.get('resposta')), '(g) sem a fala "ver a melhor forma de te atender"')


def cen_h(c):   # "tinha Oi" → segue com a pista
    r = ate_planos(c, '36036-233', '155', 'Tinha Oi Fibra, cancelei faz tempo')
    if 'ativa' in norm(r.get('resposta')):
        r = c.diz('Não, cancelei faz uns 2 anos')
    c.exige(not r.get('handoff'), '(h) encerrou a conversa')
    c.exige((r.get('interativo') or {}).get('tipo') == 'carrossel' or re.search(r'(?m)^\s*1\)', r.get('resposta') or ''), '(h) não seguiu para os planos')


def cen_i(c):   # botão "Detalhes Fibra" → texto fixo, sem Claude
    ate_planos(c, '36036-233', '155')
    r = c.diz('Detalhes Fibra')
    c.exige('600 Mega de velocidade com roteador Wi-Fi 5.  E o valor do seu plano não muda até janeiro de 2030!' in (r.get('resposta') or ''), '(i) "Detalhes Fibra" não devolveu o texto fixo da spec')


def cen_j(c):   # cidade BTU → lista em texto
    c.diz('Oi! Quero saber dos planos da Nio.')
    r = c.diz('Meu CEP é 38440-001, número 100')   # Araguari (BTU)
    if '?' in (r.get('resposta') or ''):
        r = c.diz('Sim')
    r = c.diz('Não tem complemento. Referência: perto da praça')
    r = c.diz('Uso a Claro')
    c.exige(not r.get('interativo'), '(j) mandou carrossel em cidade BTU')
    c.exige(re.search(r'(?m)^\s*1\)', r.get('resposta') or ''), '(j) sem a lista em texto')


def cen_k(c):   # teste real de 06/11 22h57 (conversa #1): rua + cidade em mensagens separadas, "Escrevi acima", "Isso"
    c.diz('Oi, quero saber da internet da Nio')
    c.diz('Não sei o CEP')
    c.diz('Rua dos Artistas, 123')
    c.diz('Juiz de Fora')
    c.diz('Escrevi acima')
    c.diz('Isso')
    c.diz('Apto 403')
    c.diz('Edificio Dom Paschoal')
    r = c.diz('Nenhuma, estou me mudando pra esse apto')
    resp = (r.get('resposta') or '').strip()
    it = r.get('interativo') or {}
    c.exige(it.get('tipo') == 'carrossel', f'(k) não mandou o carrossel: «{resp[:160]}»')
    # nunca "Olha as opções:" pendurado sem o carrossel nem a lista
    c.exige(it or not re.search(r'olha as op[cç][õo]es:?\s*$', resp, re.I), '(k) frase "Olha as opções:" sem nada depois')
    rows = sql(f"select cep, cidade, cluster from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1")
    c.exige(rows and str(rows[0].get('cep') or '').replace('-', '') == '36035130', f'(k) o CEP da opção confirmada não foi gravado: {rows}')
    c.exige(rows and rows[0].get('cluster'), f'(k) cluster vazio: {rows}')


CENARIOS = {'a': (1, cen_a), 'c': (2, cen_c), 'd': (3, cen_d), 'e': (4, cen_e), 'g': (5, cen_g), 'h': (6, cen_h), 'i': (7, cen_i), 'j': (8, cen_j), 'k': (9, cen_k)}

if __name__ == '__main__':
    if not SEGREDO:
        sys.exit('MARI_TESTE_SECRET ausente')
    escolha = [a for a in sys.argv[1:] if a in CENARIOS] or list(CENARIOS)
    sql(f"select public.mari_limpar_teste('{PREFIXO}')", escrita=True)
    res = {}
    for k in escolha:
        n, f = CENARIOS[k]
        c = Conversa(k, n)
        try:
            f(c)
        except Exception as e:
            c.falha(f'exceção: {e}')
        res[k] = c
        print(f"({k}) {'VERDE' if not c.falhas else 'FALHOU'}" + ''.join(f'\n    - {x}' for x in c.falhas))
    os.makedirs(os.path.join(REPO, 'tests', 'saida'), exist_ok=True)
    with open(os.path.join(REPO, 'tests', 'saida', 'mari_v7_bateria.json'), 'w', encoding='utf-8') as fh:
        json.dump({k: {'falhas': c.falhas, 'log': c.log} for k, c in res.items()}, fh, ensure_ascii=False, indent=1)
    if '--sem-teardown' not in sys.argv:
        sql(f"select public.mari_limpar_teste('{PREFIXO}')", escrita=True)
    verdes = sum(1 for c in res.values() if not c.falhas)
    print(f'{verdes}/{len(res)} verdes')
