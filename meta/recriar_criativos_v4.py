#!/usr/bin/env python3
"""
NIOGEN | meta/recriar_criativos_v4.py
Gerado em 06/11/2026 (America/Sao_Paulo) — Claude Code, prompt 25
Resumo: troca os 4 criativos / 8 anúncios v3 da campanha NIO_JF_C1_MSG_nov26 pelos v4 (9x16 em TODAS as posições verticais
        + fallback 1x1 + trava validar_criativo) e PROVA que a 9x16 é a imagem servida nos Stories. Roda por etapas:

  python meta/recriar_criativos_v4.py --offline                 plano + trava, sem token
  python meta/recriar_criativos_v4.py --page-id <ID>            passos 1, 2 e 4: cria criativos e anúncios v4 (PAUSED) e gera as prévias
  python meta/recriar_criativos_v4.py --previas                 refaz só as prévias (leitura) dos 8 anúncios v4
  python meta/recriar_criativos_v4.py --ativar-v4               ativa os 8 v4 (só se a prova das prévias estiver OK no JSON)
  python meta/recriar_criativos_v4.py --pausar-v3               pausa os 8 v3 (nunca apaga) — só depois dos v4 ACTIVE
  python meta/recriar_criativos_v4.py --insights                24 h depois: gasto/impressões por publisher_platform × platform_position

Não faz: apagar anúncio v3 · mexer em orçamento, público, conjuntos, texto ou CTA · ligar Advantage+ criativo ·
publicar o rascunho pendente do M1 · copiar imagem para o repo (as prévias ficam em meta/_previas/, fora do git).
Token: META_ACCESS_TOKEN_NIO (ver campanha1_jf.ler_token). Nunca é impresso.
"""
import argparse
import json
import os
import re
import struct
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import campanha1_jf as c  # noqa: E402

PREVIAS_DIR = os.path.join(c.REPO, 'meta', '_previas')

# (formato da prévia, o que a imagem servida tem de ser)
PREVIAS_VERTICAIS = ['INSTAGRAM_STORY', 'FACEBOOK_STORY_MOBILE', 'INSTAGRAM_REELS', 'FACEBOOK_REELS_MOBILE']
PREVIAS_FEED = ['MOBILE_FEED_STANDARD', 'INSTAGRAM_STANDARD', 'DESKTOP_FEED_STANDARD', 'RIGHT_COLUMN_STANDARD']
RAZAO = {'9x16': 1080 / 1920, '1x1': 1.0}


# ─────────────────────────────── prova ───────────────────────────────

def dim_imagem(b):
    """(l, a) de PNG/JPEG/WebP em memória; None se não reconhecer."""
    if b[:8] == b'\x89PNG\r\n\x1a\n':
        return struct.unpack('>II', b[16:24])
    if b[:2] == b'\xff\xd8':
        i = 2
        while i + 9 < len(b):
            if b[i] != 0xFF:
                i += 1
                continue
            m = b[i + 1]
            if m in (0xC0, 0xC1, 0xC2):
                a, l = struct.unpack('>HH', b[i + 5:i + 9])
                return l, a
            i += 2 + struct.unpack('>H', b[i + 2:i + 4])[0]
    if b[:4] == b'RIFF' and b[8:12] == b'WEBP':
        if b[12:16] == b'VP8X':
            return 1 + int.from_bytes(b[24:27], 'little'), 1 + int.from_bytes(b[27:30], 'little')
        if b[12:16] == b'VP8 ':
            return struct.unpack('<HH', b[26:30])[0] & 0x3FFF, struct.unpack('<HH', b[26:30])[1] & 0x3FFF
    return None


