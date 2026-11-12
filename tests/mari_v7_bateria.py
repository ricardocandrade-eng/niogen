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
# Uso: python tests/mari_v7_bateria.py <cenários…> [--max N] [--sem-teardown]
#   Sem cenário NÃO roda nada (só lista) — bateria custa API: 1–2 cenários, uma vez (regra de 07/11).
#   --max N limita o número de conversas. A limpeza (mari_limpar_teste) roda sempre no fim, também em erro/Ctrl+C.
# Medição (07/11): o ensaio devolve o usage separado por fala ("uso", só na rota de teste); no fim sai a tabela de
# tokens por tipo, % de cache_read, custo estimado por modelo e por conversa, e a economia estimada do corte de histórico.
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


# US$ por milhão de tokens (skill claude-api, cache de 06/10/2026): entrada, gravação no cache (5 min = 1,25×),
# leitura do cache, saída. Haiku 5.5: tabela de prompt ≤ 100 mil tokens (o da Mari tem ~25 mil).
PRECOS = {
    'claude-haiku-5-5': {'in': 0.10, 'cw': 0.125, 'cr': 0.01, 'out': 0.50},
    'claude-sonnet-5': {'in': 2.00, 'cw': 2.50, 'cr': 0.20, 'out': 10.00},
}
TIPOS = ('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens', 'output_tokens')


def custo(u, modelo):
    p = PRECOS.get(modelo)
    if not p:
        return None
    return (u.get('input_tokens', 0) * p['in'] + u.get('cache_creation_input_tokens', 0) * p['cw']
            + u.get('cache_read_input_tokens', 0) * p['cr'] + u.get('output_tokens', 0) * p['out']) / 1e6


GLOBAL = [
    # 12/11: "ainda não chega no seu endereço" (aviso do sem_cobertura, P27) é negação, não promessa
    (r'(?<!nao )\b(atende|chega|tem cobertura|tem fibra)\s+(a[ií]\b|na sua rua|no seu endereco|na sua casa)', 'prometeu cobertura no endereço'),
    (r'\btem cobertura\b|boa noticia', 'falou "tem cobertura"/"boa notícia"'),
    (r'em ate \d+\s*(h\b|hora|min)|hoje ainda|ainda hoje', 'prometeu prazo'),
]


