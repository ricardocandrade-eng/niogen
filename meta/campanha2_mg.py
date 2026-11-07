#!/usr/bin/env python3
"""
NIOGEN | meta/campanha2_mg.py
Gerado em 07/11/2026 (America/Sao_Paulo) — Claude Code, prompt 29 (rev. 17h30)
Resumo: campanha 2 de Meta Ads (Juiz de Fora inteira + 19 cidades Regular + 15 cidades BTU/Oferta 50 %), CBO lida do
        Supabase (config_meta_ads_regras.c2_orcamento_diario), 12 criativos v2 (1x1 + 9x16 por posicionamento, trava
        validar_criativo da C1), 18 anúncios. Substitui a campanha 1, que só é pausada depois de a C2 estar ACTIVE.

Etapas (idempotente: procura cada objeto pelo nome antes de criar):
  python meta/campanha2_mg.py --dry-run         plano + chaves de cidade (leitura) — nada criado
  python meta/campanha2_mg.py --criar           imagens, campanha, 3 conjuntos, 12 criativos, 18 anúncios — tudo PAUSED
  python meta/campanha2_mg.py --previas         prova: feed IG (1x1) e Stories IG (9x16) de 1 anúncio por arte + ad_review_feedback
  python meta/campanha2_mg.py --ativar          anúncios → conjuntos → campanha (só com a prova das prévias OK no JSON)
  python meta/campanha2_mg.py --status          status da C2 (e da C1)
  python meta/campanha2_mg.py --pausar-c1       pausa a C1 inteira (campanha, conjuntos, anúncios) — só com a C2 ACTIVE; nunca apaga

Reaproveita de campanha1_jf.py: api/ler_token/escolher_versao, POSICIONAMENTOS (sem Status do WhatsApp e sem Audience
Network), payloads_criativo (9x16 nas verticais + fallback 1x1 + opt-out) e criar_criativo (= validar_criativo + POST).
Não faz: misturar arte Regular no BTU (ou o contrário) · Advantage+ criativo · texto gerado pela IA da Meta · subir a verba
acima de R$ 200/dia · apagar a C1. Token: META_ACCESS_TOKEN_NIO (nunca impresso).
"""
import argparse
import copy
import datetime as dt
import glob
import json
import os
import subprocess
import sys
import time
import unicodedata
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import campanha1_jf as c1          # noqa: E402
import recriar_criativos_v4 as r4   # noqa: E402  (provar_previa)

REPO = c1.REPO
SAIDA = os.path.join(REPO, 'meta', 'campanha2_mg_ids.json')
IMAGENS_DIR = r'C:\Users\ricar\Meu Drive\Projetos Claude\dharmapro-nio\criativos_nov26\campanha2'
VERSAO_ARTE = '071126_1725'        # criativos v2 (preço do cartão no Regular); os v1 estão em _v1_preco_boleto/
CONTA = c1.CONTA
PAGINA = '1421228191072269'        # Mari Nio Internet
C1_CAMPANHA = '120257703177650211'  # NIO_JF_C1_MSG_nov26
STATUS = 'PAUSED'
VERBA_TETO = 200                   # prompt 29: não subir acima de R$ 200/dia aqui (escala depois de 72 h)

CAMPANHA = {'name': 'NIO_MG_C2_MSG_nov26', 'objective': 'OUTCOME_ENGAGEMENT', 'special_ad_categories': [],
            'bid_strategy': 'LOWEST_COST_WITHOUT_CAP'}

REGULAR = ['Belo Horizonte', 'Betim', 'Cataguases', 'Conselheiro Lafaiete', 'Contagem', 'Divinópolis', 'Esmeraldas',
           'Ibirité', 'Leopoldina', 'Nova Lima', 'Pouso Alegre', 'Ribeirão das Neves', 'Santa Luzia',
           'Santa Rita do Sapucaí', 'São Lourenço', 'Sete Lagoas', 'Ubá', 'Varginha', 'Vespasiano']
