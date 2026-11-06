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
# Desde 05/11 a produção também está na v3+ (v3 no ar; v4 depois da parte E do prompt 15): as checagens de tom e
# emoji valem nas duas rotas. V4 = venda remota (instalação no lugar da visita, guard-rail 24, Bloco 9):
# no ensaio sempre; na produção com --v4 (depois de virar ALVOS['producao'] para a v4).
V4 = ENSAIO or '--v4' in sys.argv
# V5 = prompt nº 18 (formato, condições exatas, pagamento é da Nio, retomada): ensaio sempre; produção com --v5.
V5 = ENSAIO or '--v5' in sys.argv
V4 = V4 or V5
# V6 = prompt 19 (o link da biometria é disparado pela própria Nio, por WhatsApp e e-mail): ensaio sempre; produção com --v6.
V6 = ENSAIO or '--v6' in sys.argv
V5 = V5 or V6
V4 = V4 or V6
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


PAGAMENTO_REVENDA = (r'link (de |do |pro |para o |pra )?pagamento|pagamento seguro|cadastr\w* (do |o |seu )?cartao|'
                     r'(a gente|nosso time|o time|o consultor) (cobra|vai cobrar|faz a cobranca)')


def pag_revenda(n):
    """Fala de link de pagamento / cobrança pela revenda — negar ("não tem link de pagamento") é permitido."""
    n = re.sub(r'\b(nao|nenhum|sem|nunca)\b[^.?!\n]{0,40}?(link (de |do |pro |para o |pra )?pagamento|pagamento seguro|'
               r'cadastr\w* (do |o |seu )?cartao|cobra\w*)', ' ', n)
    n = re.sub(r'\b(a gente|nos|nosso time|o time|o consultor) (nao|nunca) (cobra|vai cobrar|faz a cobranca)', ' ', n)
    return bool(re.search(PAGAMENTO_REVENDA, n))


def manda_link_nosso(n):
    """v6: frase em que a Mari ou o nosso time promete mandar o link (o link da biometria é da própria Nio)."""
    for f in re.split(r'[.?!\n]+', n):
        if (re.search(r'\b(mand|envi|encaminh)\w*\b.{0,50}\blink\b', f)
                and re.search(r'\b(nosso time|nossa equipe|o time|a gente|eu|vou|o consultor|nosso consultor|nos)\b', f)
                and not re.search(r'\bnio\b.{0,25}\b(mand|envi|dispar)\w*', f) and not re.search(r'\b(pela|da) (propria )?nio\b', f)
                and not re.search(r'\b(nao|nunca)\b.{0,30}\b(mand|envi)', f)):
            return True
    return False


def bloco_condicoes(meses=12, taxa='R$ 540'):
    """Texto exato do Ricardo (05/11 16h33); varejo = 12 meses. Empresas = 24; sem fidelidade = taxa na 1ª fatura."""
    linha = (f'• Taxa de instalação ({taxa}) ZERO ao manter o plano por {meses} meses.' if meses
             else f'• Taxa de instalação ({taxa}) cobrada na 1ª fatura (versão sem fidelidade).')
    return '\n'.join(['Antes de fechar, rapidinho as condições do seu plano:', '',
                      '• Preço fixo garantido até janeiro/2030 (sem reajuste anual).', linha,
                      '• Roteador em comodato incluído sem custo extra.',
                      '• 1ª fatura: 25 dias após a instalação no boleto (ou no dia da instalação no cartão).', '',
                      'A velocidade real depende do aparelho e do Wi-Fi.'])


BLOCOS_CONDICOES = [bloco_condicoes(12), bloco_condicoes(24), bloco_condicoes(None)]


NEGA_COBERTURA = (r'nao atende (o seu|seu|esse|ai)|ainda nao chegou|nao chegou (a )?fibra|sem viabilidade|sem cobertura|'
                  r'nao tem (cobertura|fibra)|fibra .{0,20}chegar na sua rua')


def sem_selo(x):
    """pendência 47: ✅/🎯 colados nas falas de cobertura não contam como emoji (v4)."""
    if not V4:
        return x or ''
    if V5:   # 💚 da saudação e da despedida (Ricardo, 05/11) é do sistema: não conta como emoji
        x = re.sub(r'[ \t]*💚[ \t]*', ' ', x or '').strip()
    x = re.sub(r'(atende o seu endere[cç]o!?)\s*✅', r'\1', x or '', flags=re.I)
    return re.sub(r'(atende (?:a[ií] em [^\n.!]{2,40}?|a sua cidade)[.!]?)\s*🎯', r'\1', x, flags=re.I)