class Conversa:
    def __init__(self, cid, n, nome='Teste V7'):
        # nome = nome do contato no Chatwoot. 'Teste V7' (com número) NÃO parece nome de pessoa → abertura sem nome.
        self.cid, self.tel, self.falhas, self.log, self.nome = cid, f'{PREFIXO}{n:03d}', [], [], nome

    def diz(self, texto):
        time.sleep(1.5)
        r = falar(self.tel, texto, self.nome)
        resp = r.get('resposta') or ''
        it = r.get('interativo')
        self.log.append({'lead': texto, 'mari': resp, 'interativo': it, 'handoff': r.get('handoff'), 'erro': r.get('erro'), 'tags': r.get('tags'),
                         'uso': r.get('uso'), 'modelo': r.get('modelo')})
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

    def totais(self):
        t = {k: 0 for k in TIPOS}
        t.update(chamadas=0, custo=0.0, falas=len(self.log), modelos=set(), econ_tokens=0.0)
        for f in self.log:
            u = f.get('uso') or {}
            if not u:
                continue
            for k in TIPOS:
                t[k] += u.get(k, 0)
            t['chamadas'] += u.get('chamadas', 1)
            m = u.get('modelo') or f.get('modelo')
            t['modelos'].add(m)
            t['custo'] += custo(u, m) or 0
            ch = u.get('corteHist') or {}
            base = (ch.get('charsMsgs') or 0) + (ch.get('charsDinamico') or 0)
            if base and ch.get('charsFora') and not ch.get('aplicado'):
                # tokens/char medido nesta chamada (input novo ÷ texto novo) × texto que o corte tiraria
                por_char = u.get('input_tokens', 0) / max(u.get('chamadas', 1), 1) / base
                t['econ_tokens'] += ch['charsFora'] * por_char * u.get('chamadas', 1)
        return t

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
    # a Mari confirma o endereço ("Seu endereço é…?", "…, nº 2, Barreira do Triunfo. Confere certinho?") → "Sim"
    if (r.get('interativo') or {}).get('chave') == 'sim_nao' or 'endereco e' in norm(r.get('resposta')) \
            or ('?' in (r.get('resposta') or '') and 'referencia' not in norm(r.get('resposta'))):
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
    r = confirma_email(c, r, 'edson.teste@exemplo.com', 'a')
    if (r.get('interativo') or {}).get('chave') != 'pagamento':
        c.falha('(a) forma de pagamento sem os botões')
    r = c.diz('Cartão de crédito')
    # 12/11 (Ricardo): depois do pagamento, botões de DATA (D+1/D+2/D+3, sem domingo/feriado) e depois de PERÍODO
    it = r.get('interativo') or {}
    c.exige(it.get('chave') == 'data' and len(it.get('botoes') or []) == 3, f'(a) depois do pagamento, sem os 3 botões de data: {it.get("chave")}')
    c.exige(not any(str(b.get('title', '')).startswith('Dom') for b in (it.get('botoes') or [])), '(a) ofereceu domingo')
    data_esc = ((it.get('botoes') or [{}])[0]).get('title') or 'Seg, 16/11'
    r = c.diz(data_esc)
    c.exige((r.get('interativo') or {}).get('chave') == 'turno', '(a) depois da data, sem os botões Manhã/Tarde')
    r = c.diz('Manhã')
    txt = (r.get('resposta') or '') + '\n' + ((r.get('interativo') or {}).get('corpo') or '')
    c.exige(data_esc.split(',')[-1].strip() in txt, f'(a) resumo sem a data escolhida ({data_esc})')
    c.exige('529.***.***-25' in txt, f'(a) CPF não mascarado no resumo: «{txt[:200]}»')
    c.exige('referencia' in norm(txt), '(a) resumo sem a referência')
    c.exige((r.get('interativo') or {}).get('chave') == 'resumo', '(a) resumo sem os botões')
    r = c.diz('Sim, está certo')
    c.exige((r.get('handoff') or {}).get('motivo') == 'dados_completos', '(a) sem handoff dados_completos')
    c.exige('confere tudo no sistema da nio' in norm(r.get('resposta')), '(a) despedida sem "confere tudo no sistema da Nio"')


def cen_c(c):   # só rua, sem CEP → opção única: CEP gravado na hora e mostrado na confirmação (07/11)
    c.diz('Oi! Vi o anúncio e quero saber se a Nio chega na minha rua.')
    r = c.diz('Moro na Rua Sebastião Pedro da Silva, número 2')
    resp = r.get('resposta') or ''
    conf = norm(resp + ' ' + ((r.get('interativo') or {}).get('corpo') or ''))
    c.exige('sebastiao pedro' in conf and ('triunfo' in conf or re.search(r'\d{5}-?\d{3}', conf)), f'(c) não confirmou a rua achada pelo CEP: «{resp[:160]}»')
    rows = sql(f"select cep, numero from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1")
    c.exige(rows and str(rows[0].get('cep') or '').replace('-', '') == '36092272', f'(c) o CEP da busca (opção única) não foi gravado na hora: {rows}')
    c.exige(rows and str(rows[0].get('numero') or '') == '2', f'(c) o número dado junto da rua não foi gravado: {rows}')
    c.diz('1' if re.search(r'(?m)^\s*1\)', resp) else 'Sim')
    rows = sql(f"select cep from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1")
    c.exige(rows and str(rows[0].get('cep') or '').replace('-', '') == '36092272', f'(c) o CEP mudou depois da confirmação: {rows}')


