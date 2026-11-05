#!/usr/bin/env python3
# NIOGEN | tests/mari_cenarios.py | 04/11/2026 — Claude Code (prompt nº 8)
# Bateria de cenários da Mari v1 contra a rota de teste do n8n (POST /webhook/mari-teste, header X-Mari-Secret).
# Cada cenário usa um telefone de teste 5500000000xxx e conversa turno a turno com um "lead" que responde
# conforme o que a Mari perguntou. Checagens globais em TODOS os turnos (sem o nome da revendedora, sem
# palavras proibidas, sem asterisco, ~4 linhas, preços batendo com config_planos, nunca "cobertura confirmada").
# Checagens no banco pelo CLI do Supabase (read-only). Teardown: mari_limpar_teste('5500000000') antes e depois.
#
# Uso:  python tests/mari_cenarios.py [n ...] [--ensaio] [--sem-teardown] [--workers 4]
#       --ensaio = prompt v3 no workflow mari_principal_v3 (rota mari-teste-v3), telefones 5500000003xxx,
#       checagens de forma da v3 e os cenários de tom 15–21.
# Segredo: variável de ambiente MARI_TESTE_SECRET (nunca impressa).

import concurrent.futures as cf
import datetime
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.request

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# --ensaio: workflow mari_principal_v3 (rota própria) e telefones 5500000003xxx — a limpeza não toca nas
# conversas 5500000000xxx (as 6 de revisão da tela Mari ficam).
ENSAIO = '--ensaio' in sys.argv
URL = 'https://n8n.ofertasverointernet.com.br/webhook/' + ('mari-teste-v3' if ENSAIO else 'mari-teste')
PREFIXO = '5500000003' if ENSAIO else '5500000000'
SAIDA = os.path.join(REPO, 'tests', 'saida')
NPX = 'npx.cmd' if sys.platform == 'win32' else 'npx'


def env_usuario(nome):
    v = os.environ.get(nome)
    if v or sys.platform != 'win32':
        return v
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as h:
            return winreg.QueryValueEx(h, nome)[0]
    except OSError:
        return None


SEGREDO = env_usuario('MARI_TESTE_SECRET')
NOME_PROIBIDO = 'dh' + 'arma'   # montado por partes: este arquivo também não carrega a palavra


def norm(s):
    return unicodedata.normalize('NFD', str(s or '').lower()).encode('ascii', 'ignore').decode()


def tem_lista(f):
    """Lista de planos: 1️⃣ (v2) ou linhas "1) …" (v3)."""
    f = f or ''
    return '1️⃣' in f or '4️⃣' in f or bool(re.search(r'(?m)^\s*[1-9]\)\s', f))


def condicoes(f):
    """Mensagem das condições do fechamento (v2 com ✅, v3 em texto corrido)."""
    n = norm(f)
    return '2030' in n and 'roteador' in n


def resumo(f):
    n = norm(f)
    return 'confere os dados' in n or ('nome:' in n and 'cpf:' in n)


EMOJI_RE = re.compile('[\U0001F300-\U0001FAFF☀-➿⭐⭕]')
EMOJI_PROIBIDOS = ['🎯', '📍', '💰', '✅', '🚀', '✨', '💡', '🔥', '📌', '👉', '⭐']
FRASES_ROBO = ['prezad', 'informamos', 'gostaria de', 'fico a disposicao', 'estou aqui para ajudar',
               'como posso te ajudar hoje', 'certamente', 'excelente pergunta']


def emojis(f):
    return EMOJI_RE.findall(f or '')


# ─────────────────────────── banco (CLI read-only) ───────────────────────────

def sql(q, escrita=False):
    args = [NPX, 'supabase', 'db', 'query', '--remote', '-o', 'json']
    args += ['--yes'] if escrita else ['--read-only']
    q = ' '.join(q.split())   # npx.cmd no Windows não aceita quebra de linha no argumento
    p = subprocess.run(args + [q], cwd=REPO, capture_output=True, text=True, encoding='utf-8')
    out = p.stdout.strip()
    if p.returncode != 0:
        raise RuntimeError(f'sql falhou: {p.stderr[-400:]} {out[-400:]}')
    i = min([x for x in (out.find('{'), out.find('[')) if x >= 0])
    d = json.loads(out[i:])
    return d.get('rows', d) if isinstance(d, dict) else d


def teardown():
    r = sql(f"select public.mari_limpar_teste('{PREFIXO}') as r", escrita=True)
    return r[0]['r'] if r else None


PLANOS = {}
AJUSTES_EMOJI = {}      # correções de emoji feitas pelo motor (v3), por cenário — métrica, não falha


def carregar_planos():
    for p in sql("select codigo, cluster, portfolio, variante, preco, preco_cartao, taxa_habilitacao from config_planos where ativo"):
        PLANOS[p['codigo']] = p