BTU = ['Araguari', 'Caxambu', 'Coronel Fabriciano', 'Governador Valadares', 'Ipatinga', 'Itabira', 'João Monlevade',
       'Lavras', 'Montes Claros', 'Muriaé', 'Paracatu', 'Patrocínio', 'Poços de Caldas', 'Sabará', 'Timóteo']

CONJUNTOS = [
    {'name': 'CJ_JF', 'cidades': ['Juiz de Fora'], 'arte': 'REG', 'gasto_min': True},
    {'name': 'CJ_REGULAR', 'cidades': REGULAR, 'arte': 'REG', 'gasto_min': False},
    {'name': 'CJ_BTU', 'cidades': BTU, 'arte': 'BTU', 'gasto_min': False},
]

ANUNCIOS = {
    'REG': [
        {'name': 'AD_C2R_H1_sobe', 'img': 'REG_H1_sobe', 'titulo': '600 Mega por R$ 95/mês até 2030',
         'texto': 'Sua internet subiu de novo? 😤 Aqui o preço não sobe até janeiro de 2030. Fibra óptica 600 Mega por R$ 95/mês no cartão (ou R$ 110 no boleto). Manda seu CEP no WhatsApp 👇'},
        {'name': 'AD_C2R_H2_porDia', 'img': 'REG_H2_porDia', 'titulo': 'Fibra 600 Mega por R$ 3,17/dia',
         'texto': 'R$ 3,17 por dia. Menos que um cafezinho ☕ Fibra óptica 600 Mega por R$ 95/mês no cartão (R$ 110 no boleto), preço fixo até 2030. Veja pelo WhatsApp se chega na sua rua.'},
        {'name': 'AD_C2R_H3_caro', 'img': 'REG_H3_caro', 'titulo': 'Paga mais de R$ 95? Está caro.',
         'texto': 'Se você paga mais de R$ 95 de internet, está pagando caro. Nio Fibra 600 Mega por R$ 95/mês no cartão ou R$ 110 no boleto, travado até 2030. Troque hoje: chama no WhatsApp.'},
        {'name': 'AD_C2R_H4_rua', 'img': 'REG_H4_rua', 'titulo': 'A Nio já passa na sua rua?',
         'texto': 'Chegou fibra nova na região 🚀 Manda seu CEP no WhatsApp e descubra agora se a Nio chega no seu endereço. 600 Mega por R$ 95/mês no cartão (R$ 110 no boleto).'},
        {'name': 'AD_C2R_H5_giga', 'img': 'REG_H5_giga', 'titulo': '1 Giga em casa + 5G no celular',
         'texto': '1 Giga em casa, 20 GB de internet 5G no celular e Globoplay por 12 meses. Nio Super por R$ 155/mês no cartão (R$ 170 no boleto), preço fixo até 2030. Chama no WhatsApp 👇'},
        {'name': 'AD_C2R_H6_trava', 'img': 'REG_H6_trava', 'titulo': 'Mesmo preço até 2030',
         'texto': '2026, 2027, 2028, 2029… e o preço da sua internet não muda. Fibra 600 Mega por R$ 95/mês no cartão (R$ 110 no boleto) até janeiro de 2030. Trave o seu pelo WhatsApp.'},
    ],
    'BTU': [
        {'name': 'AD_C2B_H1_metade', 'img': 'BTU_H1_metade', 'titulo': 'Fibra 600 Mega por R$ 55/mês',
         'texto': 'Internet fibra óptica 600 Mega por R$ 55 por mês, no boleto, débito ou cartão. E o preço fica travado até 2030. Manda seu CEP no WhatsApp 👇'},
        {'name': 'AD_C2B_H2_porDia', 'img': 'BTU_H2_porDia', 'titulo': 'R$ 1,83 por dia',
         'texto': 'R$ 1,83 por dia por uma fibra de 600 Mega. Isso mesmo. Preço fixo até janeiro de 2030. Veja pelo WhatsApp se chega na sua rua.'},
        {'name': 'AD_C2B_H3_caro', 'img': 'BTU_H3_caro', 'titulo': 'Paga mais de R$ 55? Está caro.',
         'texto': 'Se você paga mais de R$ 55 de internet, está pagando caro. Nio Fibra 600 Mega por R$ 55/mês, preço travado até 2030. Troque hoje: chama no WhatsApp.'},
        {'name': 'AD_C2B_H4_rua', 'img': 'BTU_H4_rua', 'titulo': 'A Nio já passa na sua rua?',
         'texto': 'Chegou fibra nova na região 🚀 600 Mega por R$ 55/mês. Manda seu CEP no WhatsApp e descubra agora se a Nio chega no seu endereço.'},
        {'name': 'AD_C2B_H5_giga', 'img': 'BTU_H5_giga', 'titulo': '1 Giga por R$ 85/mês',
         'texto': 'O plano mais rápido da Nio: 1 Giga com Wi-Fi 6 por R$ 85/mês, preço fixo até 2030. Chama no WhatsApp e veja se chega na sua rua 👇'},
        {'name': 'AD_C2B_H6_trava', 'img': 'BTU_H6_trava', 'titulo': 'Mesmo preço até 2030',
         'texto': '2026, 2027, 2028, 2029… e o preço da sua internet não muda. Fibra 600 Mega por R$ 55/mês até janeiro de 2030. Trave o seu pelo WhatsApp.'},
    ],
}