def cen_m(c):   # 07/11: rua longa (26 CEPs no ViaCEP, um por faixa de número) → sem número a Mari pede o número;
    # com "2000" o sistema acha o CEP da faixa (36015-510, lado par 1584–2200) sem chutar opções
    c.diz('Oi, quero saber da internet da Nio')
    r = c.diz('Moro na Avenida Barão do Rio Branco, em Juiz de Fora')
    resp = norm(r.get('resposta'))
    c.exige('numero' in resp, f'(m) não pediu o número da casa: «{resp[:200]}»')
    c.exige(not re.search(r'(?m)^\s*2\)', r.get('resposta') or ''), f'(m) chutou opções de CEP sem o número: «{resp[:200]}»')
    c.diz('2000')
    rows = sql(f"select cep, numero from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1")
    c.exige(rows and str(rows[0].get('cep') or '').replace('-', '') == '36015510', f'(m) o CEP da faixa do 2000 não foi gravado: {rows}')
    c.exige(rows and str(rows[0].get('numero') or '') == '2000', f'(m) número da casa não gravado: {rows}')


def cen_n(c):   # 07/11: a Mari nunca diz que já mandou planos que o cliente não recebeu
    c.diz('Oi, quero saber da internet da Nio')
    r = c.diz('Não recebi as imagens dos planos que você mandou')
    txt = norm((r.get('resposta') or '') + ' ' + ((r.get('interativo') or {}).get('corpo') or ''))
    c.exige(not re.search(r'(planos|imagens|opcoes) que (te |eu )?mand', txt), f'(n) disse que já tinha mandado planos: «{txt[:200]}»')
    c.exige(not re.search(r'r\$\s*\d', txt), f'(n) citou preço sem CEP: «{txt[:200]}»')


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


def cen_l(c):   # teste real 07/11 00h11: sem CEP o cliente pressiona por planos — nenhum preço pode ser inventado
    c.diz('Oi, quero saber da internet da Nio')
    for fala in ('Não sei o CEP, só me manda os planos e os preços', 'Não recebi nada, manda a lista agora'):
        r = c.diz(fala)
        txt = (r.get('resposta') or '') + ' ' + ((r.get('interativo') or {}).get('corpo') or '')
        c.exige(not re.search(r'R\$\s*\d', txt), f'(l) citou preço sem cidade/CEP: «{txt[:200]}»')
        c.exige(not (r.get('interativo') or {}).get('tipo') == 'carrossel', '(l) mandou carrossel sem cidade/CEP')


