#!/usr/bin/env python3
"""
NIOGEN | meta/campanha1_jf.py
Gerado em 05/11/2026 (America/Sao_Paulo) — Claude Code, prompt 20
Resumo: monta a campanha 1 de Meta Ads de Juiz de Fora (clique para WhatsApp → Mari) pela API de Marketing,
        TUDO em PAUSED. Idempotente: procura cada objeto pelo nome antes de criar.

Modos:
  python meta/campanha1_jf.py --dry-run              mostra o que faria (sem token: só o plano; com token: + o que já existe)
  python meta/campanha1_jf.py --descobrir            só leitura: conta, páginas promovíveis, WhatsApp da página, o que já existe
  python meta/campanha1_jf.py --page-id <ID>         cria o que falta (imagens, campanha, 2 conjuntos, 4 criativos, 8 anúncios)
  python meta/campanha1_jf.py --posicionamentos [--dry-run]   só troca os posicionamentos dos 2 conjuntos (07/11: sem
                                                     Status do WhatsApp e sem Audience Network); status não muda

Token: META_ACCESS_TOKEN_NIO (variável de ambiente, variável de usuário do Windows ou .env da raiz do clone — fora do git).
O token nunca é impresso, gravado ou logado. Nada é ativado por este script: status é sempre PAUSED.
"""
import argparse
import copy
import datetime as dt
import glob
import json
import os
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAIDA = os.path.join(REPO, 'meta', 'campanha1_jf_ids.json')
IMAGENS_DIR = r'C:\Users\ricar\Meu Drive\Projetos Claude\dharmapro-nio\criativos_nov26'

CONTA = 'act_764071346694892'          # CA | Nio Internet 01 – Ricardo (BRL)
WHATSAPP_MARI = '+553128881265'        # número da Mari na WABA Nio 1419511943295487
INSTAGRAM_ID = '17841411489935097'     # @mari.nio.internet (do BM Dharma, ligado à página e à CA em 06/11; antes: conta "da página" 17841423276547518)
VERSOES = ['v24.0', 'v25.0', 'v26.0', 'v23.0']
STATUS = 'PAUSED'                      # nunca muda: quem ativa é o Ricardo

CAMPANHA = {
    'name': 'NIO_JF_C1_MSG_nov26',
    'objective': 'OUTCOME_ENGAGEMENT',
    'special_ad_categories': [],
    'daily_budget': 7000,              # R$ 70/dia na campanha (CBO)
    'bid_strategy': 'LOWEST_COST_WITHOUT_CAP',
}

CONJUNTOS = [
    {'name': 'CJ_A_altopadrao', 'lat': -21.765, 'lon': -43.348, 'raios': [2.0]},
    {'name': 'CJ_B_medio', 'lat': -21.735, 'lon': -43.350, 'raios': [1.5, 2.0]},   # 2 km se a API recusar 1,5
]

MENSAGEM_PRONTA = 'Oi! Vi o anúncio e quero saber se a Nio chega na minha rua.'

ANUNCIOS = [
    {'name': 'AD_M1_preco2030', 'img': 'M1', 'titulo': 'Preço travado até 2030',
     'texto': 'Nio Fibra em Juiz de Fora com preço travado até 2030 🔒 600 Mega por R$ 95/mês no cartão, '
              'e 5G incluso a partir do Essencial. Chama no WhatsApp e consulta a sua rua.'},
    {'name': 'AD_G1_preco2030', 'img': 'G1', 'titulo': 'Internet que não sobe de preço',
     'texto': 'Internet fibra em Juiz de Fora que não sobe de preço: 600 Mega por R$ 95/mês no cartão, '
              'valor fixo até 2030. Consulte a sua rua pelo WhatsApp.'},
    {'name': 'AD_M2_troca', 'img': 'M2', 'titulo': 'Troque para a Nio',
     'texto': 'Sua internet aumentou de novo? Na Nio o preço fica travado até 2030. '
              'Trocar é simples: manda seu CEP no WhatsApp.'},
    {'name': 'AD_G2_cobertura', 'img': 'G2', 'titulo': 'Consulte a sua rua',
     'texto': 'A fibra já chega na sua rua? Mande seu CEP no WhatsApp e descubra agora. '
              'Planos a partir de R$ 95/mês no cartão, preço fixo até 2030.'},
]

# Regra de conteúdo (CLAUDE.md): nada disso pode aparecer em texto de anúncio.
PROIBIDO = ['sem fidelidade', 'desconto', 'instala amanhã', 'instalação em', 'grátis']

# Melhorias automáticas do Meta que reescrevem texto/imagem: opt-out (a IA do Meta não conhece a tabela vigente).
OPT_OUT = ['image_animation', 'text_overlay_translation', 'ig_video_native_subtitle', 'profile_card']
# Prompt 25: corte/ampliação automática e Advantage+ criativo também ficam OFF. A API de 05/11 só listou as 4 de cima
# como aceitas; tenta-se a lista completa primeiro e, se a API recusar as chaves extras, cai para a curta (anotado).
OPT_OUT_CORTE = ['image_auto_crop', 'adapt_to_placement', 'image_uncrop', 'pac_relaxation', 'text_optimizations']