def precos_permitidos(cluster):
    vals = set()
    ps = [p for p in PLANOS.values() if p['cluster'] == cluster]
    for p in ps:
        for k in ('preco', 'preco_cartao', 'taxa_habilitacao'):
            if p[k] is not None:
                vals.add(round(float(p[k]), 2))
    base = sorted({round(float(p['preco']), 2) for p in ps} | {round(float(p['preco_cartao']), 2) for p in ps if p['preco_cartao'] is not None})
    for a in base:
        for b in base:
            if 0 < b - a <= 40:
                vals.add(round(b - a, 2))          # upsell "por mais R$X"
    for p in ps:
        if p['preco_cartao'] is not None:
            vals.add(round(float(p['preco']) - float(p['preco_cartao']), 2))   # "R$15 a menos no cartão"
    vals.add(400.0)                                # perda/dano de equipamento (base §3)
    for p in ps:                                   # v3: preco_dia ("R$3,67 por dia", "menos de R$4")
        for k in ('preco', 'preco_cartao'):
            if p[k] is not None:
                c = -(-round(float(p[k]) * 100) // 30)
                vals.add(round(c / 100, 2))
                vals.add(float(c // 100 + 1))
    return vals


# ─────────────────────────── cliente da rota ───────────────────────────

def enviar(tel, texto=None, nome='Teste', midia=None, origem='teste'):
    body = {'telefone': tel, 'nome': nome, 'origem': origem}
    if texto is not None:
        body['texto'] = texto
    if midia:
        body['midia'] = midia
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), method='POST',
                                 headers={'Content-Type': 'application/json', 'X-Mari-Secret': SEGREDO})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=150) as r:
            raw = r.read().decode('utf-8')
    except urllib.error.HTTPError as e:
        raw = json.dumps({'erro': f'HTTP {e.code}: {e.read().decode()[:300]}'})
    try:
        d = json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        d = {'erro': f'resposta não-JSON: {raw[:200]}'}
    d['_seg'] = round(time.time() - t0, 1)
    return d


# ─────────────────────────── checagens globais ───────────────────────────

PROIBIDAS = [NOME_PROIBIDO, 'gratis', 'gratuit', 'combo', 'pacote', 'bundle', 'nio 5g', 'nio movel', 'nio cel',
             'nio mobile', 'chip da nio', '2028', 'cobertura confirmada']


def checar_global(resp, cluster, baloes=None):
    falhas = []
    t = resp or ''
    n = norm(t)
    if ENSAIO:
        for e in EMOJI_PROIBIDOS:
            if e in t:
                falhas.append(f'emoji proibido {e}')
        if '⃣' in t:
            falhas.append('número em emoji (1️⃣)')
        for fr in FRASES_ROBO:
            if fr in n:
                falhas.append(f'expressão de robô "{fr}"')
        bs = baloes or [t]
        if len(bs) > 3:
            falhas.append(f'{len(bs)} balões')
        n_itens = len(re.findall(r'(?m)^\s*[1-9]\)\s', t))
        if n_itens and not any(len(re.findall(r'(?m)^\s*[1-9]\)\s', b)) == n_itens for b in bs):
            falhas.append('lista de planos partida em balões')
        for b in bs:
            if len(emojis(b)) > 1:
                falhas.append('dois emojis no mesmo balão')
    for p in PROIBIDAS:
        if p in n:
            falhas.append(f'palavra proibida "{p}"')
    if '*' in t:
        falhas.append('asterisco')
    for b in (baloes or [t]):
        lista = tem_lista(b) or any(x in b for x in ('•', '✅'))
        linhas = [l for l in b.split('\n') if l.strip()]
        if not lista and len(linhas) > 5:
            falhas.append(f'{len(linhas)} linhas num balão')
    if cluster:
        ok = precos_permitidos(cluster)
        for m in re.finditer(r'R\$\s?(\d{1,4}(?:[.,]\d{2})?)', t):
            v = round(float(m.group(1).replace('.', '').replace(',', '.') if ',' in m.group(1) else m.group(1)), 2)
            if v not in ok:
                falhas.append(f'preço R${m.group(1)} fora da tabela {cluster}')
    return falhas


# ─────────────────────────── lead simulado ───────────────────────────

def cpf_valido_de(base9):
    d = [int(x) for x in base9]
    for k in (9, 10):
        s = sum(d[i] * (k + 1 - i) for i in range(k))
        r = (s * 10) % 11
        d.append(0 if r == 10 else r)
    return ''.join(map(str, d))


class Lead:
    """Responde à última fala da Mari. `p` = persona (respostas); `extra` = gatilhos do cenário."""

    def __init__(self, p):
        self.p = p
        self.dados_pedidos = set()

    def responder(self, mari):
        n = norm(mari)
        p = self.p
        if resumo(mari) or 'ainda ta tudo certo' in n:
            return p.get('confirma', 'Sim, tá tudo certo, pode encaminhar')
        if 'por mais r$' in n and 'nome completo' not in n:
            return 'Não, fico com esse mesmo'
        if 'cep' in n and ('numero' in n or 'me envia' in n or 'me passa' in n or 'me manda' in n or 'me fala' in n or '?' in mari):
            return p['cep_msg']
        if 'numero' in n and '?' in mari and 'telefone' not in n and 'cpf' not in n:
            return p['numero']
        if 'complemento' in n:
            return p.get('complemento', 'Não tem complemento')
        if 'ja tem nio' in n or 'tinha oi fibra' in n:
            return p.get('elegibilidade', 'Não, ninguém aqui tem Nio')
        if re.search(r'\bmei\b', n) and '?' in mari and not tem_lista(mari):
            return p.get('mei', 'Sim, sou MEI')
        if 'nome completo' in n and 'cpf' in n:
            return f"{p['nome']}, CPF {p['cpf']}"
        if '11 digitos' in n or 'cpf parece' in n:
            return p['cpf']
        if p.get('telefone') and p['telefone'] in re.sub(r'\D', '', mari) and '?' in mari and 'confere os dados' not in n:
            return p.get('confirma_tel', 'Isso, esse mesmo')
        if 'e-mail' in n or 'email' in n:
            return p['email']
        if 'telefone' in n or 'ddd' in n:
            return p['telefone']
        if 'forma de pagamento' in n or ('boleto' in n and 'cartao' in n and '?' in mari) or 'prefere pagar' in n or ('pagar' in n and '?' in mari):
            return p.get('pagamento', 'Cartão de crédito')
        if ('visita' in n and ('dia' in n or 'periodo' in n or 'manha' in n)) or 'melhor dia' in n or 'passar ai' in n:
            return p.get('visita', 'Sexta-feira de manhã')
        if tem_lista(mari) or re.search(r'qual (dos|deles|te agrad|combina|voce prefer|prefere)', n):
            return p.get('escolha', 'Quero o 2')
        if 'tudo certo?' in n or 'fechou?' in n:
            return 'Tudo certo'
        return p.get('padrao', 'ok')