def cen_o(c):   # teste real 07/11 23h08 (conversa #1): 👋💚, "Anotado", rua única, cobertura sem portal, condições, CPF, tanto faz
    sem_anotado = lambda r, rot: c.exige('anotad' not in norm(r.get('resposta')), f'(o) "anotado" em {rot}: «{(r.get("resposta") or "")[:100]}»')
    r = c.diz('Oi, Mari! Vim pelo Instagram e quero saber se a Nio chega na minha rua. (IG)')
    # 08/11: desde a abertura B2 a 1ª resposta é a saudação fixa com 3 botões (casos r–u); a regra do 👋💚 vale se ela não sair.
    if (r.get('interativo') or {}).get('chave') != 'abertura':
        c.exige('👋' not in (r.get('resposta') or '') and (r.get('resposta') or '').count('💚') == 1, f'(o) saudação com 2 emojis: «{(r.get("resposta") or "")[:80]}»')
    r = c.diz('Rua dos Artistas, 123')
    alvo = norm((r.get('resposta') or '') + ((r.get('interativo') or {}).get('corpo') or ''))
    c.exige('encontrei aqui' not in alvo and '·' not in alvo, f'(o) rua única em formato de lista: «{alvo[:120]}»')
    r = c.diz('Sim')
    r = c.diz('Apto 403')
    r = c.diz('Perto da igreja')
    sem_anotado(r, 'referência')
    r = c.diz('Vero')
    c.exige('atende o seu endereco' not in norm(r.get('resposta')), '(o) prometeu cobertura sem o portal')
    c.exige('pode deixar' not in norm(r.get('resposta')), f'(o) comentou a operadora: «{(r.get("resposta") or "")[:80]}»')
    r = c.diz('Quero o Super')
    t = norm(r.get('resposta'))
    c.exige('as condicoes do seu plano' in t and ('nome completo' not in t or t.index('as condicoes do seu plano') < t.index('nome completo')),
            '(o) pedido de nome/CPF antes das condições')
    r = c.diz('Ricardo Teste - 529.982.247-25')
    sem_anotado(r, 'nome/CPF')
    r = c.diz('Esse mesmo daqui')
    if '?' in (r.get('resposta') or '') and 'mail' not in norm(r.get('resposta')):
        r = c.diz('Sim')
    r = c.diz('ricardo.teste@exemplo.com')
    sem_anotado(r, 'e-mail')
    r = confirma_email(c, r, 'ricardo.teste@exemplo.com', 'o')
    c.exige((r.get('interativo') or {}).get('chave') == 'pagamento', '(o) pagamento sem os botões')
    r = c.diz('Cartão de crédito')
    sem_anotado(r, 'pagamento')
    # 12/11: "tanto faz" na data → qualquer data e segue para o período; "tanto faz" no período → qualquer período
    c.exige((r.get('interativo') or {}).get('chave') == 'data', '(o) depois do pagamento, sem os botões de data')
    r = c.diz('Tanto faz')
    if (r.get('interativo') or {}).get('chave') == 'turno':   # "tanto faz" valeu só para a data → pergunta o período
        r = c.diz('Tanto faz')
    c.exige((r.get('interativo') or {}).get('chave') != 'data', '(o) "tanto faz" na data repetiu a pergunta da data')
    txt = (r.get('resposta') or '') + '\n' + ((r.get('interativo') or {}).get('corpo') or '')
    c.exige('529.***.***-25' in txt, f'(o) CPF errado no resumo: «{txt[:240]}»')
    c.exige('deixo como' not in norm(txt) and 'qualquer' in norm(txt), f'(o) "tanto faz" virou escolha da Mari: «{txt[:160]}»')
    c.exige((r.get('interativo') or {}).get('chave') == 'resumo', '(o) resumo sem os botões')
    r = c.diz('Sim, está certo')
    c.exige((r.get('handoff') or {}).get('motivo') == 'dados_completos', '(o) sem handoff dados_completos')
    sem_anotado(r, 'despedida')
    r = c.diz('Obrigado!')
    print(f'    pós-handoff → {r.get("resposta") or r}')


def cen_p(c):   # teste real 08/11 00h15: upsell do Essencial sem "o dobro" (800 Mega → 1 Giga); telefone não se pergunta
    r = c.diz('Oi')
    c.diz('36035130')
    r = c.diz('123')
    if (r.get('interativo') or {}).get('chave') == 'sim_nao' or '?' in (r.get('resposta') or ''):
        r = c.diz('Sim')
    c.diz('403')
    r = c.diz('Igreja')
    if 'operadora' not in norm(r.get('resposta')):
        r = c.diz('Não tem ponto de referência melhor, é perto da igreja')
    c.diz('Claro')
    r = c.diz('Quero o Essencial')
    t = norm(r.get('resposta'))
    c.exige(not re.search(r'\bdobro\b|duas vezes|\btriplo\b|\bmetade\b', t), f'(p) upsell com comparação: «{(r.get("resposta") or "")[:200]}»')
    if 'por mais r$' in t:
        c.exige('800' in t and ('1 giga' in t or '1 gb' in t), f'(p) upsell sem os números da tabela: «{(r.get("resposta") or "")[:200]}»')
    if 'condicoes' not in t:
        r = c.diz('Quero esse mesmo')
        t = norm(r.get('resposta'))
    # 08/11 00h36: confirmação → condições → "Fechou? Me manda seu nome completo e CPF…" (nunca o pedido antes das condições)
    c.exige('as condicoes do seu plano' in t and 'nome completo' in t and t.index('as condicoes do seu plano') < t.index('nome completo'),
            f'(p) condições fora de ordem: «{(r.get("resposta") or "")[:220]}»')
    c.exige('preciso confirmar seus dados' not in t, '(p) pedido de dados confuso ("Agora preciso confirmar seus dados")')
    r = c.diz('Ricardo Teste - 529.982.247-25')
    t = norm(r.get('resposta'))
    c.exige('mail' in t and 'telefone' not in t, f'(p) perguntou o telefone (ou não pediu o e-mail): «{(r.get("resposta") or "")[:160]}»')


