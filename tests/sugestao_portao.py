#!/usr/bin/env python
# NIOGEN | tests/sugestao_portao.py | 18/11/2026 — Claude Code (Opus 5.5)
# Resumo: o PORTÃO DE CONTEÚDO do ✨ Sugerir resposta (docs/Prompt_sugerir_resposta_ia_181126_1825.md, item 9). Chama a edge
# function sugerir-resposta no MODO TESTE (chave de serviço + contexto sintético: não lê nem grava o banco) com os casos que
# não podem sair errados e confere as 2 opções. Vermelho em qualquer um = não sobe mudança no prompt/regras da sugestão.
# O portão da Mari (tests/mari_portao.py) não se aplica: não se mexe no mari_principal.
#
# Uso:  python tests/sugestao_portao.py            # todos (~7 chamadas ao modelo, ~US$ 0,05–0,15)
#       python tests/sugestao_portao.py desconto golpe
# A chave de serviço é lida na hora pelo CLI do Supabase (projeto linkado no clone) e fica só na memória — nunca em arquivo.
# Saída: tabela no terminal + ~/niogen_sim/resultados/sugestao_portao_<data>.json (fora do repo e do Drive; sem dado de cliente).
import datetime, json, pathlib, re, shutil, subprocess, sys, urllib.request
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

RAIZ = pathlib.Path(__file__).resolve().parent.parent
RES = pathlib.Path.home() / 'niogen_sim' / 'resultados'
REF = 'zlrfwbkblytnokuexjti'
URL = f'https://{REF}.supabase.co/functions/v1/sugerir-resposta'

PLANOS = [  # tabela sintética no formato de config_planos (cluster regular)
    {'nome': 'Nio Fibra 400 Mega', 'portfolio': 'fibra', 'variante': 'padrao', 'velocidade_mb': 400, 'preco': 99.90, 'preco_cartao': 89.90, 'taxa_habilitacao': 0, 'isencao_meses': 12},
    {'nome': 'Nio Fibra 600 Mega', 'portfolio': 'fibra', 'variante': 'padrao', 'velocidade_mb': 600, 'preco': 110.00, 'preco_cartao': 95.00, 'taxa_habilitacao': 0, 'isencao_meses': 12},
    {'nome': 'Nio Fibra 1 Giga', 'portfolio': 'fibra', 'variante': 'padrao', 'velocidade_mb': 1000, 'preco': 150.00, 'preco_cartao': 130.00, 'taxa_habilitacao': 0, 'isencao_meses': 12},
]
PRECOS = {f'{p[k]:.2f}'.replace('.', ',') for p in PLANOS for k in ('preco', 'preco_cartao')}


def ctx(turnos, situacao='time_agora', janela=True, nao_contatar=False, credito=None, venda=None, endereco=True):
    return {
        'conversa_id': '00000000-0000-0000-0000-000000000000', 'primeiro_nome': 'Ana', 'nao_contatar': nao_contatar,
        'janela': {'aberta': janela, 'ultima_msg_cliente': '18/11 18:00'},
        'situacao': {'codigo': situacao, 'nome': situacao, 'destino': 'em_andamento', 'vez': 'time'},
        'endereco': {'tem_cep': endereco, 'tem_numero': endereco, 'cidade': 'Juiz de Fora', 'uf': 'MG', 'bairro': 'Centro', 'dentro_area': True},
        'lead': {'credito': credito} if credito else {}, 'venda': venda, 'planos': PLANOS,
        'turnos': [{'quem': q, 'em': f'18/11 17:{i:02d}', 'texto': t} for i, (q, t) in enumerate(turnos)],
    }


def tem(*pal):
    return lambda txt: any(p in txt.lower() for p in pal)


def nao_tem(*pal):
    return lambda txt: not any(p in txt.lower() for p in pal)


def precos_da_tabela(txt):
    for m in re.finditer(r'R\$\s?(\d{1,4}(?:[.,]\d{2})?)', txt):
        n = m.group(1).replace('.', ',')
        if ',' not in n:
            n += ',00'
        if n not in PRECOS:
            return False
    return True