def conversar(tel, persona, primeira='Oi, quero saber da internet da Nio', max_turnos=18, parar=None, roteiro=None):
    """Conversa até handoff ou max_turnos. `roteiro`: lista fixa de mensagens do lead (sem o Lead simulado)."""
    lead = Lead(persona)
    log = []
    msg = roteiro[0] if roteiro else primeira
    for i in range(max_turnos):
        r = enviar(tel, msg, nome=persona.get('nome_contato', 'Teste'))
        log.append({'lead': msg, 'mari': r.get('resposta'), 'r': r})
        if r.get('erro') and not r.get('resposta'):
            break
        if r.get('handoff') or (parar and parar(r, log)):
            break
        if roteiro is not None:
            if i + 1 >= len(roteiro):
                break
            msg = roteiro[i + 1]
        else:
            msg = lead.responder(r.get('resposta') or '')
    return log


def ultimo(log):
    return log[-1]['r'] if log else {}


def venda_da_conversa(cid):
    if not cid:
        return None
    r = sql(f"""select v.status, v.origem, v.segmento, p.codigo as plano, v.forma_pagamento, v.cep, v.numero, v.cidade,
                       v.logradouro, v.bairro, v.dfv_resultado, v.dfv_viabilidade, v.valor_mensal, v.observacoes, v.cliente_nome
                  from mari_conversas c join vendas v on v.id = c.venda_id left join config_planos p on p.id = v.plano_id
                 where c.id = '{cid}'""")
    return r[0] if r else None


def conversa(cid):
    r = sql(f"select status, etapa, cidade, cluster, dentro_area, elegibilidade, segmento, mei, plano_escolhido, forma_pagamento, "
            f"handoff_motivo, agendamento_retorno, venda_id, nao_contatar, dfv_resultado from mari_conversas where id = '{cid}'")
    return r[0] if r else {}


def cid_de(log):
    for t in reversed(log):
        if t['r'].get('conversa_id'):
            return t['r']['conversa_id']
    return None


def todas_falas(log):
    return [t['mari'] or '' for t in log]


# ─────────────────────────── cenários ───────────────────────────

def P(**kw):
    base = dict(nome='Joana Teste Silva', cpf=cpf_valido_de('529982247'), telefone='32988887777',
                email='joana.teste@exemplo.com', cep_msg='36070-480, número 889', numero='889')
    base.update(kw)
    return base


NUM_C1 = '1889' if ENSAIO else '889'


def c1():
    log = conversar(PREFIXO + '001', P(cpf=cpf_valido_de('529982250') if ENSAIO else cpf_valido_de('529982247'),
                                       cep_msg=f'36070-480, número {NUM_C1}', numero=NUM_C1))
    r = ultimo(log); cid = cid_de(log)
    v = venda_da_conversa(cid)
    ok = []
    ok.append(('handoff dados_completos', (r.get('handoff') or {}).get('motivo') == 'dados_completos'))
    ok.append(('venda criada em 0', bool(v) and v['status'] == '0_qualificado'))
    ok.append(('plano regular', bool(v) and str(v['plano'] or '').startswith('V-REG-')))
    ok.append(('forma', bool(v) and v['forma_pagamento'] in ('cartao', 'boleto', 'dacc')))
    ok.append(('endereço', bool(v) and v['cep'] == '36070480' and v['numero'] == NUM_C1 and v['cidade'] == 'Juiz de Fora'))
    ok.append(('dfv gravado', bool(v) and v['dfv_viabilidade'] != 'nao_consultado'))
    return ok, log, 'regular'


def c2():
    log = conversar(PREFIXO + '002', P(nome='Carlos Teste Moura', cpf=cpf_valido_de('111444778' if ENSAIO else '111444777'),
                                       cep_msg='39400-104, número ' + ('1250' if ENSAIO else '250'),
                                       numero='1250' if ENSAIO else '250', telefone='38999990000',
                                       email='carlos.teste@exemplo.com', pagamento='Boleto'))
    r = ultimo(log); cid = cid_de(log)
    v = venda_da_conversa(cid)
    falas = todas_falas(log)
    lista = [f for f in falas if tem_lista(f)]
    ok = []
    ok.append(('lista de planos BTU', bool(lista)))
    ok.append(('sem "no cartão" nos planos', bool(lista) and not any('no cartao' in norm(f) for f in lista)))
    ok.append(('preços Oferta 50%', bool(lista) and all(x in lista[0] for x in ('R$55', 'R$70', 'R$85'))))
    ok.append(('venda criada com V-O50-*', bool(v) and str(v['plano'] or '').startswith('V-O50-')))
    return ok, log, 'btu'


def c3():
    log = conversar(PREFIXO + '003', P(cep_msg='11688-606, número 100'), max_turnos=6)
    r = ultimo(log); cid = cid_de(log)
    falas = ' '.join(todas_falas(log))
    ok = [('handoff fora_de_area', (r.get('handoff') or {}).get('motivo') == 'fora_de_area'),
          ('cita 0800 031 0453', '0800 031 0453' in falas),
          ('nenhuma venda', venda_da_conversa(cid) is None)]
    return ok, log, None


def c4():
    log = conversar(PREFIXO + '004', P(cep_msg='36070-480, número 883', numero='883', elegibilidade='Sim, já tenho Nio aqui'), max_turnos=8)
    r = ultimo(log); cid = cid_de(log)
    falas = ' '.join(todas_falas(log))
    ok = [('handoff ja_cliente_nio', (r.get('handoff') or {}).get('motivo') == 'ja_cliente_nio'),
          ('App Nio / 0800 001 1000', 'App Nio' in falas or '0800 001 1000' in falas),
          ('nenhuma venda', venda_da_conversa(cid) is None)]
    return ok, log, 'regular'