def confirma_email(c, r, email, rot):
    """10/11 (rodada única): a Mari repete o e-mail para o cliente confirmar antes do pagamento."""
    t = norm((r.get('resposta') or '') + ' ' + ((r.get('interativo') or {}).get('corpo') or ''))
    if (r.get('interativo') or {}).get('chave') == 'pagamento':
        c.falha(f'({rot}) foi para o pagamento sem repetir o e-mail para confirmar')
        return r
    c.exige(email.lower() in t, f'({rot}) não repetiu o e-mail para confirmar: «{t[:160]}»')
    return c.diz('Sim, está certinho')


# ── abertura B2 (08/11, docs/Prompt_mari_abertura_b2_081126_1310.md): saudação fixa + 3 botões, sem o Claude ──
BOTOES_B2 = ['📍 Ver minha rua', '💰 Ver os planos', '💬 Falar com alguém']
RX_RS = r'r\$\s*\d'


def exige_abertura(c, r, inicio, rot):
    it = r.get('interativo') or {}
    c.exige(it.get('chave') == 'abertura', f'({rot}) 1ª resposta sem a abertura B2 com botões: {it or (r.get("resposta") or "")[:120]}')
    corpo = it.get('corpo') or ''
    c.exige(corpo.startswith(inicio) or corpo.startswith(inicio.replace('😊', '💚')),
            f'({rot}) saudação errada: «{corpo[:60]}» (esperado «{inicio.replace("😊", "💚")}…»)')
    c.exige([b.get('title') for b in it.get('botoes') or []] == BOTOES_B2, f'({rot}) botões errados: {it.get("botoes")}')
    c.exige(all(len(b.get('title') or '') <= 20 for b in it.get('botoes') or []), f'({rot}) título de botão com mais de 20 caracteres')
    c.exige(r.get('modelo') == 'abertura_b2', f'({rot}) a abertura passou pelo Claude (modelo {r.get("modelo")!r})')
    c.exige(not re.search(RX_RS, norm(it.get('corpo'))), f'({rot}) preço na abertura')
    rows = sql(f"select dados->>'abertura' ab from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1")
    c.exige(rows and rows[0].get('ab') == 'b2_081126', f'({rot}) dados.abertura não gravado: {rows}')


def cen_r(c):   # B2 sem nome ("Teste V7" não parece nome) + o cliente responde em TEXTO → o Claude segue sem saudar de novo
    r = c.diz('Oi! Vi o anúncio e quero saber se a Nio chega na minha rua.')
    exige_abertura(c, r, 'Oi, tudo bem? 😊', 'r')
    r = c.diz('Moro na Rua Sebastião Pedro da Silva, número 2')
    t = norm((r.get('resposta') or '') + ' ' + ((r.get('interativo') or {}).get('corpo') or ''))
    c.exige((r.get('interativo') or {}).get('chave') != 'abertura', '(r) repetiu a abertura depois da resposta em texto')
    c.exige('aqui e a mari' not in t, f'(r) apresentou-se de novo: «{t[:120]}»')
    c.exige('sebastiao pedro' in t, f'(r) não seguiu com a rua do cliente: «{t[:160]}»')


