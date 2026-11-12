#!/usr/bin/env python3
"""
NIOGEN | meta/publicar_credibilidade.py
Gerado em 06/11/2026 (America/Sao_Paulo) — Claude Code, prompt 21
Resumo: publica pela Graph API os 9 posts de credibilidade de JF no Instagram @mari.nio.internet e na página
        "Mari Nio Internet", e os 4 stories no Instagram (stories da página só com --fb-stories).
        Idempotente: o que já tem id em meta/credibilidade_ids.json (ou legenda idêntica já publicada) é pulado.

Lotes: --lote feed_c2_nov26 usa meta/feed_c2_nov26.json, meta/feed_c2_nov26_ids.json e docs/midia/feed_c2_nov26/
       (12/11/2026: artes da campanha 2 reaproveitadas no feed). Sem --lote: o lote de credibilidade de 06/11.

Modos:
  python meta/publicar_credibilidade.py                  = --dry-run: lista o que faria (arquivo, URL, legenda, destino)
  python meta/publicar_credibilidade.py --conferir       só leitura: posts do Instagram e da página × JSON
  python meta/publicar_credibilidade.py --publicar       publica o que falta (só com o OK do Ricardo na sessão)
        [--fb-stories]  também os stories da página    [--so ig_feed,ig_stories,fb_feed,fb_stories]

Legendas: meta/credibilidade_nov26.json (texto literal do textos_credibilidade_061126_0915.md — não reescrever).
Imagens: docs/midia/credibilidade_nov26/*.jpg no GitHub Pages (a API do Instagram só aceita JPEG por URL pública).
Token: META_ACCESS_TOKEN_NIO (mesma leitura do campanha1_jf.py). O token e o da página nunca são impressos nem gravados.
Erro em um item: para, mostra o erro e não tenta contornar.
"""
import argparse
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from campanha1_jf import ErroMeta, ler_token, _enc, VERSOES   # mesma leitura de token e mesmas versões da Graph

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENTRADA = os.path.join(REPO, 'meta', 'credibilidade_nov26.json')
SAIDA = os.path.join(REPO, 'meta', 'credibilidade_ids.json')
MIDIA = os.path.join(REPO, 'docs', 'midia', 'credibilidade_nov26')


def usar_lote(lote):
    """--lote X: meta/X.json · meta/X_ids.json · docs/midia/X/ (o padrão é o lote de credibilidade de 06/11)."""
    global ENTRADA, SAIDA, MIDIA
    ENTRADA = os.path.join(REPO, 'meta', f'{lote}.json')
    SAIDA = os.path.join(REPO, 'meta', f'{lote}_ids.json')
    MIDIA = os.path.join(REPO, 'docs', 'midia', lote)

PAGINA = '1421228191072269'            # Mari Nio Internet (antes "Mari Nio Internet", renomeada em 06/11)
IG_ID = '17841411489935097'            # @mari.nio.internet
ESCOPOS = ['instagram_basic', 'instagram_content_publish', 'pages_manage_posts',
           'pages_read_engagement', 'pages_show_list']
DESTINOS = ['ig_feed', 'ig_stories', 'fb_feed', 'fb_stories']

# Regra de conteúdo (CLAUDE.md / prompt 21). "grátis" só na frase do rodapé já aprovada.
PROIBIDO = ['sem fidelidade', 'desconto', 'dharma', 'vero', 'cnpj', 'instala amanhã', 'instalação em ']
GRATIS_OK = 'Instalação grátis com 12 meses de permanência'

GRAPH = None
TOKEN = None
TOKEN_PAGINA = None


# ─────────────────────────────── utilidades ───────────────────────────────

def agora():
    return dt.datetime.now().astimezone().isoformat(timespec='seconds')


def api(method, path, params=None, token=None):
    url = f'{GRAPH}/{path}'
    headers = {'Authorization': f'Bearer {token or TOKEN}'}
    data = None
    if method == 'GET':
        if params:
            url += '?' + urllib.parse.urlencode(_enc(params))
    else:
        data = urllib.parse.urlencode(_enc(params)).encode()
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        raise ErroMeta(e.code, e.read().decode('utf-8', 'replace')) from None


def listar(path, fields, token=None, limite=100):
    itens, params = [], {'fields': fields, 'limit': 50}
    r = api('GET', path, params, token)
    while True:
        itens += r.get('data', [])
        nxt = r.get('paging', {}).get('cursors', {}).get('after')
        if not nxt or not r.get('paging', {}).get('next') or len(itens) >= limite:
            return itens
        r = api('GET', path, {**params, 'after': nxt}, token)