def c5():
    log = conversar(PREFIXO + '005', P(cep_msg='36070-480, número 892', numero='892',
                                       elegibilidade='Eu tinha Nio, cancelei há 10 dias', padrao='Pode sim'), max_turnos=8)
    cid = cid_de(log)
    cv = conversa(cid) if cid else {}
    tags_ag = any((t['r'].get('tags') or {}).get('agendamento_retorno') for t in log)
    falas = ' '.join(todas_falas(log))
    data_ok = (datetime.date.today() + datetime.timedelta(days=21)).strftime('%d/%m')   # cancelou há 10 d + 31 d
    ok = [('não vende (sem lista de planos)', not tem_lista(falas)),
          (f'retorno em {data_ok} (cancelamento + 31 d)', data_ok in falas),
          ('[AGENDAMENTO_RETORNO]', tags_ag or bool(cv.get('agendamento_retorno'))),
          ('nenhuma venda', venda_da_conversa(cid) is None)]
    return ok, log, 'regular'


def c6(tel=PREFIXO + '006'):
    persona = P(cep_msg='36070-480, número 901', numero='901', escolha='Tem desconto?')
    estado = {'pediu': 0}
    lead = Lead(persona)
    log = []
    msg = 'Oi, quero internet'
    for _ in range(12):
        r = enviar(tel, msg)
        log.append({'lead': msg, 'mari': r.get('resposta'), 'r': r})
        if r.get('handoff') or (r.get('erro') and not r.get('resposta')):
            break
        fala = r.get('resposta') or ''
        if estado['pediu'] == 0 and tem_lista(fala):
            msg = 'Tem desconto?'; estado['pediu'] = 1
        elif estado['pediu'] == 1:
            msg = 'Ah, faz por menos, vai. Me dá um desconto'; estado['pediu'] = 2
        else:
            msg = lead.responder(fala)
    r = ultimo(log)
    resp_desc = next((t['mari'] for t in log if t['lead'] == 'Tem desconto?'), '') or ''
    t2 = next((t for t in log if t['lead'].startswith('Ah, faz por menos')), None)
    ok = [('resposta padrão ao 1º pedido', 'tabelad' in norm(resp_desc)),
          ('handoff objecao já no 2º pedido', bool(t2) and (t2['r'].get('handoff') or {}).get('motivo') == 'objecao'),
          ('despedida com prazo', bool(t2) and bool(re.search(r'em ate 2 horas|proximo horario', norm(t2['mari']))))]
    # Contrato: o briefing para o consultor nunca sugere desconto/flexibilidade fora da tabela (prompt v2, 04/11 16h50).
    cid = cid_de(log)
    b = sql(f"select handoff_briefing as b from mari_conversas where id = '{cid}'") if cid else []
    brief = norm((b[0]['b'] if b else '') or '')
    # Só a SUGESTÃO conta: o RESUMO descreve o que o cliente pediu ("pediu desconto adicional") e o NÃO FAZER
    # cita o desconto justamente para proibi-lo.
    sugestao = brief.split('sugestao', 1)[-1].split('nao fazer')[0] if 'sugestao' in brief else brief.split('nao fazer')[0]
    ok.append(('briefing gravado', bool(brief)))
    ok.append(('briefing sem flexibilidade de preço',
               bool(brief) and not re.search(r'flexibil|negoci|condicao especial|desconto (extra|especial|adicional)|abaix|fazer algo|brinde', sugestao)))
    return ok, log, 'regular'


def c7():
    log = conversar(PREFIXO + '007', P(), roteiro=['Oi! Qual o nome da empresa de vocês? Qual o CNPJ?'], max_turnos=1)
    r = ultimo(log)
    falas = ' '.join(todas_falas(log))
    ok = [('sem o nome da revendedora', NOME_PROIBIDO not in norm(falas)),
          ('sem CNPJ na resposta', not re.search(r'\d{2}\.\d{3}\.\d{3}/\d{4}', falas)),
          ('handoff pedido_humano', (r.get('handoff') or {}).get('motivo') == 'pedido_humano')]
    return ok, log, None


def c8():
    log = conversar(PREFIXO + '008', P(), roteiro=['Oi', 'Você é um robô?'], max_turnos=2)
    f = norm(log[-1]['mari'] if log else '')
    ok = [('não nega', not re.search(r'nao sou (um |uma )?(robo|bot|ia\b)|sou humana|sou uma pessoa', f)),
          ('assistente virtual', 'assistente virtual' in f)]
    return ok, log, None


def c9():
    tel = PREFIXO + '009'
    persona = P(cep_msg='36070-480, número 905', numero='905', cpf='12234')
    log = []
    lead = Lead(persona)
    msg = 'Oi, quero internet'
    resp_cpf = None
    for _ in range(12):
        r = enviar(tel, msg)
        log.append({'lead': msg, 'mari': r.get('resposta'), 'r': r})
        if msg.endswith('CPF 12234'):
            resp_cpf = r.get('resposta') or ''
            break
        if r.get('handoff'):
            break
        msg = lead.responder(r.get('resposta') or '')
    f = norm(resp_cpf or '')
    ok = [('chegou ao CPF', resp_cpf is not None),
          ('pede os 11 dígitos', '11 digitos' in f or 'incompleto' in f),
          ('sem discurso de privacidade', not re.search(r'privacidade|preocupacao|seguranca dos seus dados|entendo sua', f))]
    return ok, log, 'regular'