PREVIAS = [('INSTAGRAM_STANDARD', '1x1'), ('INSTAGRAM_STORY', '9x16')]


# ─────────────────────────────── utilidades ───────────────────────────────

def sem_acento(s):
    return ''.join(ch for ch in unicodedata.normalize('NFD', s) if unicodedata.category(ch) != 'Mn').lower().strip()


def nome_criativo(ad):
    return f'CR_{ad["name"]}'


def arquivo_imagem(codigo, formato, pasta=IMAGENS_DIR):
    achados = sorted(glob.glob(os.path.join(pasta, f'NIO_C2_{codigo}_{formato}_{VERSAO_ARTE}.png')))
    if len(achados) != 1:
        raise SystemExit(f'Esperava 1 imagem {codigo} {formato} ({VERSAO_ARTE}) em {pasta}, achei {len(achados)}.')
    return achados[0]


def checar_textos():
    for arte, ads in ANUNCIOS.items():
        for ad in ads:
            if not ad['img'].startswith(arte + '_'):
                raise SystemExit(f'{ad["name"]}: arte {ad["img"]} fora do grupo {arte} (Regular e BTU não se misturam).')
            t = (ad['texto'] + ' ' + ad['titulo']).lower()
            for p in c1.PROIBIDO:
                if p in t:
                    raise SystemExit(f'{ad["name"]}: termo proibido pela regra de conteúdo: "{p}"')
            if arte == 'BTU' and ('5g' in t or 'globoplay' in t):
                raise SystemExit(f'{ad["name"]}: BTU não cita 5G nem Globoplay (inclusos da Oferta 50 % não confirmados).')


def ler_config():
    """Valores de config_meta_ads_regras (Supabase Nio) pelo CLI, só leitura. Regra 15: nada fixo no código."""
    sql = "select chave, valor from config_meta_ads_regras where parceiro_id = 'dharma' and chave like 'c2_%'"
    r = subprocess.run(['npx.cmd', 'supabase', 'db', 'query', '--remote', '--read-only', sql],
                       cwd=REPO, capture_output=True, text=True, encoding='utf-8', timeout=180)
    txt = r.stdout[r.stdout.find('{'):] if '{' in r.stdout else ''
    if r.returncode != 0 or not txt:
        raise SystemExit(f'Não consegui ler config_meta_ads_regras: {r.stderr.strip()[:300]}')
    return {x['chave']: float(x['valor']) for x in json.loads(txt).get('rows', [])}