# Prompt 25 (06/11): cada posicionamento com a sua arte. Posições VERTICAIS recebem a 9x16; o resto cai no fallback 1x1.
# Sem fallback, posição que não casa com regra nenhuma recebe a 1ª imagem (1x1) e a Meta amplia/corta (Stories de 06/11).
REGRA_VERTICAL = {
    'publisher_platforms': ['facebook', 'instagram', 'messenger', 'whatsapp'],
    'facebook_positions': ['story', 'facebook_reels', 'facebook_reels_overlay'],
    'instagram_positions': ['story', 'reels', 'profile_reels', 'reels_overlay'],
    'messenger_positions': ['story'],
    'whatsapp_positions': ['status'],
}
# 07/11/2026 (ordem do Ricardo): posicionamentos MANUAIS, sem Status do WhatsApp e sem Audience Network.
# Medido de 06/11 10h59 a 07/11: Status do WhatsApp levou R$ 41,76 de R$ 89,21 (47 %), CTR 0,28 %, 0 conversas;
# Audience Network R$ 2,54, 0 conversas. As 2 conversas vieram do feed do Instagram. O resto fica como estava.
#
# 13/11/2026 (Agente de Tráfego, "Sim, executar"): saíram do Facebook 'marketplace', 'search', 'profile_feed' e
# 'notification'. Medido em 13/11, por publisher_platform × platform_position: search R$ 1,94 em 12 impressões
# (CPM R$ 162) e 0 clique · marketplace 122 impressões e 0 clique · profile_feed 4 impressões · notification 6.
# Juntos: 144 impressões e R$ 3,59 — 2 % do dia, nenhuma conversa. No mesmo dia o Facebook Reels fez CTR 1,50 %
# (1.336 impressões, 9 cliques no link) e o feed do Instagram 0,32 % (937 impressões, 3 cliques).
# A mudança foi aplicada à mão pela API nos conjuntos CJ_JF e CJ_REGULAR da campanha 2 em 13/11 20h44; esta
# constante estava com a lista antiga e `--posicionamentos` reporia o lixo. O Instagram NÃO foi mexido: o feed do
# Instagram é o pior posicionamento do dia 13/11, mas carrega volume de verdade e 1 dia não condena.
POSICIONAMENTOS = {
    'publisher_platforms': ['facebook', 'instagram'],
    'facebook_positions': ['feed', 'instream_video', 'story',
                           'facebook_reels', 'facebook_reels_overlay'],
    'instagram_positions': ['stream', 'story', 'reels', 'explore_home', 'profile_feed'],
    'device_platforms': ['mobile', 'desktop'],
}
TAMANHO = {'1x1': (1080, 1080), '9x16': (1080, 1920)}
SUFIXO = '_v4'                         # sufixo do criativo (CR_<anúncio>_v4) e do anúncio (<anúncio>_v4)

GRAPH = None
TOKEN = None


# ─────────────────────────────── utilidades ───────────────────────────────

class ErroMeta(Exception):
    def __init__(self, status, corpo):
        self.status = status
        try:
            e = json.loads(corpo).get('error', {})
        except ValueError:
            e = {'message': corpo[:300]}
        self.code = e.get('code')
        self.subcode = e.get('error_subcode')
        self.msg = e.get('message', '')
        self.user = ' — '.join(x for x in (e.get('error_user_title'), e.get('error_user_msg')) if x)
        super().__init__(f'HTTP {status} · code {self.code}/{self.subcode} · {self.msg} {self.user}'.strip())


def ler_token():
    v = None
    if sys.platform == 'win32':
        # variável de usuário primeiro: um processo já aberto (terminal, app) guarda a cópia ANTIGA do ambiente
        # e continua usando o token rotacionado/revogado até ser reiniciado (06/11: "Bad signature" com token novo salvo)
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as h:
                v = winreg.QueryValueEx(h, 'META_ACCESS_TOKEN_NIO')[0]
        except OSError:
            v = None
    v = v or os.environ.get('META_ACCESS_TOKEN_NIO')
    if not v:
        env = os.path.join(REPO, '.env')
        if os.path.exists(env):
            for linha in open(env, encoding='utf-8'):
                if linha.strip().startswith('META_ACCESS_TOKEN_NIO='):
                    v = linha.split('=', 1)[1].strip().strip('"\'')
    return v or None


def _enc(params):
    out = {}
    for k, v in (params or {}).items():
        out[k] = json.dumps(v, ensure_ascii=False) if isinstance(v, (dict, list)) else str(v)
    return out


def api(method, path, params=None, corpo=None, tipo=None):
    url = f'{GRAPH}/{path}'
    headers = {'Authorization': f'Bearer {TOKEN}'}
    data = None
    if method == 'GET':
        if params:
            url += '?' + urllib.parse.urlencode(_enc(params))
    elif corpo is not None:
        data, headers['Content-Type'] = corpo, tipo
    else:
        data = urllib.parse.urlencode(_enc(params)).encode()
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        raise ErroMeta(e.code, e.read().decode('utf-8', 'replace')) from None