def baixar(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (NIOGEN previa)'})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def provar_previa(ad_id, rotulo, formato, esperado, hashes_do_anuncio):
    """GET /{ad}/previews → salva o HTML em meta/_previas/ e confere a proporção da imagem servida.
    Devolve (ok, texto). ok=None quando não deu para determinar (nunca vira 'ok' por omissão)."""
    os.makedirs(PREVIAS_DIR, exist_ok=True)
    try:
        r = c.api('GET', f'{ad_id}/previews', {'ad_format': formato})
    except c.ErroMeta as e:
        return False, f'prévia recusada pela Meta: {e}'
    corpo = (r.get('data') or [{}])[0].get('body', '')
    base = os.path.join(PREVIAS_DIR, f'{rotulo}_{formato}')
    with open(base + '_iframe.html', 'w', encoding='utf-8') as f:
        f.write(corpo)
    m = re.search(r'src="([^"]+)"', corpo)
    if not m:
        return False, 'a Meta não devolveu iframe de prévia'
    pagina = baixar(m.group(1).replace('&amp;', '&')).decode('utf-8', 'replace')
    with open(base + '.html', 'w', encoding='utf-8') as f:
        f.write(pagina)
    if re.search(r'0 regras|no rules|nenhuma regra', pagina, re.I):
        return False, 'a prévia diz que nenhuma regra de posicionamento casou'
    # hash da imagem esperada aparece no HTML? (nem sempre: a Meta serve por URL com assinatura)
    h_esp = hashes_do_anuncio[esperado]
    h_outro = hashes_do_anuncio['1x1' if esperado == '9x16' else '9x16']
    achou_hash = h_esp in pagina
    achou_errado = h_outro in pagina
    # proporção da imagem principal servida (a maior entre as <img>/background da prévia)
    urls = re.findall(r'(?:src|href)="(https:[^"]+?\.(?:jpg|jpeg|png|webp)[^"]*)"', pagina) + \
           re.findall(r'url\((?:&quot;|["\'])?(https:[^)"\'&]+?(?:\.jpg|\.jpeg|\.png|\.webp)[^)"\']*)', pagina)
    melhor = None
    for u in urls[:12]:
        try:
            d = dim_imagem(baixar(u.replace('&amp;', '&')))
        except Exception:
            continue
        if d and d[0] >= 300 and (melhor is None or d[0] * d[1] > melhor[0] * melhor[1]):
            melhor = d
    if achou_errado and not achou_hash:
        return False, f'o HTML da prévia cita o hash da imagem ERRADA ({h_outro})'
    if melhor:
        razao = melhor[0] / melhor[1]
        ok = abs(razao - RAZAO[esperado]) < 0.03
        return ok, f'imagem servida {melhor[0]}×{melhor[1]} (esperado {esperado})' + (f' · hash {h_esp} citado' if achou_hash else '')
    if achou_hash:
        return True, f'hash da {esperado} ({h_esp}) citado no HTML (tamanho não medido)'
    return None, 'NÃO CONFIRMADO: nem hash nem imagem identificáveis no HTML — conferir o arquivo salvo à mão'


def fazer_previas(saida, hashes):
    """Prévias dos 8 anúncios v4. Grava saida['previas'] = {anuncio: {formato: {ok, texto}}}."""
    resultados, tudo_ok = {}, True
    for cj, ads in saida['anuncios'].items():
        for nome, ad_id in ads.items():
            img = next(a['img'] for a in c.ANUNCIOS if a['name'] == nome)
            h = {'1x1': hashes[f'{img}_1x1'], '9x16': hashes[f'{img}_9x16']}
            print(f'\n{cj}/{nome}{c.SUFIXO} ({ad_id})')
            res = resultados.setdefault(ad_id, {})
            for formato, esperado in [(f, '9x16') for f in PREVIAS_VERTICAIS] + [(f, '1x1') for f in PREVIAS_FEED]:
                ok, txt = provar_previa(ad_id, f'{cj}_{nome}', formato, esperado, h)
                marca = {True: 'OK ', False: 'ERRO', None: '?  '}[ok]
                print(f'  [{marca}] {formato:<24} {txt}')
                res[formato] = {'ok': ok, 'texto': txt}
                if ok is not True:
                    tudo_ok = False
                time.sleep(1.5)       # a conta já bateu em limite (code 17) depois de muitas prévias
    saida['previas'] = {'em': c.dt.datetime.now().astimezone().isoformat(timespec='seconds'), 'tudo_ok': tudo_ok,
                        'por_anuncio': resultados}
    return tudo_ok


# ─────────────────────────────── ações ───────────────────────────────

def comparar_com_v3(saida):
    """Passo 1 do prompt: v4 mantém TUDO do v3 menos as regras. Lê os dois criativos e mostra as diferenças inesperadas."""
    legado = saida.get('legado', {}).get('_v3', {}).get('criativos', {})
    for nome, novo in saida.get('criativos', {}).items():
        antigo = legado.get(nome, {}).get('id')
        if not antigo:
            continue
        campos = 'object_story_spec,destination_spec,asset_feed_spec,degrees_of_freedom_spec,instagram_user_id'
        a = c.api('GET', antigo, {'fields': campos})
        n = c.api('GET', novo['id'], {'fields': campos})
        difs = []

        def ignora(caminho):
            return 'asset_customization_rules' in caminho or caminho.startswith('degrees_of_freedom_spec')

        def varre(x, y, caminho=''):
            if ignora(caminho):
                return
            if isinstance(x, dict) and isinstance(y, dict):
                for k in sorted(set(x) | set(y)):
                    varre(x.get(k), y.get(k), f'{caminho}.{k}'.lstrip('.'))
            elif x != y:
                # hashes das imagens e rótulos não mudam; qualquer outra diferença é reportada
                difs.append(f'{caminho}: v3={json.dumps(x, ensure_ascii=False)[:90]} · v4={json.dumps(y, ensure_ascii=False)[:90]}')
        varre(a, n)
        print(f'  {nome}: {"v4 = v3 em tudo menos as regras de posição" if not difs else "DIFERENÇAS além das regras:"}')
        for d in difs:
            print('     -', d)
        # os campos que o prompt manda preservar, explicitamente
        for caminho in ('destination_spec', 'object_story_spec.instagram_user_id'):
            if (caminho.split('.')[0] in a) and a.get(caminho.split('.')[0]) != n.get(caminho.split('.')[0]):
                print(f'     ! {caminho} difere do v3 — conferir antes de ativar')


def conferir_regras_gravadas(saida):
    """A trava valida o que ENVIAMOS; aqui se lê o que a Meta GUARDOU (ela descartou whatsapp_positions em 06/11).
    Plataforma em publisher_platforms sem lista *_positions = vale para todas as posições dela (cobre)."""
    ok = True
    for nome, cr in saida.get('criativos', {}).items():
        r = c.api('GET', cr['id'], {'fields': 'asset_feed_spec{asset_customization_rules},degrees_of_freedom_spec'})
        regras = r['asset_feed_spec']['asset_customization_rules']
        vert = next((x for x in regras if x['image_label']['name'] == 'img_9x16'), None)
        fb = [x for x in regras if x['image_label']['name'] == 'img_1x1' and
              not any(k.endswith('_positions') or k == 'publisher_platforms' for k in x.get('customization_spec', {}))]
        spec = (vert or {}).get('customization_spec', {})
        problemas = []
        for plat in c.REGRA_VERTICAL['publisher_platforms']:
            if plat not in spec.get('publisher_platforms', []):
                problemas.append(f'{plat} fora de publisher_platforms')
            elif f'{plat}_positions' in spec:
                faltam = set(c.REGRA_VERTICAL.get(f'{plat}_positions', [])) - set(spec[f'{plat}_positions'])
                if faltam:
                    problemas.append(f'{plat}: faltam {sorted(faltam)}')
        if not fb:
            problemas.append('fallback 1x1 não foi guardado')
        feats = r['degrees_of_freedom_spec']['creative_features_spec']
        ligados = [k for k, v in feats.items() if v.get('enroll_status') != 'OPT_OUT']
        if ligados:
            problemas.append(f'recursos fora de OPT_OUT: {ligados}')
        sem_lista = [p for p in c.REGRA_VERTICAL['publisher_platforms'] if f'{p}_positions' not in spec]
        print(f'  {nome}: ' + ('guardado como enviado' + (f' (sem lista de posições, vale para todas: {sem_lista})' if sem_lista else '')
                               if not problemas else 'PROBLEMAS — ' + '; '.join(problemas)))
        ok = ok and not problemas
    return ok


def ids_v(saida, versao):
    if versao == 'v4':
        return {i: f'{cj}/{n}{c.SUFIXO}' for cj, d in saida.get('anuncios', {}).items() for n, i in d.items()}
    antigo = saida.get('legado', {}).get('_v3', {}).get('anuncios', {})
    return {i: f'{cj}/{n}' for cj, d in antigo.items() for n, i in d.items()}


def mudar_status(ids, status):
    for i, nome in ids.items():
        c.api('POST', i, {'status': status})
        r = c.api('GET', i, {'fields': 'name,status,effective_status'})
        print(f'  {nome:<40} {i} · {r["status"]} / {r.get("effective_status")}')


def insights(saida):
    """Gasto e impressões por posição, dos 8 v4: confere que a 9x16 só foi para posição vertical e o 1x1 para o resto."""
    ids = list(ids_v(saida, 'v4'))
    if not ids:
        raise SystemExit('Sem anúncios v4 no JSON.')
    print('\nInsights v4 por publisher_platform × platform_position (últimos 3 dias)')
    linhas = {}
    for i in ids:
        dados = c.api('GET', f'{i}/insights', {'fields': 'ad_name,impressions,spend', 'breakdowns': 'publisher_platform,platform_position',
                                               'date_preset': 'last_3d', 'limit': 200}).get('data', [])
        for r in dados:
            k = (r['publisher_platform'], r['platform_position'])
            a = linhas.setdefault(k, [0, 0.0])
            a[0] += int(r.get('impressions', 0))
            a[1] += float(r.get('spend', 0))
    verticais = set()
    for plat, chave in (('facebook', 'facebook_positions'), ('instagram', 'instagram_positions'),
                        ('messenger', 'messenger_positions'), ('whatsapp', 'whatsapp_positions')):
        verticais |= {(plat, p) for p in c.REGRA_VERTICAL[chave]}
    print(f'  {"plataforma":<12} {"posição":<24} {"impr.":>7} {"gasto R$":>9}  arte esperada')
    for (plat, pos), (imp, gasto) in sorted(linhas.items(), key=lambda x: -x[1][1]):
        print(f'  {plat:<12} {pos:<24} {imp:>7} {gasto:>9.2f}  ' + ('9x16 (vertical)' if (plat, pos) in verticais else '1x1 (fallback)'))
    print('\nA posição vertical da lista mostra 9x16; qualquer outra posição vertical NOVA da Meta que apareça acima como 1x1 '
          'é candidata a entrar na REGRA_VERTICAL. O print do Stories real (Ricardo) continua sendo a prova final.')


# ─────────────────────────────── principal ───────────────────────────────

def main():
    ap = argparse.ArgumentParser(description='Criativos v4 (prompt 25)')
    ap.add_argument('--offline', action='store_true')
    ap.add_argument('--page-id')
    ap.add_argument('--previas', action='store_true')
    ap.add_argument('--ativar-v4', action='store_true')
    ap.add_argument('--pausar-v3', action='store_true')
    ap.add_argument('--insights', action='store_true')
    ap.add_argument('--layout', type=int, choices=(2, 3), default=2)
    ap.add_argument('--imagens', default=c.IMAGENS_DIR)
    a = ap.parse_args()

    c.checar_textos()
    if a.offline:
        c.plano_offline(a.imagens, a.layout)
        return
    c.TOKEN = c.ler_token()
    if not c.TOKEN:
        raise SystemExit('META_ACCESS_TOKEN_NIO ausente. Nada feito.')
    versao, conta = c.escolher_versao()
    if conta.get('currency') != 'BRL':
        raise SystemExit(f'Conta {c.CONTA} não está em BRL. Parado.')
    print(f'Graph {versao} · conta {c.CONTA} ok.')
    saida = c.carregar_saida()

    if a.page_id:
        # passo 5 do prompt: rascunho pendente do M1. A API não expõe edição não publicada → só avisa.
        print('Aviso (passo 5): o rascunho com textos sugeridos pela IA da Meta no anúncio 120257703612890211 foi descartado '
              'pelo Cowork em 06/11 16h52; a API não lista rascunhos — conferir no Gerenciador antes de ativar.')
        args = argparse.Namespace(dry_run=False, page_id=a.page_id, imagens=a.imagens, layout=a.layout)
        c.criar(args, conta, versao)                   # criativos pela trava (criar_criativo) + 8 anúncios v4 PAUSED
        saida = c.carregar_saida()
        print('\nComparação v4 × v3 (tudo menos as regras de posição deve ser igual):')
        comparar_com_v3(saida)
        a.previas = True

    if a.previas:
        saida = c.carregar_saida()
        ok = fazer_previas(saida, saida['imagens'])
        c.gravar_saida(saida)
        print('\n' + ('PROVA OK: 9x16 nos Stories/Reels e 1x1 nos feeds, nos 8 anúncios.' if ok else
                      'PROVA INCOMPLETA: há prévias com ERRO ou "?" — NÃO ativar até conferir os arquivos em meta/_previas/.'))
        if not ok:
            sys.exit(2)

    if a.ativar_v4:
        if not saida.get('previas', {}).get('tudo_ok'):
            raise SystemExit('Recuso ativar: a prova das prévias não está OK no JSON (rode --previas e confira).')
        print('\nAtivando os 8 anúncios v4:')
        mudar_status(ids_v(saida, 'v4'), 'ACTIVE')
        saida['v4_ativado_em'] = c.dt.datetime.now().astimezone().isoformat(timespec='seconds')
        c.gravar_saida(saida)
        print('Próximo: conferir no Gerenciador/Stories e só então --pausar-v3. Em 24 h: --insights + print do Ricardo.')

    if a.pausar_v3:
        if not saida.get('v4_ativado_em'):
            raise SystemExit('Recuso pausar o v3: os v4 ainda não foram ativados por este script.')
        v4 = {i: n for i, n in ids_v(saida, 'v4').items()}
        for i, n in v4.items():
            st = c.api('GET', i, {'fields': 'effective_status'}).get('effective_status')
            if st != 'ACTIVE':
                raise SystemExit(f'Recuso pausar o v3: {n} ({i}) está {st}, não ACTIVE.')
        print('\nPausando os 8 anúncios v3 (histórico preservado, nada é apagado):')
        mudar_status(ids_v(saida, 'v3'), 'PAUSED')
        saida['v3_pausado_em'] = c.dt.datetime.now().astimezone().isoformat(timespec='seconds')
        c.gravar_saida(saida)

    if a.insights:
        insights(saida)


if __name__ == '__main__':
    main()