def checar_global(resp, cluster, baloes=None):
    falhas = []
    t = resp or ''
    if V4:
        # pendência 47: ✅/🎯 só valem colados nas falas de cobertura; fora delas continuam proibidos.
        t = sem_selo(t)
        baloes = [sem_selo(b) for b in baloes] if baloes else baloes
    n = norm(t)
    if True:   # v3+ nas duas rotas
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
    if V4:
        # Venda remota (guard-rail 24): nada de visita/presencial e nenhum link vindo da Mari.
        if re.search(r'\bvisit|presencial|consultor vai ate', n):
            falhas.append('falou em visita/presencial (venda remota)')
        if re.search(r'https?://|www\.', n):
            falhas.append('mandou link (biometria/pagamento é do nosso time)')
        if re.search(r'credito (foi )?(aprovad|negad)|biometria (deu certo|aprovad|validad)', n):
            falhas.append('falou de resultado de crédito/biometria')
        # Adendo do Ricardo (05/11 10h05): a viabilidade nunca nega venda.
        if re.search(NEGA_COBERTURA, n):
            falhas.append('negou ou insinuou falta de cobertura')
    if V6 and manda_link_nosso(n):
        falhas.append('disse que a Mari / o nosso time manda o link da biometria (é da própria Nio)')
    if V5:
        # Prompt 18 (C5–C8): parágrafos com linha em branco; condições = texto exato; pagamento é da Nio.
        if pag_revenda(n):
            falhas.append('falou de link de pagamento / cobrança pela revenda')
        for b in (baloes or [t]):
            ls = [l.strip() for l in b.split('\n')]
            if any(ls[k] and ls[k - 1] and not (ls[k].startswith('•') and ls[k - 1].startswith('•')) for k in range(1, len(ls))):
                falhas.append('parágrafos sem linha em branco no mesmo balão')
                break
        if condicoes(t) and not any(x in t for x in BLOCOS_CONDICOES):
            falhas.append('condições fora do texto exato do Ricardo')
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
        # antes do CEP/número: "nada de número de cartão por aqui" não é pergunta de número
        if 'instalacao' in n and ('manha' in n or 'tarde' in n or 'periodo' in n) and '?' in mari and not resumo(mari):
            return p.get('instalacao', p.get('visita', 'De manhã'))
        if 'por mais r$' in n and 'nome completo' not in n:
            return 'Não, fico com esse mesmo'
        if 'cep' in n and ('numero' in n or 'me envia' in n or 'me passa' in n or 'me manda' in n or 'me fala' in n or '?' in mari):
            return p['cep_msg']
        if 'numero' in n and '?' in mari and 'telefone' not in n and 'cpf' not in n:
            return p['numero']
        # elegibilidade antes do complemento: a reação "sem complemento então" vem na mesma fala da pergunta
        if 'ja tem nio' in n or 'tinha oi fibra' in n or 'teve oi fibra' in n or 'cliente nio' in n:
            return p.get('elegibilidade', 'Não, ninguém aqui tem Nio')
        if 'complemento' in n:
            return p.get('complemento', 'Não tem complemento')
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
    l_visita = next((l for l in txt_resumo.split('\n') if 'Visita:' in l or 'Instalação:' in l), '')
    v = venda_da_conversa(cid)
    i_vero = next((i for i, t in enumerate(log) if t['lead'].startswith('Tenho Vero')), None)
    ok = [('acolhida + planos na mesma mensagem', i_vero is not None and tem_lista(log[i_vero]['mari'] or '')),
          ('respondeu "Cartão" à confirmação', i_cartao is not None),
          ('confirmação no preço do cartão (R$95)', 'R$95' in resp_cartao and 'R$110' not in resp_cartao),
          ('não parou: condições + nome/CPF logo em seguida', condicoes(prox) and 'nome completo' in norm(prox)),
          ('resumo com um preço só (R$95 no cartão)', 'R$95' in l_plano and 'R$110' not in l_plano),
          ('preferência "hoje à tarde" anotada' if V4 else 'visita "hoje à tarde" anotada',
           ('tarde' in norm(l_visita)) if V4 else ('hoje' in norm(l_visita))),
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


# ─────────────────────────── venda remota (prompt v4, prompt nº 15 parte E) ───────────────────────────
# O nível A (viabilidade oficial pelo portal) está em espera (login = SSO Microsoft): o motor manda sempre
# "indisponivel". Para exercitar o Bloco 9, os cenários 22–24 GRAVAM o resultado na conversa de teste logo depois do
# endereço (simulam o que o workflow nio_portal_viabilidade faria). Só conversas do prefixo de teste.

def injetar_viab(cid, resultado, vel=None, endereco_portal=None):
    v = f"'{vel}'" if vel else 'null'
    e = "'" + endereco_portal.replace("'", "''") + "'" if endereco_portal else 'null'
    sql(f"update public.mari_conversas set nio_viab_resultado = '{resultado}', nio_viab_velocidade = {v}, "
        f"nio_viab_endereco_portal = {e}, nio_viab_em = now() where id = '{cid}' and telefone like '{PREFIXO}%'", escrita=True)


def conversar_viab(tel, persona, resultado, vel=None, primeira='Oi, quero saber da internet da Nio', max_turnos=18):
    """Como conversar(), mas grava a viabilidade oficial quando a Mari pede o complemento (endereço completo)."""
    lead = Lead(persona)
    log = []
    msg = primeira
    injetado = False
    for _ in range(max_turnos):
        r = enviar(tel, msg, nome=persona.get('nome_contato', 'Teste'))
        log.append({'lead': msg, 'mari': r.get('resposta'), 'r': r})
        if r.get('handoff') or (r.get('erro') and not r.get('resposta')):
            break
        fala = r.get('resposta') or ''
        if not injetado and 'complemento' in norm(fala) and r.get('conversa_id'):
            injetar_viab(r['conversa_id'], resultado, vel)
            injetado = True
        msg = lead.responder(fala)
    return log, injetado


def venda_v4(cid):
    if not cid:
        return None
    r = sql(f"select v.nio_viab_resultado, v.nio_viab_velocidade, v.nio_viab_endereco_portal, v.instalacao_preferencia, "
            f"v.biometria_status, v.observacoes from mari_conversas c join vendas v on v.id = c.venda_id where c.id = '{cid}'")
    return r[0] if r else None


def briefing(cid):
    r = sql(f"select handoff_briefing from mari_conversas where id = '{cid}'")
    return (r[0].get('handoff_briefing') if r else '') or ''


def c22():
    persona = P(nome='Lucia Teste Prado', cpf=cpf_valido_de('741852963'), cep_msg='36013-260, número 420', numero='420',
                email='lucia.teste@exemplo.com', telefone='32977776666', instalacao='De manhã')
    log, inj = conversar_viab(PREFIXO + '022', persona, 'viavel', '1GB')
    r = ultimo(log); cid = cid_de(log)
    falas = todas_falas(log)
    lista = next((f for f in falas if tem_lista(f)), '')
    desp = (r.get('resposta') or '')
    v = venda_v4(cid)
    ok = [('viabilidade gravada depois do endereço', inj),
          ('lista abre com "atende o seu endereço"', 'atende o seu endereco' in norm(lista)),
          ('pediu a preferência manhã/tarde da instalação', any('instalacao' in norm(f) and ('manha' in norm(f) or 'tarde' in norm(f)) for f in falas)),
          ('resumo com a linha Instalação', any(resumo(f) and 'Instalação:' in f for f in falas)),
          (('despedida: a própria Nio manda o link (WhatsApp e e-mail)', 'propria nio' in norm(desp) and 'whatsapp' in norm(desp)
            and 'link da biometria' in norm(desp)) if V6 else
           ('despedida fala do link da biometria pelo time', 'link' in norm(desp) and 'biometria' in norm(desp))),
          ('handoff dados_completos', (r.get('handoff') or {}).get('motivo') == 'dados_completos'),
          ('venda com viabilidade oficial e preferência', bool(v) and v['nio_viab_resultado'] == 'viavel' and bool(v['instalacao_preferencia'])),
          ('venda nasce com biometria "não enviada"', bool(v) and v['biometria_status'] == 'nao_enviada'),
          ('briefing com o próximo passo do portal', 'portal pap' in norm(briefing(cid)))]
    return ok, log, 'regular'


def c23():
    # posse → Passo 2b → "não tenho" → fluxo normal até dados_completos, com a nota da posse no handoff.
    persona = P(nome='Marcos Teste Lima', cpf=cpf_valido_de('852963741'), cep_msg='36070-480, número 921', numero='921',
                email='marcos.teste@exemplo.com', telefone='32955554444',
                elegibilidade='Não, aqui ninguém tem Nio. O morador antigo é que tinha, acho')
    log, inj = conversar_viab(PREFIXO + '023', persona, 'posse')
    r = ultimo(log); cid = cid_de(log)
    falas = todas_falas(log)
    b = norm(briefing(cid))
    ok = [('viabilidade gravada depois do endereço', inj),
          ('perguntou se já tem Nio', any('ja tem nio' in norm(f) for f in falas)),
          ('seguiu para os planos', any(tem_lista(f) for f in falas)),
          ('handoff dados_completos', (r.get('handoff') or {}).get('motivo') == 'dados_completos'),
          ('nota da posse no handoff', 'posse' in b),
          ('venda criada', venda_da_conversa(cid) is not None)]
    return ok, log, 'regular'


def c24():
    # sem_viabilidade → fluxo normal SEM MUDAR UMA PALAVRA (fala pela cidade), venda criada, nota no handoff.
    # Falha se a Mari negar ou insinuar falta de cobertura (checagem global NEGA_COBERTURA).
    persona = P(nome='Sonia Teste Dias', cpf=cpf_valido_de('963741852'), cep_msg='36070-480, número 933', numero='933',
                email='sonia.teste@exemplo.com', telefone='32944443333')
    log, inj = conversar_viab(PREFIXO + '024', persona, 'sem_viabilidade')
    r = ultimo(log); cid = cid_de(log)
    falas = todas_falas(log)
    lista = next((f for f in falas if tem_lista(f)), '')
    b = norm(briefing(cid))
    ok = [('viabilidade gravada depois do endereço', inj),
          ('nenhuma fala nega ou insinua falta de cobertura', not any(re.search(NEGA_COBERTURA, norm(f)) for f in falas)),
          ('lista pela cidade (Juiz de Fora)', 'juiz de fora' in norm(lista) and 'atende o seu endereco' not in norm(lista)),
          ('handoff dados_completos', (r.get('handoff') or {}).get('motivo') == 'dados_completos'),
          ('nota "portal: sem_viabilidade — conferir manualmente" no handoff', 'portal: sem_viabilidade' in b and 'conferir manualmente' in b),
          ('venda criada', venda_da_conversa(cid) is not None)]
    return ok, log, 'regular'


def c25():
    tel = PREFIXO + '025'
    log = ate_lista(tel, P(cep_msg='36070-480, número 945', numero='945'), 'Oi! Quero internet')
    cid = cid_de(log)
    lista = next((t['mari'] for t in log if tem_lista(t['mari'] or '')), '') or ''
    c = sql(f"select nio_viab_resultado from mari_conversas where id = '{cid}'") if cid else []
    ok = [('chegou na lista', bool(lista)),
          ('estado sem viabilidade oficial (indisponível)', bool(c) and c[0].get('nio_viab_resultado') in (None, 'indisponivel')),
          ('fala da cidade (Juiz de Fora), não do endereço', 'juiz de fora' in norm(lista) and 'atende o seu endereco' not in norm(lista))]
    return ok, log, 'regular'


def c26():
    tel = PREFIXO + '026'
    log = ate_lista(tel, P(cep_msg='36070-480, número 957', numero='957'), 'Oi, boa tarde')
    log = depois(tel, log, ['Quero o 1', 'E a biometria, como faço? Alguém precisa vir aqui em casa antes?'])
    resp = norm(log[-1]['mari'] or '')
    ok = [('respondeu à pergunta da biometria', len(log) >= 2 and bool(resp)),
          (('link chega pela própria Nio (WhatsApp e e-mail)', 'propria nio' in resp and 'whatsapp' in resp
            and ('e-mail' in resp or 'email' in resp)) if V6 else
           ('link vem pelo nosso time, por aqui', 'link' in resp and ('time' in resp or 'equipe' in resp))),
          ('não precisa ir ninguém antes / técnico só instala', 'instal' in resp or 'nao precisa' in resp),
          ('não mandou link nem resultado (guard-rail 24)', 'http' not in resp and 'aprovad' not in resp)]
    return ok, log, 'regular'


def c27():
    # CEP digitado errado / rua com outro nome: o ViaCEP devolve uma rua, o cliente diz que é outra. O portal (simulado)
    # dá nao_encontrado na 1ª tentativa; o cliente corrige; o n8n refaria em cascata e acharia (simulado: viavel + o
    # endereço como a Nio cadastrou). A Mari confirma o endereço, não nega nada e a venda segue com a nota.
    tel = PREFIXO + '027'
    persona = P(nome='Rita Teste Campos', cpf=cpf_valido_de('159753486'), email='rita.teste@exemplo.com',
                telefone='32933332222', cep_msg='36070-480, número 968', numero='968')
    lead = Lead(persona)
    log = []
    msg = 'Oi, quero internet'
    fase = 0
    for _ in range(20):
        r = enviar(tel, msg, nome='Rita')
        log.append({'lead': msg, 'mari': r.get('resposta'), 'r': r})
        if r.get('handoff') or (r.get('erro') and not r.get('resposta')):
            break
        fala = r.get('resposta') or ''
        cid = r.get('conversa_id')
        if fase == 0 and 'complemento' in norm(fala) and cid:
            injetar_viab(cid, 'nao_encontrado')
            msg = 'Opa, não é essa rua não. Moro na Rua Doutor Romualdo, 968, Lourdes. Não tem complemento'
            fase = 1
            continue
        if fase == 1 and cid:
            injetar_viab(cid, 'viavel', '1GB', 'R DR ROMUALDO, 968 · LOURDES · JUIZ DE FORA/MG · 36070-480')
            fase = 2
        msg = lead.responder(fala)
    r = ultimo(log); cid = cid_de(log)
    falas = todas_falas(log)
    i_corr = next((i for i, t in enumerate(log) if t['lead'].startswith('Opa, não é essa rua')), None)
    resp_corr = norm(log[i_corr]['mari'] or '') if i_corr is not None else ''
    b = norm(briefing(cid))
    ok = [('cliente corrigiu a rua', i_corr is not None),
          ('Mari acolheu a correção sem negar cobertura', bool(resp_corr) and not re.search(NEGA_COBERTURA, resp_corr)),
          ('seguiu para os planos', any(tem_lista(f) for f in falas)),
          ('handoff dados_completos', (r.get('handoff') or {}).get('motivo') == 'dados_completos'),
          ('nota com o endereço como a Nio cadastrou', 'como a nio cadastrou' in b and 'romualdo' in b),
          ('venda criada', venda_da_conversa(cid) is not None)]
    return ok, log, 'regular'


# ─────────────────────────── prompt nº 18 (v5) ───────────────────────────

N18 = (lambda k: str((2100 if ENSAIO else 1100) + k))   # números de casa próprios (a trava de duplicidade olha o endereço)


def ate_condicoes(tel, persona, log, max_msgs=3, nome='Teste'):
    """Depois da lista: escolhe e segue o lead até a Mari mandar as condições."""
    lead = Lead(persona)
    msg = persona.get('escolha', 'Quero o 2')
    for _ in range(max_msgs):
        r = enviar(tel, msg, nome=nome)
        log.append({'lead': msg, 'mari': r.get('resposta'), 'r': r})
        if r.get('handoff') or condicoes(r.get('resposta') or ''):
            break
        msg = lead.responder(r.get('resposta') or '')
    return log


def c28():
    # C6 + C7: lista com uma linha em branco entre as opções; bloco de condições exato; proporcional só se perguntar.
    tel = PREFIXO + '028'
    persona = P(nome='Bruna Teste Rocha', cpf=cpf_valido_de('258147369' if ENSAIO else '258147360'),
                cep_msg=f'36070-480, número {N18(1)}', numero=N18(1))
    log = ate_lista(tel, persona, 'Oi, quero ver os planos')
    lista = next((b for t in log for b in (t['r'].get('baloes') or []) if tem_lista(b)), '')
    log = ate_condicoes(tel, persona, log)
    bal = [b for t in log for b in (t['r'].get('baloes') or [t['mari'] or ''])]
    cond = next((b for b in bal if condicoes(b)), '')
    ok = [('chegou à lista', bool(lista)),
          ('linha em branco entre as opções', bool(lista) and bool(re.search(r'\n\n2\)', lista)) and not re.search(r'[^\n]\n[2-9]\)', lista)),
          ('mandou as condições', bool(cond)),
          ('condições = texto exato do Ricardo (12 meses)', cond.strip() == bloco_condicoes(12)),
          ('não explicou o proporcional sem perguntarem', not any('proporcional' in norm(b) for b in bal))]
    return ok, log, 'regular'


def c29():
    # C8: cartão escolhido → "Anotado!" + manhã/tarde, sem link de pagamento em fala nenhuma nem no briefing.
    tel = PREFIXO + '029'
    persona = P(nome='Cecilia Teste Matos', cpf=cpf_valido_de('369258147' if ENSAIO else '369258140'),
                cep_msg=f'36070-480, número {N18(2)}', numero=N18(2), email='cecilia.teste@exemplo.com',
                telefone='32922221111', pagamento='Cartão de crédito')
    log = conversar(tel, persona)
    r = ultimo(log); cid = cid_de(log)
    i_pag = next((i for i, t in enumerate(log) if t['lead'] == 'Cartão de crédito'), None)
    resp = norm(log[i_pag]['mari'] or '') if i_pag is not None else ''
    b = norm(briefing(cid)) if cid else ''
    ok = [('cliente escolheu cartão', i_pag is not None),
          ('"Anotado" e já pergunta manhã ou tarde', 'anotado' in resp and ('manha' in resp or 'tarde' in resp)),
          ('nenhuma fala com link de pagamento / cobrança pela revenda', not any(pag_revenda(norm(f)) for f in todas_falas(log))),
          ('handoff dados_completos', (r.get('handoff') or {}).get('motivo') == 'dados_completos'),
          ('💚 no cumprimento da 1ª mensagem', '💚' in ((log[0]['mari'] or '').split('\n\n')[0] if log else '')),
          (('💚 no fim do 1º parágrafo da despedida', (r.get('resposta') or '').split('\n\n')[0].rstrip().endswith('💚')) if V6 else
           ('despedida começa com 💚', (r.get('resposta') or '').startswith('💚'))),
          ('briefing sem link de pagamento (só o link da biometria)', bool(b) and 'link da biometria' in b
           and not re.search(r'link (de |do )?pagamento|(e|ou) (o )?(link )?(de|do) pagamento|pagamento seguro', b))]
    return ok, log, 'regular'


def c30():
    # C8: "como pago?" → "A cobrança é feita pela própria Nio, na forma que você escolheu".
    tel = PREFIXO + '030'
    persona = P(nome='Davi Teste Nunes', cep_msg=f'36070-480, número {N18(3)}', numero=N18(3))
    log = ate_lista(tel, persona, 'Oi, boa noite')
    log = ate_condicoes(tel, persona, log)
    log = depois(tel, log, ['Antes de passar meus dados: como eu pago? Vocês mandam um link de pagamento?'])
    resp = norm(log[-1]['mari'] or '')
    ok = [('respondeu', bool(resp)),
          ('"a cobrança é feita pela própria Nio" (o conteúdo)', bool(re.search(r'cobranca e feita pela propria nio|quem cobra e a propria nio|cobrado pela propria nio', resp))),
          ('sem link de pagamento / cobrança pela revenda', not pag_revenda(resp) and 'http' not in resp)]
    return ok, log, 'regular'


def c31():
    # A: conversa em handoff (dados completos) → ciclo fechado (como faz o "resolvida" do Chatwoot) → cliente volta:
    # a Mari responde, sem refazer pergunta nem vender de novo.
    tel = PREFIXO + '031'
    persona = P(nome='Elisa Teste Faria', cpf=cpf_valido_de('147369258' if ENSAIO else '147369250'),
                cep_msg=f'36070-480, número {N18(4)}', numero=N18(4), email='elisa.teste@exemplo.com', telefone='32911110000')
    log = conversar(tel, persona)
    cid = cid_de(log)
    h1 = (ultimo(log).get('handoff') or {}).get('motivo')
    calado = enviar(tel, 'Oi? Alguém aí?', nome='Teste') if cid else {}
    log.append({'lead': 'Oi? Alguém aí?', 'mari': calado.get('resposta'), 'r': calado})
    fechou = sql(f"select public._mari_fechar_ciclo('{cid}', 'teste: conversa resolvida') as r", escrita=True)[0]['r'] if cid else {}
    if isinstance(fechou, str):
        fechou = json.loads(fechou)
    log = depois(tel, log, ['Oi, voltei! Já tá tudo certo com o meu pedido? Quando vai ser a instalação?'])
    resp = log[-1]['mari'] or ''
    c = sql(f"select status, handoff_motivo, ciclo_anterior ->> 'motivo' as anterior, ciclos_encerrados from mari_conversas where id = '{cid}'")[0] if cid else {}
    ok = [('1º handoff dados_completos', h1 == 'dados_completos'),
          ('em handoff a Mari fica calada', not calado.get('resposta')),
          ('ciclo fechado', bool(fechou) and fechou.get('fechado') is True),
          ('depois do ciclo fechado a Mari responde', bool(resp)),
          ('não pediu CEP nem CPF de novo', not re.search(r'\bcep\b|\bcpf\b', norm(resp))),
          ('não mandou a lista de novo', not tem_lista(resp)),
          ('não prometeu data de instalação', not re.search(r'\b\d{1,2}/\d{1,2}\b|amanha|segunda|terca|quarta|quinta|sexta|sabado', norm(resp))),
          ('ciclo anterior guardado (dados_completos)', c.get('anterior') == 'dados_completos' and int(c.get('ciclos_encerrados') or 0) >= 1)]
    return ok, log, 'regular'


def c32():
    # B4: venda não criada por duplicidade (mesmo CPF já tem venda ativa) → o handoff devolve a venda que já existe.
    cpf = cpf_valido_de('951357852' if ENSAIO else '951357850')
    p1 = P(nome='Fabio Teste Lopes', cpf=cpf, cep_msg=f'36070-480, número {N18(5)}', numero=N18(5),
           email='fabio.teste@exemplo.com', telefone='32900001111')
    log1 = conversar(PREFIXO + '032', p1)
    v1 = sql(f"select venda_id from mari_conversas where id = '{cid_de(log1)}'")[0]['venda_id'] if cid_de(log1) else None
    p2 = dict(p1, cep_msg=f'36070-480, número {N18(6)}', numero=N18(6))
    log2 = conversar(PREFIXO + '033', p2)
    h2 = ultimo(log2).get('handoff') or {}
    ok = [('1ª venda criada', bool(v1)),
          ('2º handoff dados_completos', h2.get('motivo') == 'dados_completos'),
          ('2ª venda NÃO criada (duplicidade)', h2.get('ok') is False and 'duplicidade' in norm(h2.get('motivo_recusa'))),
          ('devolve a venda que já existe', bool(v1) and h2.get('venda_existente_id') == v1)]
    return ok, log1 + log2, 'regular'



def c33():
    # Prompt 19: despedida dados_completos nova — três parágrafos, 💚 no fim do 1º, a própria Nio manda o link.
    tel = PREFIXO + '034'
    persona = P(nome='Gabriela Teste Pinto', cpf=cpf_valido_de('357159486' if ENSAIO else '357159480'),
                cep_msg=f'36070-480, número {N18(7)}', numero=N18(7), email='gabriela.teste@exemplo.com', telefone='32912123434')
    log = conversar(tel, persona)
    r = ultimo(log); cid = cid_de(log)
    desp = r.get('resposta') or ''
    ps = [x.strip() for x in desp.split('\n\n')]
    p2 = norm(ps[1]) if len(ps) > 1 else ''
    b = norm(briefing(cid)) if cid else ''
    v = venda_v4(cid)
    ok = [('handoff dados_completos', (r.get('handoff') or {}).get('motivo') == 'dados_completos'),
          ('três parágrafos', len(ps) == 3),
          ('1º: "Pronto, Gabriela, anotado! 💚"', bool(ps) and bool(re.match(r'^Pronto, Gabriela[^\n]*anotado! 💚$', ps[0]))),
          ('2º: o nosso time abre o pedido + prazo', 'abre o seu pedido' in p2 and ('em ate 2 horas' in p2 or 'no proximo horario de atendimento' in p2)),
          ('2º: a própria Nio manda o link por WhatsApp e por e-mail', 'propria nio' in p2 and 'whatsapp' in p2 and 'e-mail' in p2),
          ('3º: data da instalação por aqui', len(ps) > 2 and 'data da instalacao' in norm(ps[2])),
          ('sem "te manda aqui mesmo … o link"', 'te manda aqui mesmo' not in norm(desp) and not manda_link_nosso(norm(desp))),
          ('nota: registrar o nº → a Nio dispara o link → avisar o cliente',
           'registrar o n' in b and 'a nio dispara o link da biometria' in b and 'avisar o cliente' in b and 'mandar o link' not in b),
          ('venda nasce com biometria "não enviada"', bool(v) and v['biometria_status'] == 'nao_enviada')]
    return ok, log, 'regular'


def c34():
    # Prompt 19: "vocês vão me mandar o link?" no meio da venda → ele chega pela própria Nio, por WhatsApp e e-mail.
    tel = PREFIXO + '035'
    log = ate_lista(tel, P(cep_msg=f'36070-480, número {N18(8)}', numero=N18(8)), 'Oi, boa noite')
    log = depois(tel, log, ['Quero o 1', 'Vocês vão me mandar o link da biometria por aqui?'])
    resp = norm(log[-1]['mari'] or '')
    ok = [('respondeu', bool(resp)),
          ('ele chega pela própria Nio', 'propria nio' in resp),
          ('por WhatsApp e e-mail', 'whatsapp' in resp and ('e-mail' in resp or 'email' in resp)),
          ('não promete mandar o link nem manda link', not manda_link_nosso(resp) and 'http' not in resp)]
    return ok, log, 'regular'


def c35():
    # Prompt 19: venda registrada, ciclo fechado (resolvida) → "cadê o link?" → própria Nio + spam + consultor.
    tel = PREFIXO + '036'
    persona = P(nome='Helena Teste Prado', cpf=cpf_valido_de('468135792' if ENSAIO else '468135790'),
                cep_msg=f'36070-480, número {N18(9)}', numero=N18(9), email='helena.teste@exemplo.com', telefone='32956567878')
    log = conversar(tel, persona)
    cid = cid_de(log)
    h1 = (ultimo(log).get('handoff') or {}).get('motivo')
    fechou = sql(f"select public._mari_fechar_ciclo('{cid}', 'teste: conversa resolvida') as r", escrita=True)[0]['r'] if cid else {}
    if isinstance(fechou, str):
        fechou = json.loads(fechou)
    log = depois(tel, log, ['Oi! Cadê o link da biometria? Ainda não chegou nada aqui'])
    r = log[-1]['r']
    resp = norm(log[-1]['mari'] or '')
    ok = [('1º handoff dados_completos', h1 == 'dados_completos'),
          ('ciclo fechado', bool(fechou) and fechou.get('fechado') is True),
          ('o link chega pela própria Nio, por WhatsApp e e-mail', 'propria nio' in resp and 'whatsapp' in resp),
          ('confere o spam', 'spam' in resp),
          ('passa pro consultor (pedido_humano)', (r.get('handoff') or {}).get('motivo') == 'pedido_humano'),
          ('não promete mandar o link', not manda_link_nosso(resp) and 'http' not in resp),
          ('não pediu CEP nem CPF de novo', not re.search(r'\bcep\b|\bcpf\b', resp))]
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
    22: ('v4 — viável oficial (36013-260/420) até o handoff', c22),
    23: ('v4 — posse → "não tenho" → fluxo normal + nota', c23),
    24: ('v4 — sem viabilidade → fluxo normal, nunca nega (nota no handoff)', c24),
    25: ('v4 — portal indisponível → fala por cidade', c25),
    26: ('v4/v6 — "e a biometria?" → o link chega pela própria Nio (v6)', c26),
    27: ('v4 — CEP/rua digitados errado → confirma, refaz, venda segue', c27),
    28: ('v5 — lista espaçada + condições exatas', c28),
    29: ('v5 — cartão: "Anotado!" + manhã/tarde, sem link de pagamento', c29),
    30: ('v5 — "como pago?" → a cobrança é da própria Nio', c30),
    31: ('v5 — conversa resolvida e reaberta → a Mari volta com o histórico', c31),
    32: ('v5 — venda não criada (duplicidade) → devolve a venda existente', c32),
    33: ('v6 — despedida nova: a própria Nio manda o link (3 parágrafos, 💚)', c33),
    34: ('v6 — "vocês vão me mandar o link?" → chega pela própria Nio', c34),
    35: ('v6 — retomada: "cadê o link?" → própria Nio + spam + consultor', c35),
}
TOM = {15, 16, 17, 18, 19, 20, 21}   # v3+ (desde 05/11 também na produção)
VENDA_REMOTA = {22, 23, 24, 25, 26, 27}  # prompt v4 (--ensaio, ou produção com --v4). Critério da parte E: ≥ 24/27
PROMPT18 = {28, 29, 30, 31, 32}          # prompt v5 (--ensaio, ou produção com --v5). Vermelho em regra = não publica
PROMPT19 = {33, 34, 35}                  # prompt v6 (--ensaio, ou produção com --v6). Vermelho em regra = não publica


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
        if upsell and f.find('r$') >= f.find('por mais r$'):
            glob.append(f'turno {i}: sugestão de upgrade sem confirmar antes a escolha com o valor')
    # LGPD (decisão pendente a): a 1ª fala que pede o CPF traz a linha curta.
    pede_cpf = next((t['mari'] for t in log if t['mari'] and 'cpf' in norm(t['mari'])
                     and ('me passa' in norm(t['mari']) or 'nome completo' in norm(t['mari']))), None)
    if pede_cpf is not None and 'seus dados' not in norm(pede_cpf):
        glob.append('LGPD: 1º pedido de CPF sem a linha de LGPD')
    if n != 21:
        # Regra de emoji da v3: cliente sem emoji → a Mari usa no máximo 2 na conversa (a resposta fixa de mídia,
        # do motor, fica fora da conta).
        cliente = sum(len(emojis(t['lead'])) for t in log)
        mari = sum(len(emojis(sem_selo(t['mari']))) for t in log if t['r'].get('modelo') != 'fixo:midia')
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
    sel = [int(a) for a in args if a.isdigit()] or [n for n in CENARIOS if (V4 or n not in VENDA_REMOTA) and (V5 or n not in PROMPT18) and (V6 or n not in PROMPT19)]
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