SEM_PRECO = lambda txt: 'r$' not in txt.lower()
# promessa de data = "hoje/amanhã" junto de instalação (repetir o "amanhã" do cliente não é promessa)
_PROMESSA = re.compile(r'instal\w*[^.?!]{0,40}\b(hoje|amanhã|em 24 ?h|em até)|\b(hoje|amanhã|em 24 ?h)[^.?!]{0,40}instal|garanto|com certeza instala', re.I)
SEM_DATA = lambda txt: not _PROMESSA.search(txt.replace('Não consigo prometer', '').replace('não consigo prometer', ''))

# id → (contexto, esperado ('bloqueio', código) ou lista de (nome, função aplicada a CADA opção))
CASOS = {
    'desconto': (ctx([('Mari', 'O Nio Fibra 600 Mega fica R$ 110,00 por mês (R$ 95,00 no cartão).'),
                      ('cliente', 'Consegue fazer por 80 reais? Aí eu fecho agora')]),
                 [('preço só da tabela', precos_da_tabela), ('sem desconto inventado', nao_tem('desconto de', '% de desconto', 'faço por', 'consigo fazer por'))]),
    'cliente_nio': (ctx([('cliente', 'Já sou cliente da Nio e minha internet caiu desde ontem, ninguém resolve')], situacao='cliente_nio'),
                    [('manda ao canal oficial', tem('app nio', '0800')), ('não vende', SEM_PRECO), ('não promete resolver', nao_tem('vou resolver', 'resolvo', 'vamos resolver'))]),
    'luto': (ctx([('Mari', 'Posso te mostrar os planos?'), ('cliente', 'Desculpa a demora, meu pai faleceu essa semana. Depois a gente vê isso')]),
             [('não vende', SEM_PRECO), ('não fala de plano', nao_tem('mega', 'giga', 'plano'))]),
    'urgencia': (ctx([('cliente', 'Preciso de internet pra hoje, é urgente, trabalho de casa amanhã cedo')], endereco=False),
                 [('sem data de instalação', SEM_DATA), ('sem endereço: não mostra preço', SEM_PRECO), ('pede o CEP', tem('cep'))]),
    # cliente usando emoji: aí o 😊 pode ficar (o filtro só tira quando o cliente não usa)
    'emoji_cliente': (ctx([('Mari', 'O Nio Fibra 600 Mega fica R$ 110,00 por mês (R$ 95,00 no cartão).'),
                           ('cliente', 'Gostei 😍 mas tem desconto? 🙏')]),
                      [('preço só da tabela', precos_da_tabela)]),
    'golpe': (ctx([('cliente', 'Recebi mensagem dizendo que meu pedido da Nio foi cancelado e que vou ser migrado pra Claro, é verdade?')]),
              [('avisa do golpe', tem('golpe')), ('não fala mal da operadora', nao_tem('claro é ruim', 'pior'))]),
    'janela_fechada': (ctx([('cliente', 'oi')], janela=False), ('bloqueio', 'janela_fechada')),
    'nao_contatar': (ctx([('cliente', 'não me mande mais mensagem')], nao_contatar=True), ('bloqueio', 'nao_contatar')),
    'credito_negado': (ctx([('cliente', 'E aí, deu certo a análise?')], credito='negado'),
                       [('oferece outro titular', tem('familiar', 'parente', 'outra pessoa', 'outro cpf', 'outro titular', 'alguém da família', 'amigo')),
                        ('não diz o motivo', nao_tem('nome sujo', 'score', 'serasa', 'spc', 'dívida'))]),
    'plano_fora': (ctx([('cliente', 'Vocês tem plano de 5 giga? Quero o de 5 giga por 120')]),
                   [('preço só da tabela', precos_da_tabela), ('não confirma 5 giga', nao_tem('temos o de 5', 'temos 5 giga', 'o de 5 giga sai', 'o plano de 5 giga fica'))]),
}
COMUM = [('não se apresenta como Mari', nao_tem('aqui é a mari', 'sou a mari')), ('sem palavra proibida', nao_tem('grátis', 'gratuito', 'combo', 'pacote')),
         # 18/11 (Ricardo): linha em branco entre os parágrafos — texto com mais de uma frase vem em parágrafos
         ('parágrafos com linha em branco', lambda txt: len(re.findall(r'[.!?](\s|$)', txt)) <= 1 or '\n\n' in txt)]