def carregar_saida():
    return json.load(open(SAIDA, encoding='utf-8')) if os.path.exists(SAIDA) else {}


def gravar_saida(d):
    d['atualizado_em'] = dt.datetime.now().astimezone().isoformat(timespec='seconds')
    with open(SAIDA, 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
        f.write('\n')


_api_original = c1.api


def _api_com_espera(*args, **kw):
    """Limite de chamadas da conta (code 17 / 80004, 07/11 na criação da C2): espera e tenta de novo, até ~10 min."""
    esperas = [60, 120, 180, 300, 300, 300, 300, 300]   # 80004 pode durar vários minutos
    for i in range(len(esperas) + 1):
        try:
            return _api_original(*args, **kw)
        except c1.ErroMeta as e:
            if e.code not in (17, 80004, 4, 613) or i == len(esperas):
                raise
            print(f'    · limite de chamadas da Meta (code {e.code}) — esperando {esperas[i]} s')
            time.sleep(esperas[i])


c1.api = _api_com_espera   # campanha1_jf.listar/criar_criativo/… chamam c1.api pelo módulo


def conectar():
    c1.TOKEN = c1.ler_token()
    if not c1.TOKEN:
        raise SystemExit('META_ACCESS_TOKEN_NIO ausente. Nada feito.')
    versao, conta = c1.escolher_versao()
    if conta.get('currency') != 'BRL':
        raise SystemExit(f'Conta {CONTA} não está em BRL. Parado.')
    print(f'Graph {versao} · conta {conta.get("name")} ({CONTA}) ok.')
    return versao


# ─────────────────────────────── cidades ───────────────────────────────

def chave_cidade(nome):
    r = c1.api('GET', 'search', {'type': 'adgeolocation', 'location_types': ['city'], 'q': nome,
                                 'country_code': 'BR', 'limit': 25})
    alvo = sem_acento(nome)

    def limpo(n):   # a Meta escreve "João Monlevade, Brazil" e "Santa Luzia (Minas Gerais)"
        n = sem_acento(n)
        for suf in (', brazil', ' (minas gerais)'):
            n = n[:-len(suf)] if n.endswith(suf) else n
        return n
    achados = [x for x in r.get('data', [])
               if x.get('type') == 'city' and limpo(x.get('name', '')) == alvo and x.get('region') == 'Minas Gerais']
    if not achados:
        return None
    # homônimos no mesmo estado (Santa Luzia: 5 chaves): a de 6 dígitos é o município; as de 7 são distritos/localidades
    x = min(achados, key=lambda y: (len(y['key']), int(y['key'])))
    return {'key': x['key'], 'name': x['name'], 'region': x.get('region'), 'region_id': x.get('region_id')}


def resolver_cidades(saida):
    cache = saida.get('cidades', {})
    faltam = []
    for cj in CONJUNTOS:
        for nome in cj['cidades']:
            if nome in cache and cache[nome]:
                continue
            k = chave_cidade(nome)
            cache[nome] = k
            print(f'  {nome:<24} → {k["key"] + " · " + k["name"] + "/" + k["region"] if k else "NÃO ACHADA no Meta"}')
            if not k:
                faltam.append(nome)
    saida['cidades'] = cache
    if faltam:
        saida.setdefault('anotacoes', []).append(f'cidades sem chave no Meta (seguiu sem elas): {", ".join(faltam)}')
    return cache


# ─────────────────────────────── payloads ───────────────────────────────

def payload_conjunto(cj, campanha_id, chaves, gasto_min_centavos):
    p = {
        'name': cj['name'], 'campaign_id': campanha_id, 'status': STATUS,
        'destination_type': 'WHATSAPP', 'optimization_goal': 'CONVERSATIONS', 'billing_event': 'IMPRESSIONS',
        'promoted_object': {'page_id': PAGINA, 'whatsapp_phone_number': c1.WHATSAPP_MARI},
        'targeting': {
            'geo_locations': {'cities': [{'key': k} for k in chaves], 'location_types': ['home', 'recent']},
            'age_min': 25, 'age_max': 65,
            'targeting_automation': {'advantage_audience': 0},
            **copy.deepcopy(c1.POSICIONAMENTOS),
        },
    }
    if gasto_min_centavos:
        p['daily_min_spend_target'] = gasto_min_centavos
    return p


def plano(saida, cfg):
    orc = cfg.get('c2_orcamento_diario')
    print(f'\nCampanha {CAMPANHA["name"]} · CBO R$ {orc}/dia · {STATUS}')
    for cj in CONJUNTOS:
        ks = [saida['cidades'][n]['key'] for n in cj['cidades'] if saida['cidades'].get(n)]
        print(f'  {cj["name"]}: {len(ks)}/{len(cj["cidades"])} cidades · artes {cj["arte"]}'
              + (f' · gasto mínimo R$ {cfg.get("c2_cj_jf_gasto_min")}' if cj['gasto_min'] else ''))
    for arte, ads in ANUNCIOS.items():
        for ad in ads:
            h1, h9 = f'<{ad["img"]}_1x1>', f'<{ad["img"]}_9x16>'
            desc, p = c1.payloads_criativo(ad, PAGINA, h1, h9)[0]
            p['name'] = nome_criativo(ad)
            dims = {h1: c1.dimensoes_png(arquivo_imagem(ad['img'], '1x1')),
                    h9: c1.dimensoes_png(arquivo_imagem(ad['img'], '9x16'))}
            c1.validar_criativo(p, dims)
            print(f'  {nome_criativo(ad)}: trava OK {dims[h1]} / {dims[h9]}')


# ─────────────────────────────── criar ───────────────────────────────

def criar(saida, cfg):
    orc = cfg.get('c2_orcamento_diario')
    if not orc or orc > VERBA_TETO:
        raise SystemExit(f'c2_orcamento_diario = {orc}: ausente ou acima do teto R$ {VERBA_TETO} deste prompt. Parado.')
    notas = saida.setdefault('anotacoes', [])
    saida.update({'conta': CONTA, 'pagina_id': PAGINA, 'instagram_id': c1.INSTAGRAM_ID, 'whatsapp': c1.WHATSAPP_MARI})

    print('\n1. Imagens')
    ja = {i['name']: i['hash'] for i in c1.listar(f'{CONTA}/adimages', 'hash,name,status', limite=2000)}
    hashes = saida.setdefault('imagens', {})
    for ads in ANUNCIOS.values():
        for ad in ads:
            for fmt in ('1x1', '9x16'):
                arq = arquivo_imagem(ad['img'], fmt)
                nome = os.path.basename(arq)
                chave = f'{ad["img"]}_{fmt}'
                if nome in ja:
                    hashes[chave] = ja[nome]
                    continue
                b = uuid.uuid4().hex
                corpo = (f'--{b}\r\nContent-Disposition: form-data; name="filename"; filename="{nome}"\r\n'
                         f'Content-Type: image/png\r\n\r\n').encode() + open(arq, 'rb').read() + f'\r\n--{b}--\r\n'.encode()
                r = c1.api('POST', f'{CONTA}/adimages', corpo=corpo, tipo=f'multipart/form-data; boundary={b}')
                hashes[chave] = list(r['images'].values())[0]['hash']
                print(f'  {chave}: enviada ({hashes[chave]})')
    print(f'  {len(hashes)} imagens prontas')
    gravar_saida(saida)

    print('\n2. Campanha')
    camp = c1.por_nome(c1.listar(f'{CONTA}/campaigns', 'id,name,status,effective_status'), CAMPANHA['name'])
    if camp:
        print(f'  já existe {camp["id"]} · {camp["effective_status"]}')
    else:
        camp = c1.api('POST', f'{CONTA}/campaigns', {**CAMPANHA, 'daily_budget': int(round(orc * 100)), 'status': STATUS})
        print(f'  criada {camp["id"]} (CBO R$ {orc}/dia)')
    saida['campanha'] = {'id': camp['id'], 'nome': CAMPANHA['name'], 'orcamento_diario': orc}
    gravar_saida(saida)

    print('\n3. Conjuntos')
    ex = c1.listar(f'{camp["id"]}/adsets', 'id,name,effective_status')
    conjuntos = saida.setdefault('conjuntos', {})
    agora = dt.datetime.now().astimezone().isoformat(timespec='seconds')
    for cj in CONJUNTOS:
        ks = [saida['cidades'][n]['key'] for n in cj['cidades'] if saida['cidades'].get(n)]
        s = c1.por_nome(ex, cj['name'])
        if s:
            conjuntos[cj['name']] = {**conjuntos.get(cj['name'], {}), 'id': s['id']}
            print(f'  {cj["name"]}: já existe {s["id"]} · {s["effective_status"]}')
            continue
        gm = int(round(cfg.get('c2_cj_jf_gasto_min', 0) * 100)) if cj['gasto_min'] else 0
        tent = []
        if gm:
            tent.append((f'gasto mínimo R$ {gm / 100:.0f}/dia',
                         lambda: c1.api('POST', f'{CONTA}/adsets', {**payload_conjunto(cj, camp['id'], ks, gm), 'start_time': agora})))
        tent.append(('sem gasto mínimo',
                     lambda: c1.api('POST', f'{CONTA}/adsets', {**payload_conjunto(cj, camp['id'], ks, 0), 'start_time': agora})))
        r, desc = c1.tentar(tent, cj['name'], notas)
        conjuntos[cj['name']] = {'id': r['id'], 'cidades': len(ks), 'variante': desc}
        print(f'  {cj["name"]}: criado {r["id"]} ({len(ks)} cidades · {desc})')
        gravar_saida(saida)

    print('\n4. Criativos')
    cr_ex = c1.listar(f'{CONTA}/adcreatives', 'id,name,status', limite=2000)
    criativos = saida.setdefault('criativos', {})
    dims = {hashes[f'{ad["img"]}_{fmt}']: c1.dimensoes_png(arquivo_imagem(ad['img'], fmt))
            for ads in ANUNCIOS.values() for ad in ads for fmt in ('1x1', '9x16')}
    for ads in ANUNCIOS.values():
        for ad in ads:
            nome = nome_criativo(ad)
            c = c1.por_nome(cr_ex, nome)
            if c:
                criativos[ad['name']] = {**criativos.get(ad['name'], {}), 'id': c['id']}
                print(f'  {nome}: já existe {c["id"]}')
                continue
            tent = []
            for d, p in c1.payloads_criativo(ad, PAGINA, hashes[f'{ad["img"]}_1x1'], hashes[f'{ad["img"]}_9x16']):
                p['name'] = nome
                tent.append((d, lambda p=p: c1.criar_criativo(CONTA, p, dims)))   # trava antes do POST
            r, desc = c1.tentar(tent, nome, notas)
            criativos[ad['name']] = {'id': r['id'], 'variante': desc}
            print(f'  {nome}: criado {r["id"]}')
            gravar_saida(saida)

    print('\n5. Anúncios')
    anuncios = saida.setdefault('anuncios', {})
    for cj in CONJUNTOS:
        sid = conjuntos[cj['name']]['id']
        ads_ex = c1.listar(f'{sid}/ads', 'id,name,effective_status')
        anuncios.setdefault(cj['name'], {})
        for ad in ANUNCIOS[cj['arte']]:
            x = c1.por_nome(ads_ex, ad['name'])
            if x:
                anuncios[cj['name']][ad['name']] = x['id']
                print(f'  {cj["name"]}/{ad["name"]}: já existe {x["id"]}')
                continue
            r = c1.api('POST', f'{CONTA}/ads', {'name': ad['name'], 'adset_id': sid, 'status': STATUS,
                                                'creative': {'creative_id': criativos[ad['name']]['id']}})
            anuncios[cj['name']][ad['name']] = r['id']
            print(f'  {cj["name"]}/{ad["name"]}: criado {r["id"]}')
        gravar_saida(saida)
    saida['anotacoes'] = notas
    gravar_saida(saida)


# ─────────────────────────────── prova ───────────────────────────────

def previas(saida):
    """1 anúncio por arte (REG em CJ_REGULAR, BTU em CJ_BTU) em feed IG e Stories IG + revisão de todos os 18."""
    tudo_ok, res = True, {}
    alvo = {**{a['name']: ('CJ_REGULAR', a) for a in ANUNCIOS['REG']}, **{a['name']: ('CJ_BTU', a) for a in ANUNCIOS['BTU']}}
    for nome, (cj, ad) in alvo.items():
        ad_id = saida['anuncios'][cj][nome]
        h = {'1x1': saida['imagens'][f'{ad["img"]}_1x1'], '9x16': saida['imagens'][f'{ad["img"]}_9x16']}
        print(f'\n{cj}/{nome} ({ad_id})')
        for formato, esperado in PREVIAS:
            ok, txt = r4.provar_previa(ad_id, f'C2_{cj}_{nome}', formato, esperado, h)
            print(f'  [{ {True: "OK ", False: "ERRO", None: "?  "}[ok] }] {formato:<20} {txt}')
            res.setdefault(ad_id, {})[formato] = {'ok': ok, 'texto': txt}
            tudo_ok &= ok is True
            time.sleep(1.5)
    print('\nRevisão (ad_review_feedback / issues_info) dos 18 anúncios:')
    revisao = {}
    for cj, ads in saida['anuncios'].items():
        for nome, ad_id in ads.items():
            r = c1.api('GET', ad_id, {'fields': 'name,status,effective_status,ad_review_feedback,issues_info'})
            prob = r.get('ad_review_feedback') or r.get('issues_info')
            revisao[ad_id] = {'effective_status': r.get('effective_status'), 'problema': prob}
            print(f'  {cj}/{nome:<18} {ad_id} · {r.get("effective_status")}' + (f' · ⚠️ {json.dumps(prob, ensure_ascii=False)}' if prob else ''))
            tudo_ok &= not prob
    saida['previas'] = {'em': dt.datetime.now().astimezone().isoformat(timespec='seconds'), 'tudo_ok': bool(tudo_ok),
                        'por_anuncio': res, 'revisao': revisao}
    gravar_saida(saida)
    print('\nPROVA OK' if tudo_ok else '\nPROVA INCOMPLETA — não ativar antes de conferir meta/_previas/')
    return tudo_ok


def mudar(ids, status):
    for i, nome in ids:
        c1.api('POST', i, {'status': status})
        r = c1.api('GET', i, {'fields': 'status,effective_status'})
        print(f'  {nome:<32} {i} · {r["status"]} / {r.get("effective_status")}')


def objetos_c2(saida):
    ads = [(i, f'{cj}/{n}') for cj, d in saida['anuncios'].items() for n, i in d.items()]
    cjs = [(v['id'], k) for k, v in saida['conjuntos'].items()]
    return ads, cjs, [(saida['campanha']['id'], saida['campanha']['nome'])]


def ativar(saida):
    if not (saida.get('previas') or {}).get('tudo_ok'):
        raise SystemExit('Prova das prévias não está OK no JSON. Rode --previas antes. Nada ativado.')
    ads, cjs, camp = objetos_c2(saida)
    print('\nAnúncios'); mudar(ads, 'ACTIVE')
    print('Conjuntos'); mudar(cjs, 'ACTIVE')
    print('Campanha'); mudar(camp, 'ACTIVE')
    saida['ativada_em'] = dt.datetime.now().astimezone().isoformat(timespec='seconds')
    gravar_saida(saida)


def status(saida, quais=('c2', 'c1')):
    out = {}
    if 'c2' in quais:
        print('\nC2')
        for grupo in objetos_c2(saida):
            for i, nome in grupo:
                r = c1.api('GET', i, {'fields': 'status,effective_status'})
                out[i] = r.get('effective_status')
                print(f'  {nome:<32} {i} · {r["status"]} / {r.get("effective_status")}')
    if 'c1' in quais:
        r = c1.api('GET', C1_CAMPANHA, {'fields': 'name,status,effective_status'})
        print(f'\nC1 {r["name"]} {C1_CAMPANHA} · {r["status"]} / {r.get("effective_status")}')
    return out


def status_em_lote(campanha_id):
    """3 chamadas no total (campanha, /adsets, /ads) em vez de 1 por objeto — a conta bate no limite (80004) fácil."""
    camp = c1.api('GET', campanha_id, {'fields': 'name,status,effective_status'})
    cjs = c1.listar(f'{campanha_id}/adsets', 'id,name,status,effective_status')
    ads = c1.listar(f'{campanha_id}/ads', 'id,name,status,effective_status,adset_id')
    return camp, cjs, ads


def pausar_c1(saida):
    camp, cjs, ads = status_em_lote(saida['campanha']['id'])
    ok = ('ACTIVE', 'IN_PROCESS', 'PENDING_REVIEW')
    ruins = {o['id']: o['effective_status'] for o in [camp] + cjs + ads if o['effective_status'] not in ok}
    print(f'C2: campanha {camp["effective_status"]} · {len(cjs)} conjuntos · {len(ads)} anúncios · fora de ACTIVE: {ruins or "nenhum"}')
    if ruins or len(cjs) != 3 or len(ads) != 18:
        raise SystemExit(f'C2 ainda não está ativa em todos os objetos ({ruins}). C1 NÃO pausada.')
    print('\nPausando a C1 (campanha → conjuntos → anúncios; nada apagado)')
    mudar([(C1_CAMPANHA, 'NIO_JF_C1_MSG_nov26')], 'PAUSED')
    _, cjs1, ads1 = status_em_lote(C1_CAMPANHA)
    for o in cjs1 + ads1:
        if o['status'] != 'PAUSED':
            c1.api('POST', o['id'], {'status': 'PAUSED'})
            print(f'  {o["name"]:<32} {o["id"]} · PAUSED')
    camp1, cjs1, ads1 = status_em_lote(C1_CAMPANHA)
    abertos = [o['id'] for o in [camp1] + cjs1 + ads1 if o['status'] != 'PAUSED']
    print(f'C1 conferida: campanha {camp1["status"]}/{camp1["effective_status"]} · {len(cjs1)} conjuntos · {len(ads1)} anúncios · '
          f'fora de PAUSED: {abertos or "nenhum"}')
    if abertos:
        raise SystemExit('C1 com objetos fora de PAUSED.')
    saida['c1_pausada_em'] = dt.datetime.now().astimezone().isoformat(timespec='seconds')
    gravar_saida(saida)


def main():
    ap = argparse.ArgumentParser(description='Campanha 2 MG (Meta Ads)')
    g = ap.add_mutually_exclusive_group(required=True)
    for op in ('dry-run', 'criar', 'previas', 'ativar', 'status', 'pausar-c1'):
        g.add_argument(f'--{op}', action='store_true')
    a = ap.parse_args()
    checar_textos()
    saida = carregar_saida()
    conectar()
    if a.dry_run or a.criar:
        cfg = ler_config()
        print(f'config: {cfg}')
        print('\nCidades')
        resolver_cidades(saida)
        if a.dry_run:
            plano(saida, cfg)
            print('\n(dry-run: nada criado; chaves de cidade gravadas no JSON)')
            gravar_saida(saida)
            return
        criar(saida, cfg)
        status(saida, ('c2',))
    elif a.previas:
        previas(saida)
    elif a.ativar:
        ativar(saida)
    elif a.status:
        status(saida)
    elif a.pausar_c1:
        pausar_c1(saida)


if __name__ == '__main__':
    main()