def cen_s(c):   # B2 com nome de pessoa no contato → "Oi, Ana, tudo bem? 😊"
    c.nome = 'Ana Paula Teste'
    r = c.diz('Vi o anúncio e queria mais informações')
    exige_abertura(c, r, 'Oi, Ana, tudo bem? 😊', 's')


def cen_t(c):   # 1ª mensagem já com CEP → sem abertura com botões, direto no fluxo do CEP (Claude)
    r = c.diz('Oi, quero a internet da Nio. Meu CEP é 36035-130')
    c.exige((r.get('interativo') or {}).get('chave') != 'abertura', '(t) mandou a abertura com botões a quem já deu o CEP')
    c.exige(r.get('modelo') != 'abertura_b2', '(t) respondeu com texto fixo da abertura')
    rows = sql(f"select cep, dados->>'abertura' ab from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1")
    c.exige(rows and str(rows[0].get('cep') or '').replace('-', '') == '36035130', f'(t) CEP não gravado: {rows}')
    c.exige(rows and not rows[0].get('ab'), f'(t) dados.abertura gravado sem abertura: {rows}')


def cen_u(c):   # toque em cada botão (sem Claude): rua e planos → pede só o CEP, sem preço; "Falar com alguém" → humano agora
    r = c.diz('Oi! Vi o anúncio e quero saber se a Nio chega na minha rua.')
    exige_abertura(c, r, 'Oi, tudo bem? 😊', 'u')
    r = c.diz('📍 Ver minha rua')
    t = norm(r.get('resposta'))
    c.exige('me manda so o seu cep' in t and 'rua e o bairro' in t, f'(u) "Ver minha rua" sem o texto fixo: «{t[:120]}»')
    c.exige(r.get('modelo') == 'abertura_b2', f'(u) "Ver minha rua" passou pelo Claude ({r.get("modelo")!r})')
    rows = sql(f"select dados->>'abertura_botao' b from mari_conversas where telefone = '{c.tel}' order by created_at desc limit 1")
    c.exige(rows and rows[0].get('b') == 'rua', f'(u) dados.abertura_botao não gravado: {rows}')
    r = c.diz('💰 Ver os planos')
    t = norm(r.get('resposta'))
    c.exige('600 mega a 1 giga' in t and 'cep' in t, f'(u) "Ver os planos" sem o texto fixo: «{t[:120]}»')
    c.exige(not re.search(RX_RS, t), '(u) preço antes da cidade')
    h = type(c)('u2', int(c.tel[-3:]) + 1, c.nome)
    r = h.diz('Oi, vi o anúncio')
    exige_abertura(h, r, 'Oi, tudo bem? 😊', 'u2')
    r = h.diz('💬 Falar com alguém')
    h.exige((r.get('handoff') or {}).get('motivo') == 'pedido_humano', f'(u2) "Falar com alguém" sem handoff humano: {r.get("handoff")}')
    h.exige('ja chamei nosso consultor' in norm(r.get('resposta')), f'(u2) resposta fixa errada: «{(r.get("resposta") or "")[:100]}»')
    c.falhas += h.falhas
    c.log += h.log


CENARIOS = {'r': (16, cen_r), 's': (17, cen_s), 't': (18, cen_t), 'u': (19, cen_u), 'p': (14, cen_p), 'o': (13, cen_o), 'm': (11, cen_m), 'n': (12, cen_n), 'l': (10, cen_l),'a': (1, cen_a), 'c': (2, cen_c), 'd': (3, cen_d), 'e': (4, cen_e), 'g': (5, cen_g), 'h': (6, cen_h), 'i': (7, cen_i), 'j': (8, cen_j), 'k': (9, cen_k)}