def listar(path, fields, limite=500):
    itens, params = [], {'fields': fields, 'limit': 200}
    r = api('GET', path, params)
    while True:
        itens += r.get('data', [])
        nxt = r.get('paging', {}).get('cursors', {}).get('after')
        if not nxt or not r.get('paging', {}).get('next') or len(itens) >= limite:
            return itens
        r = api('GET', path, {**params, 'after': nxt})


def por_nome(itens, nome):
    achados = [i for i in itens if i.get('name') == nome and i.get('effective_status', i.get('status')) not in ('DELETED', 'ARCHIVED')]
    return achados[0] if achados else None


def tentar(tentativas, rotulo, notas):
    """tentativas = [(descricao, funcao)]. Devolve (resultado, descricao) da 1ª que der certo."""
    erros = []
    for desc, fn in tentativas:
        try:
            r = fn()
            if erros:
                notas.append(f'{rotulo}: ficou "{desc}" — antes: ' + ' | '.join(erros))
            return r, desc
        except ErroMeta as e:
            erros.append(f'[{desc}] {e}')
            print(f'    · recusado ({desc}): {e}')
    raise SystemExit(f'{rotulo}: todas as tentativas falharam.\n  ' + '\n  '.join(erros))


def escolher_versao():
    global GRAPH
    versoes = [os.environ['META_GRAPH_VERSION']] if os.environ.get('META_GRAPH_VERSION') else VERSOES
    ultimo = None
    for v in versoes:
        GRAPH = f'https://graph.facebook.com/{v}'
        try:
            conta = api('GET', CONTA, {'fields': 'name,currency,account_status,timezone_name'})
            return v, conta
        except ErroMeta as e:
            ultimo = e
            if e.code == 2635 or 'version' in e.msg.lower():
                continue
            raise SystemExit(f'Falha ao ler a conta {CONTA}: {e}')
    raise SystemExit(f'Nenhuma versão da Graph API aceitou: {ultimo}')


def arquivo_imagem(pasta, codigo, formato):
    achados = sorted(glob.glob(os.path.join(pasta, f'NIO_JF_{codigo}_*_{formato}_*.png')))
    if len(achados) != 1:
        raise SystemExit(f'Esperava 1 imagem {codigo} {formato} em {pasta}, achei {len(achados)}.')
    return achados[0]


def welcome_json():
    return json.dumps({
        'type': 'VISUAL_EDITOR', 'version': 2, 'landing_screen_type': 'welcome_message', 'media_type': 'text',
        'text_format': {'customer_action_type': 'autofill_message',
                        'message': {'autofill_message': {'content': MENSAGEM_PRONTA}, 'text': MENSAGEM_PRONTA}},
    }, ensure_ascii=False)


# ─────────────────────────────── payloads ───────────────────────────────

def payload_conjunto(cj, campanha_id, page_id, raio, com_wpp):
    po = {'page_id': page_id}
    if com_wpp:
        po['whatsapp_phone_number'] = WHATSAPP_MARI
    return {
        'name': cj['name'], 'campaign_id': campanha_id, 'status': STATUS,
        'destination_type': 'WHATSAPP', 'optimization_goal': 'CONVERSATIONS', 'billing_event': 'IMPRESSIONS',
        'promoted_object': po,
        'targeting': {
            'geo_locations': {'custom_locations': [{'latitude': cj['lat'], 'longitude': cj['lon'],
                                                    'radius': raio, 'distance_unit': 'kilometer'}]},
            'age_min': 25, 'age_max': 65,
            'targeting_automation': {'advantage_audience': 0},   # idade 25–65 é limite, não sugestão
            **copy.deepcopy(POSICIONAMENTOS),
        },
    }


def aplicar_posicionamentos(dry_run):
    """Troca SÓ os posicionamentos dos conjuntos que já existem (público, raio, idade e status ficam como estão)."""
    camp = por_nome(listar(f'{CONTA}/campaigns', 'id,name,status,effective_status'), CAMPANHA['name'])
    if not camp:
        raise SystemExit(f'Campanha {CAMPANHA["name"]} não existe. Nada feito.')
    lixo = ('page_types', 'dt_consolidation_state')
    for s in listar(f'{camp["id"]}/adsets', 'id,name,status,effective_status,targeting'):
        if s['name'] not in {c['name'] for c in CONJUNTOS}:
            continue
        t = {k: v for k, v in s.get('targeting', {}).items()
             if not k.startswith('effective_') and k not in lixo and not k.endswith('_positions')
             and k not in ('publisher_platforms', 'device_platforms')}
        t.update(copy.deepcopy(POSICIONAMENTOS))
        antes = s.get('targeting', {}).get('publisher_platforms', 'automático')
        print(f'  {s["name"]} {s["id"]} ({s["status"]}): {antes} → {t["publisher_platforms"]}')
        if dry_run:
            continue
        api('POST', s['id'], {'targeting': t})
        r = api('GET', s['id'], {'fields': 'status,effective_status,targeting'})['targeting']
        # 13/11: a conferência olhava só publisher_platforms, então um posicionamento a mais ou a menos passava
        # batido. Agora compara as 4 listas (sem ordem, porque a Meta devolve na ordem dela).
        divergiu = [k for k, v in POSICIONAMENTOS.items() if sorted(r.get(k) or []) != sorted(v)]
        ok = not divergiu and 'whatsapp_positions' not in r and 'audience_network_positions' not in r
        print(f'    conferido: {r.get("publisher_platforms")} · fb {r.get("facebook_positions")} · '
              f'ig {r.get("instagram_positions")} · {"OK" if ok else "DIVERGENTE"}')
        if not ok:
            if divergiu:
                for k in divergiu:
                    print(f'    {k}: esperado {sorted(POSICIONAMENTOS[k])} · veio {sorted(r.get(k) or [])}')
            else:
                print('    veio com whatsapp_positions ou audience_network_positions')
            raise SystemExit('Posicionamento não ficou como o esperado. Parado.')


