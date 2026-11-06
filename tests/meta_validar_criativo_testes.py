#!/usr/bin/env python3
"""
NIOGEN | tests/meta_validar_criativo_testes.py
Gerado em 06/11/2026 — Claude Code, prompt 25
Resumo: testes offline (sem token, sem rede) da trava validar_criativo de meta/campanha1_jf.py.
        python tests/meta_validar_criativo_testes.py
"""
import copy
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'meta'))
import campanha1_jf as c  # noqa: E402

AD = c.ANUNCIOS[0]
H1, H9 = 'h_1x1', 'h_9x16'
DIMS = {H1: (1080, 1080), H9: (1080, 1920)}
falhas = []


def bom(layout=2, variante=0):
    return copy.deepcopy(c.payloads_criativo(AD, 'PAG', H1, H9, layout=layout)[variante][1])


def espera_ok(rotulo, spec, dims=DIMS):
    try:
        c.validar_criativo(spec, dims)
    except c.CriativoReprovado as e:
        falhas.append(f'{rotulo}: deveria passar e foi recusado — {e}')


def espera_recusa(rotulo, spec, trecho, dims=DIMS):
    try:
        c.validar_criativo(spec, dims)
    except c.CriativoReprovado as e:
        if trecho not in str(e):
            falhas.append(f'{rotulo}: recusou, mas sem "{trecho}" — {e}')
        return
    falhas.append(f'{rotulo}: deveria ser recusado e passou')


# ── passa ──
for layout in (2, 3):
    for v in (0, 1):
        espera_ok(f'layout {layout} variante {v}', bom(layout, v))

# ── imagens ──
s = bom(); s['asset_feed_spec']['images'] = [i for i in s['asset_feed_spec']['images'] if i['hash'] != H9]
espera_recusa('sem a 9x16', s, 'falta a versão 9x16')
s = bom(); s['asset_feed_spec']['images'] = [i for i in s['asset_feed_spec']['images'] if i['hash'] != H1]
espera_recusa('sem a 1x1', s, 'falta a versão 1x1')
espera_recusa('9x16 com tamanho errado', bom(), 'a 9x16 tem 1080×1350', {H1: (1080, 1080), H9: (1080, 1350)})
espera_recusa('1x1 com tamanho errado', bom(), 'a 1x1 tem 1080×1350', {H1: (1080, 1350), H9: (1080, 1920)})
espera_recusa('tamanho não informado', bom(), 'não informado', {H1: (1080, 1080)})

# ── regra vertical ──
for plataforma, posicao in (('instagram_positions', 'profile_reels'), ('messenger_positions', 'story'),
                            ('whatsapp_positions', 'status'), ('facebook_positions', 'facebook_reels_overlay'),
                            ('instagram_positions', 'reels_overlay')):
    s = bom()
    v = s['asset_feed_spec']['asset_customization_rules'][0]['customization_spec']
    v[plataforma] = [p for p in v[plataforma] if p != posicao]
    espera_recusa(f'vertical sem {plataforma}.{posicao}', s, f'não cobre {plataforma}: faltam {posicao}')
s = bom(); s['asset_feed_spec']['asset_customization_rules'][0]['customization_spec']['publisher_platforms'].remove('whatsapp')
espera_recusa('vertical sem whatsapp em publisher_platforms', s, 'publisher_platforms')
s = bom(); s['asset_feed_spec']['asset_customization_rules'] = s['asset_feed_spec']['asset_customization_rules'][1:]
espera_recusa('sem regra vertical', s, 'nenhuma regra usa a 9x16')

# ── fallback ──
s = bom(); s['asset_feed_spec']['asset_customization_rules'] = s['asset_feed_spec']['asset_customization_rules'][:1]
espera_recusa('sem fallback', s, 'falta a regra de fallback')
s = bom(3); s['asset_feed_spec']['asset_customization_rules'].pop()      # layout 3 sem o fallback final (só feeds explícitos)
espera_recusa('só feeds explícitos, sem fallback', s, 'falta a regra de fallback')
s = bom(); s['asset_feed_spec']['asset_customization_rules'][1]['customization_spec'] = {'publisher_platforms': ['facebook', 'instagram']}
espera_recusa('"fallback" só com publisher_platforms (o erro da v2)', s, 'falta a regra de fallback')
s = bom(); r = s['asset_feed_spec']['asset_customization_rules']; r[0]['priority'], r[1]['priority'] = 2, 1
espera_recusa('fallback antes da vertical', s, 'prioridade MAIOR')

# ── recursos automáticos ──
for chave in c.OPT_OUT + c.OPT_OUT_CORTE:
    s = bom(); s['degrees_of_freedom_spec']['creative_features_spec'][chave]['enroll_status'] = 'OPT_IN'
    espera_recusa(f'{chave} OPT_IN', s, f'{chave} não está OPT_OUT')
s = bom(); del s['degrees_of_freedom_spec']
espera_recusa('sem degrees_of_freedom_spec', s, 'degrees_of_freedom_spec ausente')
s = bom(); s['contextual_multi_ads'] = {'enroll_status': 'OPT_IN'}
espera_recusa('contextual_multi_ads', s, 'Advantage+ criativo')

# ── o único caminho de POST /adcreatives passa pela trava ──
fonte = open(c.__file__, encoding='utf-8').read()
posts = [l.strip() for l in fonte.splitlines() if "'POST'" in l and 'adcreatives' in l]
if len(posts) != 1:
    falhas.append(f'esperava 1 POST /adcreatives (dentro de criar_criativo), achei {len(posts)}: {posts}')

# ── as 8 imagens reais do Drive têm o tamanho exigido ──
if os.path.isdir(c.IMAGENS_DIR):
    for ad in c.ANUNCIOS:
        for fmt in ('1x1', '9x16'):
            d = c.dimensoes_png(c.arquivo_imagem(c.IMAGENS_DIR, ad['img'], fmt))
            if d != c.TAMANHO[fmt]:
                falhas.append(f'{ad["img"]} {fmt}: {d}')

if falhas:
    print('FALHOU:')
    for f in falhas:
        print('  -', f)
    sys.exit(1)
print('validar_criativo: todos os casos ok')