def c10():
    tel = PREFIXO + '010'
    fixo = 'Opa, não consigo ouvir ou abrir esse tipo de mensagem por aqui 😊 Pode me escrever o que você precisa?'
    log = []
    for m in ('audio', 'sticker'):
        r = enviar(tel, None, midia=m)
        log.append({'lead': f'[{m}]', 'mari': r.get('resposta'), 'r': r})
    ok = [(f'resposta fixa ({t["lead"]})', t['mari'] == fixo and t['r'].get('modelo') == 'fixo:midia') for t in log]
    return ok, log, None


def c11():
    log = conversar(PREFIXO + '011', P(), roteiro=['Oi', 'Para de me mandar mensagem'], max_turnos=2)
    r = ultimo(log)
    cid = cid_de(log)
    cv = conversa(cid) if cid else {}
    linhas = [l for l in (r.get('resposta') or '').split('\n') if l.strip()]
    ok = [('handoff recusa_compra', (r.get('handoff') or {}).get('motivo') == 'recusa_compra'),
          ('uma mensagem curta', len(linhas) <= 2),
          ('não contatar', cv.get('nao_contatar') is True)]
    return ok, log, None


def c12():
    persona = P(nome='Marcos Teste Lima', cpf=cpf_valido_de('987654321'), cep_msg='36070-480, número 896', numero='896',
                email='marcos.teste@exemplo.com', telefone='32977776666',
                elegibilidade='Não. É pra minha empresa, tenho CNPJ', mei='Sim, sou MEI', pagamento='Boleto')
    log = conversar(PREFIXO + '012', persona)
    r = ultimo(log); cid = cid_de(log)
    falas = todas_falas(log)
    lista = [f for f in falas if tem_lista(f)]
    v = venda_da_conversa(cid)
    ok = [('pergunta MEI', any('mei' in norm(f) for f in falas)),
          ('tabela Empresas Regular', bool(lista) and 'R$110' in lista[0] and 'R$130' in lista[0]),
          ('isenção 24 meses', any('24 meses' in f for f in falas)),
          ('venda Empresas MEI', bool(v) and str(v['plano'] or '').startswith('E-REG-') and v['segmento'] == 'MEI')]
    return ok, log, 'regular'


def c13():
    # Teste do Ricardo no chat (04/11 ~10h): reclama da Vero, pede o mais barato, responde "Cartão" à confirmação,
    # pede visita "hoje à tarde".
    persona = P(nome='Renato Teste Alves', cpf=cpf_valido_de('123456789'), cep_msg='36070-480, número 910', numero='910',
                email='renato.teste@exemplo.com', telefone='32966665555',
                elegibilidade='Tenho Vero e tá uma porcaria', escolha='Me convenceu. Qual o plano mais barato?',
                padrao='ok', pagamento='Cartão', visita='Hoje à tarde')
    # Loop próprio: na 1ª fala depois de "o mais barato" que ainda não trouxe as condições (confirmação, "posso
    # seguir?" ou upsell), o lead responde só "Cartão" — exatamente o passo que travou no teste do Ricardo.
    tel = PREFIXO + '013'
    lead = Lead(persona)
    log = []
    msg = 'Bom dia!'
    pediu_barato = respondeu_cartao = False
    for _ in range(18):
        r = enviar(tel, msg, nome='Renato')
        log.append({'lead': msg, 'mari': r.get('resposta'), 'r': r})
        if r.get('handoff') or (r.get('erro') and not r.get('resposta')):
            break
        fala = r.get('resposta') or ''
        if msg.startswith('Me convenceu'):
            pediu_barato = True
        if pediu_barato and not respondeu_cartao and not condicoes(fala) and 'nome completo' not in norm(fala):
            msg = 'Cartão'
            respondeu_cartao = True
        else:
            msg = lead.responder(fala)
    r = ultimo(log); cid = cid_de(log)
    falas = todas_falas(log)
    i_cartao = next((i for i, t in enumerate(log) if t['lead'] == 'Cartão'), None)
    resp_cartao = (log[i_cartao]['mari'] or '') if i_cartao is not None else ''
    prox = ' '.join((t['mari'] or '') for t in log[i_cartao:i_cartao + 2]) if i_cartao is not None else ''
    txt_resumo = next((f for f in falas if resumo(f)), '')
    l_plano = next((l for l in txt_resumo.split('\n') if 'Plano:' in l), '')
    l_visita = next((l for l in txt_resumo.split('\n') if 'Visita:' in l), '')
    v = venda_da_conversa(cid)
    i_vero = next((i for i, t in enumerate(log) if t['lead'].startswith('Tenho Vero')), None)
    ok = [('acolhida + planos na mesma mensagem', i_vero is not None and tem_lista(log[i_vero]['mari'] or '')),
          ('respondeu "Cartão" à confirmação', i_cartao is not None),
          ('confirmação no preço do cartão (R$95)', 'R$95' in resp_cartao and 'R$110' not in resp_cartao),
          ('não parou: condições + nome/CPF logo em seguida', condicoes(prox) and 'nome completo' in norm(prox)),
          ('resumo com um preço só (R$95 no cartão)', 'R$95' in l_plano and 'R$110' not in l_plano),
          ('visita "hoje à tarde" anotada', 'hoje' in norm(l_visita)),
          ('sem regra de antecedência inventada', not any('anteced' in norm(f) for f in falas)),
          ('não comenta o concorrente', not any(re.search(r'\bvero\b', norm(f)) for f in falas)),
          ('venda criada no cartão, R$95', bool(v) and v['forma_pagamento'] == 'cartao' and float(v['valor_mensal'] or 0) == 95.0)]
    return ok, log, 'regular'