REGRA_FEEDS_1X1 = {   # só no layout 3 (prova de 05/11: posições explícitas casam com os feeds); o fallback vem depois
    'publisher_platforms': ['facebook', 'instagram', 'audience_network', 'messenger'],
    'facebook_positions': ['feed', 'right_hand_column', 'marketplace', 'video_feeds',
                           'search', 'profile_feed', 'instream_video', 'notification'],
    'instagram_positions': ['stream', 'explore', 'explore_home', 'profile_feed', 'ig_search'],
    'audience_network_positions': ['classic', 'instream_video', 'rewarded_video'],
    'messenger_positions': ['messenger_home'],
}


def regras_posicionamento(layout=2):
    """Regra 1: 9x16 em todas as posições verticais. Última regra: fallback 1x1 SEM customization_spec (= "o resto").
    layout 2 (padrão, prompt 25): vertical + fallback. layout 3: vertical + feeds explícitos + fallback."""
    r = [{'priority': 1, 'image_label': {'name': 'img_9x16'}, 'customization_spec': copy.deepcopy(REGRA_VERTICAL)}]
    if layout == 3:
        r.append({'priority': 2, 'image_label': {'name': 'img_1x1'}, 'customization_spec': copy.deepcopy(REGRA_FEEDS_1X1)})
    # A Meta recusa (1487390, "tente novamente mais tarde") regra SEM customization_spec; com só a faixa de idade, aceita —
    # e é como ela mesma guarda as regras (age_min 13 / age_max 65 = sem restrição de idade). Nenhuma posição = "o resto".
    r.append({'priority': len(r) + 1, 'image_label': {'name': 'img_1x1'}, 'customization_spec': {'age_min': 13, 'age_max': 65}})
    return r


def payloads_criativo(ad, page_id, h1, h9, ig=INSTAGRAM_ID, layout=2):
    """Variantes em ordem de preferência: (descricao, payload). Todas passam por validar_criativo antes do POST;
    nenhuma abre mão de 9x16 + fallback, mensagem pronta ou opt-out (variante que enfraquece isso não existe mais)."""
    nome = nome_criativo(ad)
    oss = {'page_id': page_id, 'instagram_user_id': ig} if ig else {'page_id': page_id}
    link = 'https://api.whatsapp.com/send'

    def afs():
        return {
            'images': [{'hash': h1, 'adlabels': [{'name': 'img_1x1'}]}, {'hash': h9, 'adlabels': [{'name': 'img_9x16'}]}],
            'bodies': [{'text': ad['texto']}], 'titles': [{'text': ad['titulo']}],
            'link_urls': [{'website_url': link}], 'call_to_action_types': ['WHATSAPP_MESSAGE'],
            'ad_formats': ['SINGLE_IMAGE'], 'optimization_type': 'PLACEMENT',
            'asset_customization_rules': regras_posicionamento(layout),
            'additional_data': {'page_welcome_message': welcome_json()},
        }

    out = []
    for desc, chaves in (('opt-out completo (animação, tradução, legenda, cartão, corte, adaptação, uncrop, PAC, texto)', OPT_OUT + OPT_OUT_CORTE),
                         ('opt-out curto (só as 4 que a API de 05/11 aceitou)', OPT_OUT)):
        dof = {'creative_features_spec': {k: {'enroll_status': 'OPT_OUT'} for k in chaves}}
        out.append((f'1x1 fallback + 9x16 vertical (layout {layout}), mensagem pronta · {desc}',
                    {'name': nome, 'object_story_spec': dict(oss), 'asset_feed_spec': afs(), 'degrees_of_freedom_spec': dof}))
    return out


def nome_criativo(ad):
    # criativo não se edita: cada correção ganha nome novo e a leva anterior vira *_descartado
    #   1ª leva (sem sufixo): sem conta do Instagram → anúncio recusado
    #   _ig: regra do 1x1 sem posições → não casava com nenhum feed (só stories/reels)
    #   _v2: Instagram "da página" + posições explícitas
    #   _v3: @mari.nio.internet + posições explícitas (sem fallback: Stories de 06/11 receberam a 1x1 ampliada)
    #   _v4: 9x16 em TODAS as verticais + fallback 1x1 + trava validar_criativo (prompt 25)
    return f'CR_{ad["name"]}{SUFIXO}'


def nome_anuncio(ad):
    return f'{ad["name"]}{SUFIXO}'


# ─────────────────────────────── trava (prompt 25) ───────────────────────────────

class CriativoReprovado(Exception):
    """validar_criativo recusou o envio — nada foi mandado à Meta."""