def relatorio(res):
    print('\n── tokens e custo (estimativa pelos preços da tabela PRECOS) ──')
    print(f"{'conv':<5}{'modelo':<18}{'falas':>6}{'cham':>6}{'input':>9}{'c.write':>9}{'c.read':>10}{'output':>8}{'%cache':>8}{'US$':>9}")
    g = {k: 0 for k in TIPOS}
    g.update(chamadas=0, custo=0.0, econ_tokens=0.0)
    for k, c in res.items():
        t = c.totais()
        ent = t['input_tokens'] + t['cache_creation_input_tokens'] + t['cache_read_input_tokens']
        pc = f"{100 * t['cache_read_input_tokens'] / ent:.0f}%" if ent else '-'
        mods = ','.join(sorted(m or '?' for m in t['modelos'])) or '?'
        print(f"{k:<5}{mods[:17]:<18}{t['falas']:>6}{t['chamadas']:>6}{t['input_tokens']:>9}{t['cache_creation_input_tokens']:>9}"
              f"{t['cache_read_input_tokens']:>10}{t['output_tokens']:>8}{pc:>8}{t['custo']:>9.4f}")
        for x in g:
            g[x] += t[x] if x in t else 0
    ent = g['input_tokens'] + g['cache_creation_input_tokens'] + g['cache_read_input_tokens']
    if ent:
        print(f"total: {g['chamadas']} chamadas · input {g['input_tokens']} · c.write {g['cache_creation_input_tokens']} · "
              f"c.read {g['cache_read_input_tokens']} ({100 * g['cache_read_input_tokens'] / ent:.0f}% da entrada) · "
              f"output {g['output_tokens']} · US$ {g['custo']:.4f} · por conversa US$ {g['custo'] / max(len(res), 1):.4f}")
        if g['econ_tokens']:
            print(f"corte de histórico (medido, não aplicado): ~{g['econ_tokens']:.0f} tokens de input novo a menos "
                  f"({100 * g['econ_tokens'] / max(g['input_tokens'], 1):.0f}% do input novo)")
    else:
        print('sem "uso" nas respostas — o alvo não devolve a medição (só o ensaio devolve)')


if __name__ == '__main__':
    if not SEGREDO:
        sys.exit('MARI_TESTE_SECRET ausente')
    escolha = [a for a in sys.argv[1:] if a in CENARIOS]
    if not escolha:
        sys.exit('nenhum cenário escolhido — nada rodou (bateria custa API).\n'
                 f'cenários: {" ".join(sorted(CENARIOS))}  ·  ex.: python tests/mari_v7_bateria.py c k --max 2')
    if '--max' in sys.argv:
        i = sys.argv.index('--max')
        try:
            escolha = escolha[:int(sys.argv[i + 1])]
        except (IndexError, ValueError):
            sys.exit('--max N: N inteiro')
    print(f'cenários: {" ".join(escolha)}')
    res = {}
    try:
        sql(f"select public.mari_limpar_teste('{PREFIXO}')", escrita=True)
        for k in escolha:
            n, f = CENARIOS[k]
            c = Conversa(k, n)
            res[k] = c
            try:
                f(c)
            except Exception as e:
                c.falha(f'exceção: {e}')
            print(f"({k}) {'VERDE' if not c.falhas else 'FALHOU'}" + ''.join(f'\n    - {x}' for x in c.falhas))
    finally:
        # Sempre: grava o que houve e limpa os telefones de teste, também em erro ou Ctrl+C.
        os.makedirs(os.path.join(REPO, 'tests', 'saida'), exist_ok=True)
        with open(os.path.join(REPO, 'tests', 'saida', 'mari_v7_bateria.json'), 'w', encoding='utf-8') as fh:
            json.dump({k: {'falhas': c.falhas, 'totais': {**c.totais(), 'modelos': sorted(m or '?' for m in c.totais()['modelos'])},
                           'log': c.log} for k, c in res.items()}, fh, ensure_ascii=False, indent=1)
        if '--sem-teardown' not in sys.argv:
            sql(f"select public.mari_limpar_teste('{PREFIXO}')", escrita=True)
            print('teardown: mari_limpar_teste ok')
    relatorio(res)
    verdes = sum(1 for c in res.values() if not c.falhas)
    print(f'{verdes}/{len(res)} verdes')