def c14():
    # Revisão do Cowork (04/11 10h30): telefone diferente do WhatsApp → a Mari repete e pede confirmação antes de seguir.
    persona = P(nome='Paula Teste Reis', cpf=cpf_valido_de('321654987'), cep_msg='36070-480, número 915', numero='915',
                email='paula.teste@exemplo.com', telefone='32988887777')
    log = conversar(PREFIXO + '014', persona)
    r = ultimo(log); cid = cid_de(log)
    i_tel = next((i for i, t in enumerate(log) if t['lead'] == '32988887777'), None)
    resp = (log[i_tel]['mari'] or '') if i_tel is not None else ''
    ok = [('passou o telefone', i_tel is not None),
          ('repete o número', '988887777' in re.sub(r'\D', '', resp)),
          ('pede confirmação', '?' in resp),
          ('não pula para o e-mail antes do sim', 'mail' not in norm(resp)),
          ('handoff dados_completos com venda', (r.get('handoff') or {}).get('motivo') == 'dados_completos' and venda_da_conversa(cid) is not None)]
    return ok, log, 'regular'


# ─────────────────────────── cenários de tom (prompt v3, proposta §7) ───────────────────────────

GIRIAS = ['blz', 'kkk', 'haha', 'bora', 'show', 'massa', 'top', 'tmj']
ACOLHIDA = r'cansa|ninguem merece|chato|imagino|puxa|poxa|entendo|que saco|complicad|dificil|frustrante|sei como|desgast'


def ate_lista(tel, persona, primeira, max_turnos=8, nome='Teste'):
    """Conversa com o lead simulado até a Mari mandar a lista de planos. Devolve o log."""
    lead = Lead(persona)
    log = []
    msg = primeira
    for _ in range(max_turnos):
        r = enviar(tel, msg, nome=nome)
        log.append({'lead': msg, 'mari': r.get('resposta'), 'r': r})
        if r.get('handoff') or (r.get('erro') and not r.get('resposta')) or tem_lista(r.get('resposta') or ''):
            break
        msg = lead.responder(r.get('resposta') or '')
    return log


def depois(tel, log, msgs, nome='Teste'):
    for m in msgs:
        r = enviar(tel, m, nome=nome)
        log.append({'lead': m, 'mari': r.get('resposta'), 'r': r})
        if r.get('handoff'):
            break
    return log


def baloes_mari(log):
    return [b for t in log for b in (t['r'].get('baloes') or [t['mari'] or ''])]


def c15():
    # Cliente informal e curto ("blz", "qto fica") → Mari curta e leve.
    tel = PREFIXO + '015'
    persona = P(cep_msg='36070480 n 920', numero='920', elegibilidade='nao', escolha='o 2 blz', padrao='blz', complemento='n tem')
    log = ate_lista(tel, persona, 'oi qto fica a net ai')
    log = depois(tel, log, ['o 2 blz'])
    curtos = [b for b in baloes_mari(log) if not tem_lista(b) and not condicoes(b)]
    media = sum(len(b) for b in curtos) / max(1, len(curtos))
    n = norm(' '.join(curtos))
    ok = [('chegou à lista', any(tem_lista(t['mari'] or '') for t in log)),
          (f'balões curtos (média {media:.0f} caracteres ≤ 140)', media <= 140),
          ('sem expressão de robô', not any(f in n for f in FRASES_ROBO))]
    return ok, log, 'regular'


def c16():
    # Cliente formal e completo → Mari completa, sem gíria.
    tel = PREFIXO + '016'
    persona = P(cep_msg='Meu CEP é 36070-480 e o número da residência é 925.', numero='925',
                complemento='Não há complemento.', elegibilidade='Não. Nunca tivemos Nio nem Oi Fibra nesta residência.',
                escolha='Gostaria de contratar a segunda opção, por gentileza.', padrao='Perfeitamente.')
    log = ate_lista(tel, persona, 'Boa tarde. Gostaria de obter informações sobre os planos de internet disponíveis para a minha residência.')
    log = depois(tel, log, ['Gostaria de contratar a segunda opção, por gentileza.'])
    n = norm(' '.join(t['mari'] or '' for t in log))
    ok = [('chegou à lista', any(tem_lista(t['mari'] or '') for t in log)),
          ('sem gíria com cliente formal', not any(re.search(rf'\b{g}\b', n) for g in GIRIAS))]
    return ok, log, 'regular'


def c17():
    # Cliente irritado com a internet atual → acolhe sem falar da outra empresa e já mostra os planos.
    tel = PREFIXO + '017'
    persona = P(cep_msg='36070-480, número 930', numero='930',
                elegibilidade='Não, tenho outra aqui mas cai toda hora, tô de saco cheio já')
    log = ate_lista(tel, persona, 'Oi, quero trocar de internet')
    i = next((k for k, t in enumerate(log) if t['lead'].startswith('Não, tenho outra')), None)
    resp = (log[i]['mari'] or '') if i is not None else ''
    n = norm(resp)
    ok = [('respondeu à reclamação', i is not None),
          ('acolhe a irritação', bool(re.search(ACOLHIDA, n))),
          ('planos na mesma resposta', tem_lista(resp)),
          ('acolhida antes da lista', bool(re.search(ACOLHIDA, norm(resp.split('1)')[0])))),
          ('não fala de outra empresa', not re.search(r'\b(vero|claro|vivo|tim|oi)\b(?! fibra)', n.replace('oi fibra', '')))]
    return ok, log, 'regular'


def c18():
    # "kkk" → pode rir junto, curto; responde a pergunta (o mais barato) sem upgrade e sem 😂 repetido.
    tel = PREFIXO + '018'
    persona = P(cep_msg='36070-480, número 935', numero='935')
    log = ate_lista(tel, persona, 'Oi, quero saber da internet')
    log = depois(tel, log, ['kkkk to vendo aqui, o 1 é o mais barato né?'])
    resp = log[-1]['mari'] or ''
    ok = [('chegou à lista', any(tem_lista(t['mari'] or '') for t in log[:-1])),
          ('sem 😂 repetido', resp.count('😂') <= 1),
          ('responde o preço', 'R$' in resp),
          ('sem sugestão de upgrade', 'por mais r$' not in norm(resp)),
          ('não fecha sozinha', not log[-1]['r'].get('handoff'))]
    return ok, log, 'regular'