def dimensoes_png(caminho):
    """(largura, altura) lidas do cabeçalho IHDR do PNG — sem Pillow."""
    with open(caminho, 'rb') as f:
        b = f.read(24)
    if b[:8] != b'\x89PNG\r\n\x1a\n':
        raise CriativoReprovado(f'{os.path.basename(caminho)}: não é PNG')
    return struct.unpack('>II', b[16:24])


def validar_criativo(spec, dimensoes):
    """Recusa (CriativoReprovado) o payload de POST /adcreatives que repetiria o erro de 06/11. Chamar ANTES de todo POST.
    spec = payload do criativo; dimensoes = {hash_da_imagem: (largura, altura)} (lidas do arquivo local, não da Meta).
    Confere: (1) 1x1 e 9x16 presentes, cada uma no tamanho exato; (2) regra vertical cobre toda a lista de REGRA_VERTICAL;
    (3) há regra de fallback (1x1 sem posição) e ela vem depois da vertical; (4) nenhum recurso automático em OPT_IN."""
    erros = []
    afs = spec.get('asset_feed_spec') or {}

    # 1. imagens
    por_rotulo = {}
    for im in afs.get('images', []):
        for lab in im.get('adlabels', []):
            por_rotulo[lab.get('name')] = im.get('hash')
    for rot, fmt in (('img_1x1', '1x1'), ('img_9x16', '9x16')):
        h = por_rotulo.get(rot)
        if not h:
            erros.append(f'falta a versão {fmt} (rótulo {rot}) — todo anúncio de imagem leva 1x1 e 9x16')
            continue
        dim = dimensoes.get(h)
        if dim is None:
            erros.append(f'tamanho da {fmt} ({h}) não informado — não dá para provar {TAMANHO[fmt][0]}×{TAMANHO[fmt][1]}')
        elif tuple(dim) != TAMANHO[fmt]:
            erros.append(f'a {fmt} tem {dim[0]}×{dim[1]}, o exigido é {TAMANHO[fmt][0]}×{TAMANHO[fmt][1]}')
    if len(afs.get('images', [])) < 2:
        erros.append('menos de 2 imagens no criativo')

    # 2. regra vertical
    regras = sorted(afs.get('asset_customization_rules', []), key=lambda r: r.get('priority', 999))
    vert = [r for r in regras if (r.get('image_label') or {}).get('name') == 'img_9x16']
    if not vert:
        erros.append('nenhuma regra usa a 9x16')
    else:
        cobertas = {}
        for r in vert:
            for k, v in (r.get('customization_spec') or {}).items():
                cobertas.setdefault(k, set()).update(v)
        for k, exigidas in REGRA_VERTICAL.items():
            faltam = sorted(set(exigidas) - cobertas.get(k, set()))
            if faltam:
                erros.append(f'regra vertical não cobre {k}: faltam {", ".join(faltam)}')

    # 3. fallback: regra da 1x1 sem nenhuma posição, depois da vertical
    def sem_posicao(r):
        cs = r.get('customization_spec') or {}
        return not any(k.endswith('_positions') or k == 'publisher_platforms' for k in cs)
    fb = [r for r in regras if (r.get('image_label') or {}).get('name') == 'img_1x1' and sem_posicao(r)]
    if not fb:
        erros.append('falta a regra de fallback (1x1 sem customization_spec de posição): posição não coberta receberia a 1ª imagem ampliada')
    elif vert and min(r.get('priority', 999) for r in fb) <= min(r.get('priority', 999) for r in vert):
        erros.append('o fallback precisa ter prioridade MAIOR (vir depois) que a regra vertical')

    # 4. recursos automáticos
    feats = (spec.get('degrees_of_freedom_spec') or {}).get('creative_features_spec')
    if not feats:
        erros.append('degrees_of_freedom_spec ausente: sem ele a Meta liga as melhorias automáticas por padrão')
    else:
        for k, v in feats.items():
            if (v or {}).get('enroll_status') != 'OPT_OUT':
                erros.append(f'recurso automático {k} não está OPT_OUT ({(v or {}).get("enroll_status")})')
    for k in spec.get('contextual_multi_ads') or {}:
        erros.append(f'contextual_multi_ads.{k}: Advantage+ criativo não é permitido')

    if erros:
        raise CriativoReprovado(f'{spec.get("name", "?")}: criativo recusado pela trava —\n  ' + '\n  '.join(erros))
    return True


def dimensoes_por_hash(hashes, pasta):
    """{hash: (l, a)} de cada imagem, lidas dos PNGs locais do Drive (chave do dict 'hashes' = '<img>_<formato>')."""
    out = {}
    for chave, h in hashes.items():
        cod, fmt = chave.rsplit('_', 1)
        out[h] = dimensoes_png(arquivo_imagem(pasta, cod, fmt))
    return out


def arquivar_versao_anterior(saida):
    """Se o JSON ainda guarda os criativos/anúncios de outra versão (ex.: v3), move para saida['legado'] — histórico, nunca apagado."""
    atual = saida.get('versao_criativos', '_v3')
    if atual == SUFIXO:
        return
    saida.setdefault('legado', {})[atual] = {'criativos': saida.pop('criativos', {}), 'anuncios': saida.pop('anuncios', {})}
    saida['versao_criativos'] = SUFIXO


