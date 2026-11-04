#!/usr/bin/env python3
# NIOGEN | tests/mari_cenarios.py | 04/11/2026 — Claude Code (prompt nº 8)
# Bateria de cenários da Mari v1 contra a rota de teste do n8n (POST /webhook/mari-teste, header X-Mari-Secret).
# Cada cenário usa um telefone de teste 5500000000xxx e conversa turno a turno com um "lead" que responde
# conforme o que a Mari perguntou. Checagens globais em TODOS os turnos (sem o nome da revendedora, sem
# palavras proibidas, sem asterisco, ~4 linhas, preços batendo com config_planos, nunca "cobertura confirmada").
# Checagens no banco pelo CLI do Supabase (read-only). Teardown: mari_limpar_teste('5500000000') antes e depois.
#
# Uso:  python tests/mari_cenarios.py [n ...] [--sem-teardown] [--workers 4]
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
URL = 'https://n8n.ofertasverointernet.com.br/webhook/mari-teste'
PREFIXO = '5500000000'
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


def checar_global(resp, cluster):
    falhas = []
    t = resp or ''
    n = norm(t)
    for p in PROIBIDAS:
        if p in n:
            falhas.append(f'palavra proibida "{p}"')
    if '*' in t:
        falhas.append('asterisco')
    lista = any(x in t for x in ('1️⃣', '2️⃣', '4️⃣', '•', '✅'))
    linhas = [l for l in t.split('\n') if l.strip()]
    if not lista and len(linhas) > 5:
        falhas.append(f'{len(linhas)} linhas')
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
        if 'confere os dados' in n or 'ainda ta tudo certo' in n:
            return p.get('confirma', 'Sim, tá tudo certo, pode encaminhar')
        if 'so pra voce saber' in n and 'por mais' in n and 'nome completo' not in n:
            return 'Não, fico com esse mesmo'
        if 'cep' in n and ('numero' in n or 'me envia' in n or 'me passa' in n):
            return p['cep_msg']
        if 'qual e?' in n and 'numero' in n:
            return p['numero']
        if 'complemento' in n:
            return p.get('complemento', 'Não tem complemento')
        if 'ja tem nio' in n or 'tinha oi fibra' in n:
            return p.get('elegibilidade', 'Não, ninguém aqui tem Nio')
        if re.search(r'\bmei\b', n) and '?' in mari:
            return p.get('mei', 'Sim, sou MEI')
        if 'nome completo' in n and 'cpf' in n:
            return f"{p['nome']}, CPF {p['cpf']}"
        if '11 digitos' in n or 'cpf parece' in n:
            return p['cpf']
        if 'telefone' in n or 'ddd' in n:
            return p['telefone']
        if 'e-mail' in n or 'email' in n:
            return p['email']
        if 'forma de pagamento' in n or ('boleto' in n and 'cartao' in n and '?' in mari) or 'como prefere pagar' in n:
            return p.get('pagamento', 'Cartão de crédito')
        if 'visita' in n and ('dia' in n or 'periodo' in n or 'manha' in n):
            return p.get('visita', 'Sexta-feira de manhã')
        if '1️⃣' in mari or 'qual combina' in n:
            return p.get('escolha', 'Quero o 2')
        if 'tudo certo?' in n:
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


def c1():
    log = conversar(PREFIXO + '001', P())
    r = ultimo(log); cid = cid_de(log)
    v = venda_da_conversa(cid)
    ok = []
    ok.append(('handoff dados_completos', (r.get('handoff') or {}).get('motivo') == 'dados_completos'))
    ok.append(('venda criada em 0', bool(v) and v['status'] == '0_qualificado'))
    ok.append(('plano regular', bool(v) and str(v['plano'] or '').startswith('V-REG-')))
    ok.append(('forma', bool(v) and v['forma_pagamento'] in ('cartao', 'boleto', 'dacc')))
    ok.append(('endereço', bool(v) and v['cep'] == '36070480' and v['numero'] == '889' and v['cidade'] == 'Juiz de Fora'))
    ok.append(('dfv gravado', bool(v) and v['dfv_viabilidade'] != 'nao_consultado'))
    return ok, log, 'regular'


def c2():
    log = conversar(PREFIXO + '002', P(nome='Carlos Teste Moura', cpf=cpf_valido_de('111444777'),
                                       cep_msg='39400-104, número 250', numero='250', telefone='38999990000',
                                       email='carlos.teste@exemplo.com', pagamento='Boleto'))
    r = ultimo(log); cid = cid_de(log)
    v = venda_da_conversa(cid)
    falas = todas_falas(log)
    lista = [f for f in falas if '1️⃣' in f]
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
    ok = [('não vende (sem lista de planos)', '1️⃣' not in falas),
          (f'retorno em {data_ok} (cancelamento + 31 d)', data_ok in falas),
          ('[AGENDAMENTO_RETORNO]', tags_ag or bool(cv.get('agendamento_retorno'))),
          ('nenhuma venda', venda_da_conversa(cid) is None)]
    return ok, log, 'regular'


def c6():
    tel = PREFIXO + '006'
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
        if estado['pediu'] == 0 and '1️⃣' in fala:
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
    lista = [f for f in falas if '1️⃣' in f]
    v = venda_da_conversa(cid)
    ok = [('pergunta MEI', any('mei' in norm(f) for f in falas)),
          ('tabela Empresas Regular', bool(lista) and 'R$110' in lista[0] and 'R$130' in lista[0]),
          ('isenção 24 meses', any('24 meses' in f for f in falas)),
          ('venda Empresas MEI', bool(v) and str(v['plano'] or '').startswith('E-REG-') and v['segmento'] == 'MEI')]
    return ok, log, 'regular'


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
}


def rodar(n):
    nome, fn = CENARIOS[n]
    try:
        checks, log, cluster = fn()
    except Exception as e:  # noqa: BLE001
        return n, nome, [('execução', False)], [], f'exceção: {e}'
    glob = []
    for i, t in enumerate(log, 1):
        for f in checar_global(t['mari'], cluster):
            glob.append(f'turno {i}: {f}')
        if t['r'].get('erro'):
            glob.append(f'turno {i}: erro do motor: {t["r"]["erro"]}')
    # LGPD (decisão pendente a): a 1ª fala que pede o CPF traz a linha curta.
    pede_cpf = next((t['mari'] for t in log if t['mari'] and 'cpf' in norm(t['mari'])
                     and ('me passa' in norm(t['mari']) or 'nome completo' in norm(t['mari']))), None)
    if pede_cpf is not None and 'seus dados sao usados' not in norm(pede_cpf):
        glob.append('LGPD: 1º pedido de CPF sem a linha de LGPD')
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
    sel = [int(a) for a in args if a.isdigit()] or list(CENARIOS)
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
    if '--sem-teardown' not in sys.argv:
        print('teardown final:', teardown())
    sys.exit(0 if all(all(c[1] for c in r[2]) for r in res) else 1)


if __name__ == '__main__':
    main()