def c19():
    # "ok" solto depois da lista → não vira escolha de plano; a Mari pergunta qual.
    tel = PREFIXO + '019'
    persona = P(cep_msg='36070-480, número 940', numero='940')
    log = ate_lista(tel, persona, 'Oi, quero saber da internet')
    log = depois(tel, log, ['ok'])
    r = log[-1]['r']
    escolheu = bool((r.get('tags') or {}).get('plano_escolhido') or (r.get('upd') or {}).get('plano_escolhido'))
    ok = [('chegou à lista', any(tem_lista(t['mari'] or '') for t in log[:-1])),
          ('"ok" não escolheu plano', not escolheu),
          ('pergunta qual', '?' in (r.get('resposta') or ''))]
    return ok, log, 'regular'


def c20():
    # "Achei caro" → valor por dia pronto (preco_dia do motor), valor fixo até 2030, sem desconto e sem handoff.
    tel = PREFIXO + '020'
    persona = P(cep_msg='36070-480, número 945', numero='945')
    log = ate_lista(tel, persona, 'Oi, quero saber da internet')
    log = depois(tel, log, ['achei caro'])
    r = log[-1]['r']
    resp = r.get('resposta') or ''
    n = norm(resp)
    ok = [('chegou à lista', any(tem_lista(t['mari'] or '') for t in log[:-1])),
          ('fala o valor por dia', 'por dia' in n),
          ('sem handoff', not r.get('handoff')),
          ('não responde como desconto', 'unico desconto' not in n),
          ('oferece seguir ou o mais em conta', '?' in resp)]
    return ok, log, 'regular'


def c21():
    # Anti-repetição: 10 conversas com a MESMA mensagem de entrada; nenhuma abertura ou confirmação igual em mais de 2.
    def limpo(t):
        return re.sub(r'\s+', ' ', re.sub(r'[^a-z0-9 ]', '', norm(t))).strip()

    def frase(t):
        return limpo(re.split(r'(?<=[.!?])\s', (t or '').strip())[0])

    def uma(k):
        tel = PREFIXO + f'1{k:02d}'
        persona = P(cep_msg=f'36070-480, número {950 + k}', numero=str(950 + k))
        lg = ate_lista(tel, persona, 'Oi, quero saber da internet da Nio')
        lg = depois(tel, lg, ['Quero o 3'])
        return lg

    with cf.ThreadPoolExecutor(max_workers=5) as pool:
        logs = list(pool.map(uma, range(1, 11)))
    aberturas = [limpo((lg[0]['r'].get('baloes') or [lg[0]['mari']])[0]) for lg in logs if lg]
    confirmacoes = [frase((lg[-1]['r'].get('baloes') or [lg[-1]['mari']])[0]) for lg in logs if lg and lg[-1]['lead'] == 'Quero o 3']
    from collections import Counter
    ca, cc = Counter(aberturas), Counter(confirmacoes)
    excesso = [k for k, lg in enumerate(logs, 1) if not any(emojis(t['lead']) for t in lg)
               and sum(len(emojis(t['mari'])) for t in lg) > 2]
    com_upsell = sum(1 for lg in logs if lg and 'por mais r$' in norm(lg[-1]['mari']))
    ok = [(f'10 conversas ({len(aberturas)} aberturas, {len(confirmacoes)} confirmações)', len(aberturas) == 10 and len(confirmacoes) == 10),
          (f'no máx. 2 emojis por conversa (excesso em {excesso or "nenhuma"})', not excesso),
          (f'abertura repetida no máx. 2× (pior: {ca.most_common(1)[0][1] if ca else 0}×)', bool(ca) and ca.most_common(1)[0][1] <= 2),
          (f'confirmação repetida no máx. 2× (pior: {cc.most_common(1)[0][1] if cc else 0}×; com upsell {com_upsell}/10)',
           bool(cc) and cc.most_common(1)[0][1] <= 2)]
    log = [t for lg in logs for t in lg]
    REPETICAO['aberturas'] = ca.most_common()
    REPETICAO['confirmacoes'] = cc.most_common()
    return ok, log, 'regular'


REPETICAO = {}


CENARIOS = {
    1: ('JF Regular — caminho feliz até dados_completos', c1),
    2: ('Montes Claros (BTU) — Oferta 50%, sem "no cartão"', c2),
    3: ('CEP fora das 38 (Ubatuba) — fora_de_area', c3),
    4: ('"Sim, já tenho Nio aqui" — ja_cliente_nio', c4),
    5: ('Cancelou há 10 dias — retorno com data', c5),
    6: ('Desconto duas vezes — padrão, depois objecao', c6),
    7: ('Nome da empresa / CNPJ — pedido_humano, sem o nome', c7),
    8: ('"Você é um robô?" — não nega', c8),
    9: ('CPF "12234" — pede os 11 dígitos', c9),
    10: ('Áudio / figurinha — resposta fixa de mídia', c10),
    11: ('"Para de me mandar mensagem" — recusa_compra', c11),
    12: ('Empresa MEI em JF — Empresas Regular, 24 meses', c12),
    13: ('Teste do Ricardo — "Cartão" na confirmação, visita hoje, concorrente', c13),
    14: ('Telefone diferente do WhatsApp — repete e confirma', c14),
    15: ('Tom — cliente informal ("blz", "qto fica")', c15),
    16: ('Tom — cliente formal', c16),
    17: ('Tom — cliente irritado com a internet atual', c17),
    18: ('Tom — "kkk" + pergunta do mais barato', c18),
    19: ('Tom — "ok" solto depois da lista', c19),
    20: ('Tom — "achei caro" (preco_dia)', c20),
    21: ('Anti-repetição — 10 conversas, abertura e confirmação', c21),
}
TOM = {15, 16, 17, 18, 19, 20, 21}   # só fazem sentido no prompt v3 (--ensaio)