def criar_criativo(conta, spec, dimensoes):
    """ÚNICO caminho para POST /adcreatives neste repo: valida antes de enviar."""
    validar_criativo(spec, dimensoes)
    return api('POST', f'{conta}/adcreatives', spec)


# ─────────────────────────────── principal ───────────────────────────────

def checar_textos():
    for ad in ANUNCIOS:
        t = (ad['texto'] + ' ' + ad['titulo']).lower()
        for p in PROIBIDO:
            if p in t:
                raise SystemExit(f'{ad["name"]}: texto com termo proibido pela regra de conteúdo: "{p}"')


def carregar_saida():
    if os.path.exists(SAIDA):
        return json.load(open(SAIDA, encoding='utf-8'))
    return {}


def gravar_saida(d):
    d['atualizado_em'] = dt.datetime.now().astimezone().isoformat(timespec='seconds')
    with open(SAIDA, 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
        f.write('\n')


def plano_offline(pasta, layout=2):
    print('\n== PLANO (sem token: nada foi consultado na Meta) ==')
    print(f'Conta {CONTA} · tudo {STATUS}')
    for ad in ANUNCIOS:
        for fmt in ('1x1', '9x16'):
            print(f'  imagem {ad["img"]} {fmt}: {os.path.basename(arquivo_imagem(pasta, ad["img"], fmt))}')
    print('\nCampanha:', json.dumps({**CAMPANHA, 'status': STATUS}, ensure_ascii=False))
    for cj in CONJUNTOS:
        p = payload_conjunto(cj, '<CAMPANHA_ID>', '<PAGE_ID>', cj['raios'][0], True)
        print(f'\nConjunto {cj["name"]} (raios tentados: {cj["raios"]} km):', json.dumps(p, ensure_ascii=False))
    for ad in ANUNCIOS:
        h1, h9 = f'<hash {ad["img"]}_1x1>', f'<hash {ad["img"]}_9x16>'
        desc, p = payloads_criativo(ad, '<PAGE_ID>', h1, h9, layout=layout)[0]
        dims = {h1: dimensoes_png(arquivo_imagem(pasta, ad['img'], '1x1')), h9: dimensoes_png(arquivo_imagem(pasta, ad['img'], '9x16'))}
        validar_criativo(p, dims)          # a trava roda também no plano: criativo reprovado nem chega à Meta
        print(f'\nCriativo {nome_criativo(ad)} (1ª variante: {desc}) · trava OK ({dims[h1]} / {dims[h9]}):')
        print('  regras:', json.dumps(p['asset_feed_spec']['asset_customization_rules'], ensure_ascii=False))
        print('  degrees_of_freedom_spec:', json.dumps(p['degrees_of_freedom_spec'], ensure_ascii=False))
    for cj in CONJUNTOS:
        for ad in ANUNCIOS:
            print(f'Anúncio {nome_anuncio(ad)} em {cj["name"]} → criativo {nome_criativo(ad)} · {STATUS}')


def descobrir(conta_info):
    print(f'\nConta: {conta_info.get("name")} · {conta_info.get("currency")} · status {conta_info.get("account_status")} · {conta_info.get("timezone_name")}')
    paginas = []
    for path in (f'{CONTA}/promote_pages', 'me/accounts'):
        try:
            for p in listar(path, 'id,name'):
                if p['id'] not in [x['id'] for x in paginas]:
                    paginas.append(p)
        except ErroMeta as e:
            print(f'  ({path} indisponível: {e})')
    print('\nPáginas que esta conta pode promover:')
    for p in paginas:
        wpp = info_whatsapp(p['id'])
        print(f'  {p["id"]} · {p["name"]} · WhatsApp: {wpp}')
    if not paginas:
        print('  nenhuma — a página precisa estar no BM Dharma com acesso da CA / do Nio_API.')
    return paginas


def info_whatsapp(page_id):
    for campo in ('whatsapp_number', 'whatsapp_connected_number'):
        try:
            r = api('GET', page_id, {'fields': campo})
            v = r.get(campo)
            if v:
                ok = ''.join(c for c in str(v) if c.isdigit()).endswith('3128881265')
                return f'{v} ({"é o da Mari" if ok else "NÃO é o da Mari +55 31 2888-1265"})'
            # vínculo feito pelo perfil do número no BM (Contas do WhatsApp → Perfil do telefone → Facebook)
            # não aparece neste campo; quem prova é a criação do conjunto com whatsapp_phone_number
            return f'não exposto em {campo} (vínculo pelo BM não aparece aqui — o conjunto valida)'
        except ErroMeta:
            continue
    return 'não legível com este token (conferir no BM)'


def main():
    global TOKEN
    ap = argparse.ArgumentParser(description='Campanha 1 JF (Meta Ads, tudo PAUSED)')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--descobrir', action='store_true')
    ap.add_argument('--page-id')
    ap.add_argument('--imagens', default=IMAGENS_DIR)
    ap.add_argument('--layout', type=int, choices=(2, 3), default=2,
                    help='2 = vertical + fallback (prompt 25); 3 = vertical + feeds explícitos + fallback')
    ap.add_argument('--offline', action='store_true', help='plano sem consultar a Meta (ignora o token)')
    ap.add_argument('--posicionamentos', action='store_true',
                    help='só troca os posicionamentos dos 2 conjuntos existentes (POSICIONAMENTOS); com --dry-run só mostra')
    a = ap.parse_args()

    checar_textos()
    TOKEN = None if a.offline else ler_token()
    if not TOKEN:
        if a.dry_run or a.offline:
            plano_offline(a.imagens, a.layout)
            return
        raise SystemExit('META_ACCESS_TOKEN_NIO ausente (variável de ambiente / de usuário / .env). Nada feito.')

    versao, conta = escolher_versao()
    if conta.get('currency') != 'BRL':
        raise SystemExit(f'Conta {CONTA} não está em BRL ({conta.get("currency")}). Parado.')
    print(f'Graph {versao} · conta {CONTA} ok.')

    if a.posicionamentos:
        aplicar_posicionamentos(a.dry_run)
        return
    if a.descobrir:
        descobrir(conta)
    if a.descobrir or (a.dry_run and not a.page_id):
        existentes()
        if a.dry_run:
            plano_offline(a.imagens, a.layout)
        return
    if not a.page_id:
        raise SystemExit('Informe --page-id (confirmado com o Ricardo). Rode --descobrir para listar as páginas.')

    criar(a, conta, versao)


def existentes():
    camp = por_nome(listar(f'{CONTA}/campaigns', 'id,name,status,effective_status'), CAMPANHA['name'])
    print(f'\nCampanha {CAMPANHA["name"]}: {camp["id"] + " · " + camp["effective_status"] if camp else "não existe"}')
    if camp:
        for s in listar(f'{camp["id"]}/adsets', 'id,name,effective_status'):
            print(f'  conjunto {s["name"]}: {s["id"]} · {s["effective_status"]}')
            for ad in listar(f'{s["id"]}/ads', 'id,name,effective_status'):
                print(f'    anúncio {ad["name"]}: {ad["id"]} · {ad["effective_status"]}')
    return camp


def criar(a, conta, versao):
    dry = a.dry_run
    page_id = a.page_id
    saida = carregar_saida()
    notas = saida.get('anotacoes', [])
    saida.update({'conta': CONTA, 'graph': versao, 'pagina_id': page_id, 'whatsapp': WHATSAPP_MARI,
                  'waba': '1419511943295487'})

    wpp = info_whatsapp(page_id)
    print(f'Página {page_id} · WhatsApp: {wpp}')
    if 'NÃO é o da Mari' in wpp:
        raise SystemExit('A página tem outro WhatsApp vinculado. Parado: vincular o +55 31 2888-1265 à página no BM.')

    # 1. imagens
    print('\n1. Imagens')
    ja = {i['name']: i['hash'] for i in listar(f'{CONTA}/adimages', 'hash,name,status')}
    hashes = saida.get('imagens', {})
    for ad in ANUNCIOS:
        for fmt in ('1x1', '9x16'):
            arq = arquivo_imagem(a.imagens, ad['img'], fmt)
            nome = os.path.basename(arq)
            chave = f'{ad["img"]}_{fmt}'
            if nome in ja:
                hashes[chave] = ja[nome]
                print(f'  {chave}: já existe ({ja[nome]})')
            elif dry:
                print(f'  {chave}: subiria {nome}')
            else:
                b = uuid.uuid4().hex
                dados = open(arq, 'rb').read()
                corpo = (f'--{b}\r\nContent-Disposition: form-data; name="filename"; filename="{nome}"\r\n'
                         f'Content-Type: image/png\r\n\r\n').encode() + dados + f'\r\n--{b}--\r\n'.encode()
                r = api('POST', f'{CONTA}/adimages', corpo=corpo, tipo=f'multipart/form-data; boundary={b}')
                hashes[chave] = list(r['images'].values())[0]['hash']
                print(f'  {chave}: enviada ({hashes[chave]})')
    saida['imagens'] = hashes

    # 2. campanha
    print('\n2. Campanha')
    camp = por_nome(listar(f'{CONTA}/campaigns', 'id,name,status,effective_status'), CAMPANHA['name'])
    if camp:
        print(f'  já existe: {camp["id"]} · {camp["effective_status"]}')
    elif dry:
        print(f'  criaria {CAMPANHA["name"]} ({STATUS})')
    else:
        camp = api('POST', f'{CONTA}/campaigns', {**CAMPANHA, 'status': STATUS})
        print(f'  criada: {camp["id"]}')
    if camp:
        saida['campanha'] = {'id': camp['id'], 'nome': CAMPANHA['name']}
    if dry and not camp:
        print('\n(dry-run: o resto depende da campanha existir — veja o plano completo abaixo)')
        plano_offline(a.imagens)
        return

    # 3. conjuntos
    print('\n3. Conjuntos')
    conj_ex = listar(f'{camp["id"]}/adsets', 'id,name,effective_status,targeting') if camp else []
    conjuntos = saida.get('conjuntos', {})
    for cj in CONJUNTOS:
        s = por_nome(conj_ex, cj['name'])
        if s:
            raio = s.get('targeting', {}).get('geo_locations', {}).get('custom_locations', [{}])[0].get('radius')
            conjuntos[cj['name']] = {'id': s['id'], 'raio_km': raio}
            print(f'  {cj["name"]}: já existe {s["id"]} · raio {raio} km · {s["effective_status"]}')
            continue
        if dry:
            print(f'  criaria {cj["name"]} (raio {cj["raios"][0]} km)')
            continue
        tent = []
        for raio in cj['raios']:
            for com_wpp in (True, False):
                desc = f'raio {raio} km' + (', com número do WhatsApp' if com_wpp else ', sem número (só página)')
                tent.append((desc, lambda r=raio, w=com_wpp: (api('POST', f'{CONTA}/adsets',
                             payload_conjunto(cj, camp['id'], page_id, r, w)), r)))
        (r, raio), desc = tentar(tent, cj['name'], notas)
        conjuntos[cj['name']] = {'id': r['id'], 'raio_km': raio}
        print(f'  {cj["name"]}: criado {r["id"]} ({desc})')
    saida['conjuntos'] = conjuntos

    # 4. criativos
    print('\n4. Criativos')
    arquivar_versao_anterior(saida)        # v3 → saida['legado']['_v3']; os IDs v4 entram limpos em criativos/anuncios
    cr_ex = listar(f'{CONTA}/adcreatives', 'id,name,status')
    criativos = saida.get('criativos', {})
    for ad in ANUNCIOS:
        nome = nome_criativo(ad)
        c = por_nome(cr_ex, nome)
        if c:
            criativos[ad['name']] = {**criativos.get(ad['name'], {}), 'id': c['id']}
            print(f'  {nome}: já existe {c["id"]}')
            continue
        if dry:
            print(f'  criaria {nome}')
            continue
        h1, h9 = hashes[f'{ad["img"]}_1x1'], hashes[f'{ad["img"]}_9x16']
        dims = dimensoes_por_hash(hashes, a.imagens)
        # criar_criativo = validar_criativo + POST; CriativoReprovado não é ErroMeta: aborta tudo, nada vai à Meta
        tent = [(d, lambda p=p: criar_criativo(CONTA, p, dims))
                for d, p in payloads_criativo(ad, page_id, h1, h9, layout=getattr(a, 'layout', 2))]
        r, desc = tentar(tent, nome, notas)
        criativos[ad['name']] = {'id': r['id'], 'variante': desc}
        print(f'  {nome}: criado {r["id"]} ({desc})')
    saida['criativos'] = criativos

    # 5. anúncios
    print('\n5. Anúncios')
    novos = []
    anuncios = saida.get('anuncios', {})
    for cj in CONJUNTOS:
        sid = conjuntos.get(cj['name'], {}).get('id')
        if not sid:
            continue
        ads_ex = listar(f'{sid}/ads', 'id,name,effective_status,creative{id}')
        anuncios.setdefault(cj['name'], {})
        for ad in ANUNCIOS:
            x = por_nome(ads_ex, nome_anuncio(ad))
            if x:
                anuncios[cj['name']][ad['name']] = x['id']
                quer = criativos.get(ad['name'], {}).get('id')
                tem = x.get('creative', {}).get('id')
                if quer and tem != quer and not dry:
                    api('POST', x['id'], {'creative': {'creative_id': quer}})      # status não muda (segue PAUSED)
                    print(f'  {cj["name"]}/{ad["name"]}: já existe {x["id"]} · criativo trocado {tem} → {quer}')
                else:
                    print(f'  {cj["name"]}/{ad["name"]}: já existe {x["id"]} · {x["effective_status"]}'
                          + (f' · trocaria criativo {tem} → {quer}' if quer and tem != quer else ''))
            elif dry:
                print(f'  criaria {cj["name"]}/{ad["name"]}')
            else:
                r = api('POST', f'{CONTA}/ads', {'name': nome_anuncio(ad), 'adset_id': sid, 'status': STATUS,
                                                 'creative': {'creative_id': criativos[ad['name']]['id']}})
                anuncios[cj['name']][ad['name']] = r['id']
                novos.append(r['id'])
                print(f'  {cj["name"]}/{nome_anuncio(ad)}: criado {r["id"]}')
    saida['anuncios'] = anuncios

    if dry:
        print('\n(dry-run: nada criado, nada gravado)')
        return

    # 6. prova: os anúncios desta rodada ficaram PAUSED (campanha e conjuntos já existentes não são tocados aqui)
    print('\n6. Conferência de status')
    ids = list(dict.fromkeys(novos + [i for d in anuncios.values() for i in d.values()]))
    r = {i: api('GET', i, {'fields': 'name,status,effective_status'}) for i in ids}   # ?ids= foi descontinuado
    ativos = [f'{v["name"]} ({k})' for k, v in r.items() if k in novos and v.get('status') != 'PAUSED']
    for k, v in r.items():
        print(f'  {v["name"]:<24} {k} · {v["status"]} / {v.get("effective_status")}')
    saida['anotacoes'] = notas
    gravar_saida(saida)
    print(f'\nIDs em {os.path.relpath(SAIDA, REPO)}')
    if ativos:
        raise SystemExit('ATENÇÃO: objetos fora de PAUSED: ' + ', '.join(ativos))
    for n in notas:
        print('  nota:', n)


if __name__ == '__main__':
    main()