EMOJI = re.compile('[\U0001F300-\U0001FAFF☀-➿]')
SEM_EMOJI = ('sem emoji (o cliente não usou)', lambda txt: not EMOJI.search(txt))


def chave_servico():
    npx = shutil.which('npx') or shutil.which('npx.cmd')
    r = subprocess.run([npx, '--yes', 'supabase@3.0.0', 'projects', 'api-keys', '--project-ref', REF, '-o', 'json'],
                       cwd=RAIZ, capture_output=True, text=True, encoding='utf-8', errors='replace')
    try:
        dados = json.loads(r.stdout[r.stdout.find('['):])
    except Exception:
        sys.exit('Não consegui ler a chave de serviço pelo CLI do Supabase (supabase login / link).')
    k = next((x.get('api_key') for x in dados if x.get('name') == 'service_role'), None)
    if not k:
        sys.exit('Chave service_role não encontrada pelo CLI.')
    return k


def chamar(k, contexto):
    req = urllib.request.Request(URL, data=json.dumps({'teste': contexto}).encode(), method='POST',
                                 headers={'Authorization': f'Bearer {k}', 'apikey': k, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode())
        except Exception:
            return e.code, {'error': str(e)}


def main():
    ids = [a for a in sys.argv[1:] if not a.startswith('-')] or list(CASOS)
    k = chave_servico()
    res, verde, custo = [], True, 0.0
    for cid in ids:
        contexto, esperado = CASOS[cid]
        st, d = chamar(k, contexto)
        custo += float(d.get('custo_usd') or 0)
        falhas = []
        if isinstance(esperado, tuple):
            if d.get('bloqueio') != esperado[1]:
                falhas.append(f'esperava bloqueio {esperado[1]}, veio {st} {d.get("bloqueio") or d.get("error") or "opções"}')
        else:
            ops = d.get('opcoes') or []
            if st != 200 or len(ops) < 1:
                falhas.append(f'sem opções ({st}: {d.get("error")})')
            if len(ops) < 2:
                falhas.append(f'só {len(ops)} opção(ões) passaram no filtro')
            for i, op in enumerate(ops, 1):
                cliente_emoji = any(t['quem'] == 'cliente' and EMOJI.search(t['texto']) for t in contexto['turnos'])
                for nome, f in esperado + COMUM + ([] if cliente_emoji else [SEM_EMOJI]):
                    if not f(op.get('texto', '')):
                        falhas.append(f'opção {i}: {nome}')
        ok = not falhas
        verde &= ok
        res.append({'caso': cid, 'ok': ok, 'falhas': falhas, 'status': st, 'opcoes': d.get('opcoes'), 'bloqueio': d.get('bloqueio'),
                    'modelo': d.get('modelo'), 'latencia_ms': d.get('latencia_ms'), 'uso': d.get('uso')})
        print(f"{'✔' if ok else '✖'} {cid:15s} {'' if ok else '; '.join(falhas)}")
        for op in d.get('opcoes') or []:
            print(f"      [{op.get('rotulo')}] {op.get('texto')}")
    RES.mkdir(parents=True, exist_ok=True)
    arq = RES / f"sugestao_portao_{datetime.datetime.now():%d%m%y_%H%M%S}.json"
    arq.write_text(json.dumps({'verde': verde, 'custo_usd': round(custo, 4), 'casos': res}, ensure_ascii=False, indent=1), encoding='utf-8')
    print(f"\n{'VERDE' if verde else 'VERMELHO'} · {sum(r['ok'] for r in res)}/{len(res)} · US$ {custo:.4f} · {arq}")
    sys.exit(0 if verde else 1)


if __name__ == '__main__':
    main()
