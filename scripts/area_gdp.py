#!/usr/bin/env python
# NIOGEN | scripts/area_gdp.py | 26/11/2026 — Claude Code
# Resumo: monta a carga de config_area a partir da GDP da Nio (aba "Todos os Canais" do xlsx GDPx + o CSV da base de cobertura,
#   que traz o nome com acento). Sai um JSON com uma linha por município da carteira: uf, municipio_gdp (o texto da Nio, chave da
#   carga), cidade (nome de exibição, como o ViaCEP devolve), origem (gdp | conurbada), cidade_polo, cod_ibge, ddd, portfolio.
#   A carga é REPETÍVEL: public.area_carregar_gdp(<json>, <data da GDP>) atualiza os dados da Nio, cria a cidade nova DESLIGADA e
#   nunca mexe em ativo nem em cluster de cidade que já existe (a diferença de cluster aparece na conferência diária).
#
# Uso:  python scripts/area_gdp.py "<pasta da governança>/referencia-nio/20261029_B2B_GDPx 1.xlsx" \
#                                  "<pasta da governança>/portfolio/base_cobertura_b2b_nio_20261029.csv" > carga.json
#       python scripts/area_gdp.py <xlsx> <csv> --sql 2026-10-28 > carga.sql     # SQL pronto para a CLI (só admin/CLI roda)
# Os arquivos da Nio ficam na pasta do Drive (regra 4), nunca no repo.
import csv, json, sys, unicodedata

import openpyxl

PEQUENAS = {'de', 'da', 'do', 'das', 'dos', 'e', 'del'}
# Conurbadas que não estão no CSV: a GDP traz só o nome sem acento (MUNICIPIO_NOVA_FIBRA é a cidade-polo).
ACENTO = {
    'AGUAS LINDAS DE GOIAS': 'Águas Lindas de Goiás', 'CEILANDIA': 'Ceilândia', 'GUARA': 'Guará',
    'NUCLEO BANDEIRANTE': 'Núcleo Bandeirante', 'PARANOA': 'Paranoá', 'SANTO ANTONIO DO DESCOBERTO': 'Santo Antônio do Descoberto',
    'BRAZILANDIA': 'Brazlândia', 'SAO SEBASTIAO': 'São Sebastião', 'COLONIA FARIA': 'Colônia Faria', 'MARACANA': 'Maracanã',
    'ROCA GRANDE': 'Roça Grande', 'CAMINHO DE BUZIOS': 'Caminho de Búzios', 'ITAIPUACU': 'Itaipuaçu',
    'MARINA PORTO BUZIOS': 'Marina Porto Búzios', 'PEDRO DE ALCANTARA': 'Pedro de Alcântara',
    'JUSTINOPOLIS': 'Justinópolis', 'SERRA DEL REI': 'Serra del Rei',
}
CLUSTER = {'REGULAR MÓVEL': 'regular', 'BTU MÓVEL': 'btu'}


def norm(s):
    s = unicodedata.normalize('NFKD', str(s or '')).encode('ascii', 'ignore').decode().upper()
    return ' '.join(s.replace('-', ' ').replace("'", '').split())


def titulo(s):
    out = []
    for i, w in enumerate(str(s).lower().split()):
        if i and w in PEQUENAS:
            out.append(w)
        elif "'" in w:                      # d'oeste → d'Oeste
            a, b = w.split("'", 1)
            out.append(a + "'" + b[:1].upper() + b[1:])
        else:
            out.append('-'.join(p[:1].upper() + p[1:] for p in w.split('-')))
    return ' '.join(out)


def carga(xlsx, arq_csv):
    acc = {(r['UF'], norm(r['Município'])): r['Município'] for r in csv.DictReader(open(arq_csv, encoding='utf-8-sig'))}
    rows = list(openpyxl.load_workbook(xlsx, read_only=True, data_only=True)['Todos os Canais'].iter_rows(values_only=True))
    ix = {k: i for i, k in enumerate(rows[0])}
    out, vistos = [], set()
    for r in rows[1:]:
        if r[0] in (None, 'UF'):
            continue
        port = r[ix['PORTFOLIO_GDP_28_10']]
        if port not in CLUSTER:
            raise SystemExit(f'portfólio desconhecido: {r[0]} {r[ix["MUNICIPIO"]]} = {port!r}')
        uf, mun = r[0], norm(r[ix['MUNICIPIO']])
        if (uf, mun) in vistos:
            raise SystemExit(f'município repetido na GDP: {uf} {mun}')
        vistos.add((uf, mun))
        conurb = r[ix['ORIGEM']] != 'GDP'
        nome = acc.get((uf, mun)) or ACENTO.get(mun) or mun
        polo = r[ix['MUNICIPIO_NOVA_FIBRA']]
        out.append({'uf': uf, 'municipio_gdp': mun, 'cidade': titulo(nome), 'origem': 'conurbada' if conurb else 'gdp',
                    'cidade_polo': titulo(polo) if conurb and polo and norm(polo) != mun else None,
                    'cod_ibge': r[ix['COD_IBGE']], 'ddd': r[ix['DDD']], 'portfolio': port, 'cluster': CLUSTER[port]})
    return out


if __name__ == '__main__':
    if len(sys.argv) < 3:
        raise SystemExit(__doc__ or 'uso: area_gdp.py <xlsx> <csv> [--sql AAAA-MM-DD]')
    linhas = carga(sys.argv[1], sys.argv[2])
    js = json.dumps(linhas, ensure_ascii=False, separators=(',', ':'))
    sys.stdout.reconfigure(encoding='utf-8')
    if '--sql' in sys.argv:
        versao = sys.argv[sys.argv.index('--sql') + 1]
        print(f"select public.area_carregar_gdp($gdp${js}$gdp$::jsonb, '{versao}'::date);")
    else:
        print(js)