def escolher_versao():
    global GRAPH
    versoes = [os.environ['META_GRAPH_VERSION']] if os.environ.get('META_GRAPH_VERSION') else VERSOES
    ultimo = None
    for v in versoes:
        GRAPH = f'https://graph.facebook.com/{v}'
        try:
            api('GET', 'me', {'fields': 'id'})
            return v
        except ErroMeta as e:
            ultimo = e
            if e.code == 2635 or 'version' in e.msg.lower():
                continue
            raise SystemExit(f'Falha ao ler o token: {e}')
    raise SystemExit(f'Nenhuma versão da Graph API aceitou: {ultimo}')


def carregar():
    d = json.load(open(ENTRADA, encoding='utf-8'))
    ids = json.load(open(SAIDA, encoding='utf-8')) if os.path.exists(SAIDA) else {}
    for k in DESTINOS:
        ids.setdefault(k, {})
    return d, ids


def gravar(ids):
    ids['atualizado_em'] = agora()
    with open(SAIDA, 'w', encoding='utf-8', newline='\n') as f:
        f.write(json.dumps(ids, ensure_ascii=False, indent=2) + '\n')


def url_de(d, arquivo):
    return d['base_url'] + arquivo


def checar_conteudo(d):
    erros = []
    for p in d['posts']:
        t = p['legenda'].lower()
        for w in PROIBIDO:
            if w in t:
                erros.append(f"{p['arquivo']}: contém \"{w}\"")
        if 'grátis' in t.replace(GRATIS_OK.lower(), ''):
            erros.append(f"{p['arquivo']}: \"grátis\" fora da frase do rodapé")
        if not os.path.exists(os.path.join(MIDIA, p['arquivo'])):
            erros.append(f"{p['arquivo']}: não está em {MIDIA}")
    for s in d['stories']:
        if not os.path.exists(os.path.join(MIDIA, s['arquivo'])):
            erros.append(f"{s['arquivo']}: não está em {MIDIA}")
    if erros:
        raise SystemExit('Conteúdo recusado:\n  ' + '\n  '.join(erros))


def checar_urls(d):
    """A prova de que o Pages publicou: cada URL responde 200 com content-type image/jpeg."""
    ruins = []
    for a in [p['arquivo'] for p in d['posts']] + [s['arquivo'] for s in d['stories']]:
        req = urllib.request.Request(url_de(d, a), method='HEAD')
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                ct = r.headers.get('content-type', '')
                if r.status != 200 or not ct.startswith('image/jpeg'):
                    ruins.append(f'{a}: {r.status} {ct}')
        except urllib.error.HTTPError as e:
            ruins.append(f'{a}: HTTP {e.code}')
    return ruins


def passo0():
    """Escopos do token, token da página (só em memória) e o Instagram ligado à página."""
    global TOKEN_PAGINA
    perms = {p['permission'] for p in api('GET', 'me/permissions')['data'] if p.get('status') == 'granted'}
    faltam = [e for e in ESCOPOS if e not in perms]
    pg = api('GET', PAGINA, {'fields': 'name,access_token,instagram_business_account'})
    ig = (pg.get('instagram_business_account') or {}).get('id')
    if ig != IG_ID:
        raise SystemExit(f'PARE: a página {PAGINA} devolveu o Instagram {ig}, esperado {IG_ID}.')
    TOKEN_PAGINA = pg.get('access_token')
    return pg.get('name'), faltam


# ─────────────────────────────── plano ───────────────────────────────

def plano(d, ids, destinos):
    """Lista ordenada de (destino, item). Feed na ordem 09 → 01 (o 01 fica no topo da grade)."""
    feed = sorted(d['posts'], key=lambda p: -p['ordem'])
    stories = sorted(d['stories'], key=lambda s: s['ordem'])
    out = []
    for dest in destinos:
        for it in (feed if dest.endswith('feed') else stories):
            out.append((dest, it))
    return out


def ja_publicado(ids, dest, arquivo):
    r = ids[dest].get(arquivo, {})
    return r.get('media_id') or r.get('post_id') or r.get('story_id')


def mostrar(d, ids, itens):
    print(f"\n{'destino':<11} {'estado':<10} arquivo · URL · legenda (80)")
    for dest, it in itens:
        est = 'publicado' if ja_publicado(ids, dest, it['arquivo']) else 'falta'
        leg = it.get('legenda', '(story, sem legenda)').replace('\n', ' ⏎ ')[:80]
        print(f"{dest:<11} {est:<10} {it['arquivo']}\n{'':<22} {url_de(d, it['arquivo'])}\n{'':<22} {leg}")


# ─────────────────────────────── publicação ───────────────────────────────