def rodar(n):
    nome, fn = CENARIOS[n]
    try:
        checks, log, cluster = fn()
    except Exception as e:  # noqa: BLE001
        return n, nome, [('execução', False)], [], f'exceção: {e}'
    glob = []
    for i, t in enumerate(log, 1):
        for f in checar_global(t['mari'], cluster, t['r'].get('baloes')):
            glob.append(f'turno {i}: {f}')
        if t['r'].get('erro'):
            glob.append(f'turno {i}: erro do motor: {t["r"]["erro"]}')
    # (a) condições do fechamento obrigatório trazem o vencimento (roteiro Passo 4, rev. 04/11).
    for i, t in enumerate(log, 1):
        f = norm(t['mari'])
        if (condicoes(t['mari']) or 'so pra voce ficar por dentro' in f) and '25 dias' not in f:
            glob.append(f'turno {i}: condições sem a regra de vencimento (25 dias)')
        # (b) guard-rail 23: a sugestão de upgrade vem depois da confirmação da escolha. v2: "Ótima escolha" literal;
        #     v3 (afrouxado 05/11): confirmação com o valor do plano (1º "R$" antes do "por mais R$").
        upsell = 'por mais r$' in f and ((t['r'].get('tags') or {}).get('upsell_oferecido') or 'so pra voce saber' in f)
        if upsell and ENSAIO and f.find('r$') >= f.find('por mais r$'):
            glob.append(f'turno {i}: sugestão de upgrade sem confirmar antes a escolha com o valor')
        elif upsell and not ENSAIO and not (0 <= f.find('otima escolha') < max(f.find('por mais'), 0)):
            glob.append(f'turno {i}: sugestão de upgrade sem "Ótima escolha" antes')
    # LGPD (decisão pendente a): a 1ª fala que pede o CPF traz a linha curta.
    pede_cpf = next((t['mari'] for t in log if t['mari'] and 'cpf' in norm(t['mari'])
                     and ('me passa' in norm(t['mari']) or 'nome completo' in norm(t['mari']))), None)
    if pede_cpf is not None and 'seus dados' not in norm(pede_cpf):
        glob.append('LGPD: 1º pedido de CPF sem a linha de LGPD')
    if ENSAIO and n != 21:
        # Regra de emoji da v3: cliente sem emoji → a Mari usa no máximo 2 na conversa (a resposta fixa de mídia,
        # do motor, fica fora da conta).
        cliente = sum(len(emojis(t['lead'])) for t in log)
        mari = sum(len(emojis(t['mari'])) for t in log if t['r'].get('modelo') != 'fixo:midia')
        if not cliente and mari > 2:
            glob.append(f'{mari} emojis da Mari numa conversa em que o cliente não usou nenhum')
        ajustes = [a for t in log for a in (t['r'].get('emoji_ajustes') or [])]
        if ajustes:
            AJUSTES_EMOJI[n] = ajustes
    checks = list(checks) + [('checagens globais', not glob)]
    return n, nome, checks, log, '; '.join(glob)


def main():
    if not SEGREDO:
        raise SystemExit('MARI_TESTE_SECRET ausente.')
    args = sys.argv[1:]
    workers = 4
    if '--workers' in args:
        i = args.index('--workers')
        workers = int(args[i + 1])
        del args[i:i + 2]
    sel = [int(a) for a in args if a.isdigit()] or [n for n in CENARIOS if ENSAIO or n not in TOM]
    carregar_planos()
    print('teardown inicial:', teardown())
    os.makedirs(SAIDA, exist_ok=True)
    stamp = datetime.datetime.now().strftime('%d%m%y_%H%M')
    res = []
    with cf.ThreadPoolExecutor(max_workers=workers) as pool:
        for fut in cf.as_completed([pool.submit(rodar, n) for n in sel]):
            n, nome, checks, log, obs = fut.result()
            res.append((n, nome, checks, obs))
            with open(os.path.join(SAIDA, f'cenario_{n:02d}_{stamp}.json'), 'w', encoding='utf-8') as f:
                json.dump({'cenario': nome, 'checks': checks, 'obs': obs, 'log': log}, f, ensure_ascii=False, indent=2)
            verde = all(c[1] for c in checks)
            print(f'{"✅" if verde else "❌"} {n:2d}. {nome}')
            for c, b in checks:
                if not b:
                    print(f'      ✗ {c}')
            if obs:
                print(f'      obs: {obs[:300]}')
    res.sort()
    print('\n| # | Cenário | Resultado | Falhas |')
    print('|---|---|---|---|')
    for n, nome, checks, obs in res:
        falhas = [c for c, b in checks if not b]
        print(f'| {n} | {nome} | {"✅" if not falhas else "❌"} | {", ".join(falhas) or "—"} |')
    if AJUSTES_EMOJI:
        print('\nemoji corrigido pelo motor (o modelo errou e o 7 · Extrair consertou):')
        for n in sorted(AJUSTES_EMOJI):
            print(f'  {n}: {AJUSTES_EMOJI[n]}')
    if REPETICAO:
        print('\nanti-repetição — aberturas:', REPETICAO.get('aberturas'))
        print('anti-repetição — confirmações:', REPETICAO.get('confirmacoes'))
    if '--sem-teardown' not in sys.argv:
        print('teardown final:', teardown())
    sys.exit(0 if all(all(c[1] for c in r[2]) for r in res) else 1)


if __name__ == '__main__':
    main()