def ig_existentes():
    return listar(f'{IG_ID}/media', 'id,caption,media_type,permalink,timestamp')


def fb_existentes():
    return listar(f'{PAGINA}/posts', 'id,message,permalink_url,created_time', TOKEN_PAGINA)


def esperar_container(cid, rotulo):
    for _ in range(60):                     # até ~5 min
        st = api('GET', cid, {'fields': 'status_code,status'})
        sc = st.get('status_code')
        if sc == 'FINISHED':
            return
        if sc in ('ERROR', 'EXPIRED'):
            raise SystemExit(f'{rotulo}: container {cid} {sc} — {st.get("status")}')
        time.sleep(5)
    raise SystemExit(f'{rotulo}: container {cid} não ficou FINISHED em 5 min')


def publicar_ig(d, ids, dest, it):
    a = it['arquivo']
    reg = ids[dest].setdefault(a, {})
    params = {'image_url': url_de(d, a)}
    if dest == 'ig_feed':
        params['caption'] = it['legenda']
    else:
        params['media_type'] = 'STORIES'
    if not reg.get('container_id'):
        reg['container_id'] = api('POST', f'{IG_ID}/media', params)['id']
        reg['container_em'] = agora()
        gravar(ids)
    esperar_container(reg['container_id'], a)
    reg['media_id'] = api('POST', f'{IG_ID}/media_publish', {'creation_id': reg['container_id']})['id']
    reg['publicado_em'] = agora()
    try:
        reg['permalink'] = api('GET', reg['media_id'], {'fields': 'permalink'}).get('permalink')
    except ErroMeta:
        pass
    gravar(ids)
    print(f"    ✓ {dest} {a} → media {reg['media_id']} {reg.get('permalink', '')}")


def publicar_fb_feed(d, ids, it):
    a = it['arquivo']
    reg = ids['fb_feed'].setdefault(a, {})
    r = api('POST', f'{PAGINA}/photos', {'url': url_de(d, a), 'message': it['legenda'], 'published': 'true'},
            TOKEN_PAGINA)
    reg.update({'photo_id': r.get('id'), 'post_id': r.get('post_id'), 'publicado_em': agora()})
    try:
        reg['permalink'] = api('GET', reg['post_id'], {'fields': 'permalink_url'}, TOKEN_PAGINA).get('permalink_url')
    except ErroMeta:
        pass
    gravar(ids)
    print(f"    ✓ fb_feed {a} → post {reg['post_id']} {reg.get('permalink', '')}")


def publicar_fb_story(d, ids, it):
    a = it['arquivo']
    reg = ids['fb_stories'].setdefault(a, {})
    if not reg.get('photo_id'):
        reg['photo_id'] = api('POST', f'{PAGINA}/photos', {'url': url_de(d, a), 'published': 'false'},
                              TOKEN_PAGINA)['id']
        gravar(ids)
    r = api('POST', f'{PAGINA}/photo_stories', {'photo_id': reg['photo_id']}, TOKEN_PAGINA)
    reg.update({'story_id': r.get('post_id') or r.get('id'), 'publicado_em': agora()})
    gravar(ids)
    print(f"    ✓ fb_stories {a} → {reg['story_id']}")


def adotar_existentes(d, ids, destinos):
    """Se a legenda idêntica já está publicada (ids perdidos), grava o id e não publica de novo."""
    if 'ig_feed' in destinos:
        por_leg = {m.get('caption'): m for m in ig_existentes() if m.get('caption')}
        for p in d['posts']:
            m = por_leg.get(p['legenda'])
            if m and not ja_publicado(ids, 'ig_feed', p['arquivo']):
                ids['ig_feed'][p['arquivo']] = {'media_id': m['id'], 'permalink': m.get('permalink'),
                                                'publicado_em': m.get('timestamp'), 'adotado': True}
    if 'fb_feed' in destinos:
        por_msg = {m.get('message'): m for m in fb_existentes() if m.get('message')}
        for p in d['posts']:
            m = por_msg.get(p['legenda'])
            if m and not ja_publicado(ids, 'fb_feed', p['arquivo']):
                ids['fb_feed'][p['arquivo']] = {'post_id': m['id'], 'permalink': m.get('permalink_url'),
                                                'publicado_em': m.get('created_time'), 'adotado': True}
    gravar(ids)


def publicar(d, ids, itens, intervalo):
    adotar_existentes(d, ids, {dest for dest, _ in itens})
    anterior = None
    for dest, it in itens:
        if ja_publicado(ids, dest, it['arquivo']):
            print(f"  · {dest} {it['arquivo']}: já publicado, pulo")
            continue
        if anterior == dest and dest == 'ig_feed':
            print(f'  … {intervalo} s entre posts do feed')
            time.sleep(intervalo)
        print(f"  → {dest} {it['arquivo']}")
        try:
            if dest.startswith('ig_'):
                publicar_ig(d, ids, dest, it)
            elif dest == 'fb_feed':
                publicar_fb_feed(d, ids, it)
            else:
                publicar_fb_story(d, ids, it)
        except ErroMeta as e:
            gravar(ids)
            if dest == 'fb_stories' and e.code in (3, 10, 200):
                ids['fb_stories']['_recusado'] = f'{agora()} · {e}'
                gravar(ids)
                print(f'    ✗ stories da página recusados ({e}) — registrado; sigo sem eles')
                return
            raise SystemExit(f'PARE em {dest} {it["arquivo"]}: {e}')
        anterior = dest


def conferir(d, ids):
    ok = True
    ig = {m['id']: m for m in ig_existentes()}
    fb = {m['id']: m for m in fb_existentes()}
    print('\nConferência (feed):')
    for p in sorted(d['posts'], key=lambda x: x['ordem']):
        a = p['arquivo']
        mi = ids['ig_feed'].get(a, {}).get('media_id')
        po = ids['fb_feed'].get(a, {}).get('post_id')
        m_ig, m_fb = ig.get(mi), fb.get(po)
        c_ig = bool(m_ig) and m_ig.get('caption') == p['legenda']
        c_fb = bool(m_fb) and m_fb.get('message') == p['legenda']
        if m_ig and m_ig.get('permalink'):
            ids['ig_feed'][a]['permalink'] = m_ig['permalink']
        if m_fb and m_fb.get('permalink_url'):
            ids['fb_feed'][a]['permalink'] = m_fb['permalink_url']
        ok &= c_ig and c_fb
        print(f"  {p['ordem']:02d} IG {'✓' if c_ig else '✗'}  página {'✓' if c_fb else '✗'}  {a}")
    print(f'  Instagram: {len(ig)} mídias na conta · página: {len(fb)} posts')
    gravar(ids)
    return ok


# ─────────────────────────────── main ───────────────────────────────

def main():
    global TOKEN
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--dry-run', action='store_true', help='padrão: só mostra o plano')
    ap.add_argument('--publicar', action='store_true', help='publica o que falta (OK do Ricardo na sessão)')
    ap.add_argument('--conferir', action='store_true', help='só leitura: feed do IG e da página × JSON')
    ap.add_argument('--fb-stories', action='store_true', help='também os stories da página')
    ap.add_argument('--so', help='destinos separados por vírgula: ' + ','.join(DESTINOS))
    ap.add_argument('--lote', help='nome do lote (meta/<lote>.json); padrão: credibilidade_nov26')
    ap.add_argument('--intervalo', type=int, default=60, help='segundos entre posts do feed do IG (padrão 60)')
    a = ap.parse_args()
    if a.lote:
        usar_lote(a.lote)

    d, ids = carregar()
    checar_conteudo(d)
    destinos = ['ig_feed', 'ig_stories', 'fb_feed'] + (['fb_stories'] if a.fb_stories else [])
    if a.so:
        destinos = [x for x in a.so.split(',') if x in DESTINOS]
    itens = plano(d, ids, destinos)

    ruins = checar_urls(d)
    n = len(d['posts']) + len(d['stories'])
    print('URLs públicas: ' + (f'{n}/{n} 200 image/jpeg' if not ruins else 'PROBLEMA\n  ' + '\n  '.join(ruins)))

    TOKEN = ler_token()
    if not TOKEN:
        mostrar(d, ids, itens)
        raise SystemExit('\n(sem META_ACCESS_TOKEN_NIO: só o plano)')
    versao = escolher_versao()
    nome, faltam = passo0()
    print(f'Graph {versao} · página "{nome}" → Instagram {IG_ID} ✓ · escopos que faltam: {faltam or "nenhum"}')

    if a.conferir:
        sys.exit(0 if conferir(d, ids) else 1)
    mostrar(d, ids, itens)
    if not a.publicar:
        print('\n--dry-run: nada publicado. Para publicar: --publicar (só com o OK do Ricardo).')
        return
    if faltam:
        raise SystemExit(f'PARE: o token não tem {faltam}. Regerar no BM (Nio_API → app NIOGEN).')
    if ruins:
        raise SystemExit('PARE: há URL que não responde 200 image/jpeg.')
    ids['versao_graph'] = versao
    publicar(d, ids, itens, a.intervalo)
    if any(x in destinos for x in ('ig_feed', 'fb_feed')):
        conferir(d, ids)


if __name__ == '__main__':
    main()
