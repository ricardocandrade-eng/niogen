# NIOGEN | dfv/cobertura_cidades.py | 12/11/2026 — Claude Code (prompt "Cobertura por cidade e bairro no retrato do Agente de Tráfego")
# Resumo: lê o DFV da Nio (só leitura, mesmo login e mesmo pedido da grade do painel, agrupado e contado) e grava no Supabase Nio
#   cidades     → dfv_cobertura_cidade + dfv_cobertura_bairro: as 35 cidades da C2 (meta/campanha2_mg.py), fachadas viáveis,
#                 domicílios, bairros e lat/long média de cada bairro. 1 pedido agregado por cidade (~0,5–3 s).
#   distancias  → conversa_cobertura_distancia: para cada conversa sem cobertura desde 05/11 sem medida, ponto do CEP (só o CEP,
#                 AwesomeAPI → BrasilAPI) e distância até a fachada viável mais próxima (fachadas dos bairros a até 5 km).
# Saída na tela: só contagens. Nunca imprime senha, CEP, rua ou nome.
#
# Uso (PC do Ricardo, Chrome instalado; o login do DFV sai de config_links.acesso pelo CLI, sem passar pela tela):
#   python dfv/cobertura_cidades.py cidades [--so "JUIZ DE FORA"]
#   python dfv/cobertura_cidades.py distancias [--refazer]
#   python dfv/cobertura_cidades.py tudo
# Por que agregado e não o mapa: o mapa do painel vem amostrado (OverlappingPointsSample) — não serve para contar.

import ast
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.request

AQUI = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.dirname(AQUI)
CLI = 'npx.cmd supabase@3.0.0' if os.name == 'nt' else 'npx supabase@3.0.0'
DESDE = '2026-11-05'
RAIO_BAIRROS_M = 5000


def sql(q, escrever=False):
    fd, p = tempfile.mkstemp(suffix='.sql')
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(q)
    try:
        flag = '--yes' if escrever else '--read-only'
        out = subprocess.run(f'{CLI} db query --remote {flag} -f "{p}"', cwd=RAIZ, shell=True, capture_output=True,
                             text=True, encoding='utf-8').stdout
    finally:
        os.remove(p)
    i = out.find('{')
    if i < 0:
        raise SystemExit('CLI do Supabase sem resposta')
    d = json.loads(out[i:])
    if d.get('_tag') == 'Error' or 'error' in d:
        raise SystemExit(f'Supabase: {str(d.get("error"))[:300]}')
    return d.get('rows') or []


def lit(v):
    if v is None:
        return 'null'
    if isinstance(v, (int, float)):
        return repr(v)
    return "'" + str(v).replace("'", "''") + "'"


def sem_acento(s):
    return ''.join(c for c in unicodedata.normalize('NFD', s) if unicodedata.category(c) != 'Mn')


def cidades_c2():
    """Lê REGULAR e BTU do meta/campanha2_mg.py sem importar (o import faria chamadas à Meta)."""
    src = open(os.path.join(RAIZ, 'meta', 'campanha2_mg.py'), encoding='utf-8').read()
    lista = {}
    for nome in ('REGULAR', 'BTU'):
        m = re.search(rf'^{nome}\s*=\s*(\[.*?\])', src, re.S | re.M)
        lista[nome] = ast.literal_eval(m.group(1))
    out = [('Juiz de Fora', 'CJ_JF')]
    out += [(c, 'CJ_REGULAR') for c in lista['REGULAR']]
    out += [(c, 'CJ_BTU') for c in lista['BTU']]
    return out


def haversine_m(a, b):
    r = 6371000
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


# ------------------------------------------------------------------ DFV
class DFV:
    def __init__(self):
        r = sql("select url, acesso->>'usuario' u, acesso->>'senha1' s1, acesso->>'senha2' s2 "
                "from config_links where chave = 'dfv_sudeste'")[0]
        os.environ.update(DFV_URL=r['url'] or '', SDE_USUARIO=r['u'] or 'PARCEIRO', SDE_SENHA1=r['s1'] or '',
                          SDE_SENHA2=r['s2'] or '', DFV_OP_TOKEN=os.environ.get('DFV_OP_TOKEN') or 'x' * 30)
        os.environ.setdefault('DFV_CHROME_CANAL', 'chrome')
        sys.path.insert(0, AQUI)
        import operador  # noqa: E402 — lê o .env no import
        operador.log = lambda m: print(f'  [dfv] {m.split("(")[0][:60]}', flush=True)
        self.O = operador
        self.op = operador.Operador()
        for tentativa in range(2):
            try:
                self.op.login(leve=True)
                break
            except Exception as e:  # noqa: BLE001
                if tentativa:
                    raise
                print(f'  login do DFV falhou ({type(e).__name__}) — de novo')
        if 'grade' not in self.op.modelos:
            raise SystemExit('sem o modelo da grade do painel')
        self.particao = None
        try:
            d = self.op._pedir('data', {'UF': 'MG'})
            ms = (d[0] if d else {}).get('Min(BASE_HP_F.dt_dfv_particao)')
            if ms:
                self.particao = time.strftime('%Y-%m-%d', time.gmtime(ms / 1000))
        except Exception:  # noqa: BLE001
            pass

    def agregado(self, municipio, grupo, medidas, extra_in=None, janela=30000):
        """Pedido da grade do painel com os mesmos filtros de login, agrupado por `grupo` e com `medidas` (nome, função, coluna).
        Funções do Power BI: 0 soma · 1 média · 2 contagem distinta · 5 contagem."""
        b = json.loads(self.O.com_filtros(self.op.modelos['grade']['corpo'], {'UF': 'MG', 'MUNICIPIO': municipio}))
        cmd = b['queries'][0]['Query']['Commands'][0]['SemanticQueryDataShapeCommand']
        q = cmd['Query']
        src = next(f['Name'] for f in q['From'] if f.get('Entity') == 'BASE_HP_F')
        col = lambda p: {'Column': {'Expression': {'SourceRef': {'Source': src}}, 'Property': p}}  # noqa: E731
        sel = [dict(col(g), Name=f'BASE_HP_F.{g}') for g in grupo]
        sel += [{'Aggregation': {'Expression': col(p), 'Function': fn}, 'Name': nome} for nome, fn, p in medidas]
        q['Select'] = sel
        for w in q['Where']:
            if 'Target' in w:
                w['Target'] = [col(g) for g in grupo]
        for coluna, valores in (extra_in or {}).items():
            q['Where'].append({'Condition': {'In': {'Expressions': [col(coluna)],
                                                     'Values': [[{'Literal': {'Value': lit(v)}}] for v in valores]}}})
        cmd['Binding'] = {'Primary': {'Groupings': [{'Projections': list(range(len(sel)))}]},
                          'DataReduction': {'DataVolume': 3, 'Primary': {'Window': {'Count': janela}}}, 'Version': 1}
        b['cancelQueries'] = []
        m = self.op.modelos['grade']
        r = self.op.page.evaluate("""async ({url, chave, corpo}) => {
            const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 30000);
            try {
              const r = await fetch(url, {method: 'POST', body: corpo, signal: ctl.signal, headers: {
                'Content-Type': 'application/json;charset=UTF-8', 'X-PowerBI-ResourceKey': chave,
                'ActivityId': crypto.randomUUID(), 'RequestId': crypto.randomUUID()}});
              return {status: r.status, txt: await r.text()};
            } catch (e) { return {status: 0, txt: String(e)}; } finally { clearTimeout(t); }
        }""", {'url': m['url'], 'chave': m['chave'], 'corpo': json.dumps(b, ensure_ascii=False)})
        if r['status'] != 200:
            raise RuntimeError(f'painel respondeu {r["status"]}')
        d = json.loads(r['txt'])
        ds = d['results'][0]['result']['data']['dsr']
        if 'DataShapes' in ds or not ds.get('DS'):
            raise RuntimeError('painel recusou o pedido agregado')
        if ds['DS'][0].get('RT'):
            raise RuntimeError(f'resposta cortada em {janela} linhas')
        return self.O.decodificar(d)

    def municipio(self, cidade):
        """Nome do município no DFV: tenta sem acento e com acento (maiúsculas). None se nenhum tem fachada."""
        base = re.sub(r'\s*\(.*\)|,.*$', '', cidade).strip().upper()
        for nome in dict.fromkeys([sem_acento(base), base]):
            linhas = self.agregado(nome, ['UF'], [('hps', 5, 'NO_FACHADA')])
            if linhas and (linhas[0].get('hps') or 0) > 0:
                return nome
        return None


def cmd_cidades(dfv, so=None):
    alvo = [(c, cj) for c, cj in cidades_c2() if not so or sem_acento(c.upper()).startswith(sem_acento(so.upper()))]
    print(f'{len(alvo)} cidades da C2 · base do DFV {dfv.particao or "?"}')
    resumo = []
    for cidade, conjunto in alvo:
        t = time.time()
        mun = dfv.municipio(cidade)
        nome_dfv = mun or sem_acento(re.sub(r'\s*\(.*\)|,.*$', '', cidade).strip().upper())
        bairros = {}
        if mun:
            linhas = dfv.agregado(mun, ['BAIRRO', 'CODIGO_LOGRADOURO'],
                                  [('fach', 2, 'NO_FACHADA'), ('hps', 5, 'NO_FACHADA'),
                                   ('lat', 1, 'LATITUDE'), ('lon', 1, 'LONGITUDE')])
            for x in linhas:
                nome = (x.get('BASE_HP_F.BAIRRO') or '(sem bairro)').strip()
                b = bairros.setdefault(nome, {'fach': 0, 'hps': 0, 'la': 0.0, 'lo': 0.0, 'peso': 0})
                f, h = int(x.get('fach') or 0), int(x.get('hps') or 0)
                b['fach'] += f
                b['hps'] += h
                try:
                    la, lo = float(x['lat']), float(x['lon'])
                    if la and lo:
                        b['la'] += la * f
                        b['lo'] += lo * f
                        b['peso'] += f
                except (KeyError, TypeError, ValueError):
                    pass
        fach = sum(b['fach'] for b in bairros.values())
        hps = sum(b['hps'] for b in bairros.values())
        cidade_limpa = re.sub(r'\s*\(.*\)|,.*$', '', cidade).strip()
        stmts = [f"delete from public.dfv_cobertura_bairro where parceiro_id = 'dharma' and uf = 'MG' and municipio = {lit(nome_dfv)};"]
        stmts.append(
            'insert into public.dfv_cobertura_cidade (uf, municipio, cidade, conjunto, fachadas, hps, bairros, particao, atualizado_em) '
            f"values ('MG', {lit(nome_dfv)}, {lit(cidade_limpa)}, {lit(conjunto)}, {fach}, {hps}, {len(bairros)}, "
            f"{lit(dfv.particao)}, now()) on conflict (parceiro_id, uf, municipio) do update set cidade = excluded.cidade, "
            'conjunto = excluded.conjunto, fachadas = excluded.fachadas, hps = excluded.hps, bairros = excluded.bairros, '
            'particao = excluded.particao, atualizado_em = now();')
        valores = [f"('MG', {lit(nome_dfv)}, {lit(n)}, {b['fach']}, {b['hps']}, "
                   f"{lit(round(b['la'] / b['peso'], 6) if b['peso'] else None)}, "
                   f"{lit(round(b['lo'] / b['peso'], 6) if b['peso'] else None)})" for n, b in bairros.items()]
        for i in range(0, len(valores), 400):
            stmts.append('insert into public.dfv_cobertura_bairro (uf, municipio, bairro, fachadas, hps, lat, lon) values '
                         + ', '.join(valores[i:i + 400]) + ';')
        sql('begin;\n' + '\n'.join(stmts) + '\ncommit;', escrever=True)
        resumo.append((cidade_limpa, conjunto, fach, len(bairros)))
        print(f'  {cidade_limpa:<24} {conjunto:<11} {fach:>7} fachadas · {len(bairros):>4} bairros '
              f'{"(DFV sem a cidade)" if not mun else ""} {time.time() - t:.1f}s', flush=True)
    return resumo


def geocodificar_cep(cep):
    """Ponto do CEP (centro do trecho). Só o CEP sai daqui — sem número, nome ou telefone."""
    for fonte, url in (('awesomeapi', f'https://cep.awesomeapi.com.br/json/{cep}'),
                       ('brasilapi', f'https://brasilapi.com.br/api/cep/v2/{cep}')):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'niogen-cobertura'})
            d = json.loads(urllib.request.urlopen(req, timeout=15).read())
            if fonte == 'awesomeapi':
                la, lo = d.get('lat'), d.get('lng')
            else:
                c = ((d.get('location') or {}).get('coordinates') or {})
                la, lo = c.get('latitude'), c.get('longitude')
            if la and lo:
                return (float(la), float(lo)), fonte
        except Exception:  # noqa: BLE001
            continue
    return None, None


def faixa(m):
    if m is None:
        return 'sem_medida'
    return 'ate_200m' if m <= 200 else ('200m_1km' if m <= 1000 else 'mais_1km')


def cmd_distancias(dfv, refazer=False):
    conv = sql(f"""
      select c.id, regexp_replace(coalesce(c.cep, c.endereco_cep->>'cep', ''), '\\D', '', 'g') as cep, k.municipio
        from public.mari_conversas c
        left join public.dfv_cobertura_cidade k on k.parceiro_id = 'dharma' and k.cidade_norm = public._norm_geo(c.cidade)
       where c.canal = 'whatsapp' and c.funil_destino = 'sem_cobertura' and c.created_at >= '{DESDE}'
         {'' if refazer else 'and not exists (select 1 from public.conversa_cobertura_distancia d where d.conversa_id = c.id)'}""")
    print(f'{len(conv)} conversas sem cobertura para medir')
    bairros_cache, fach_cache, linhas, cont = {}, {}, [], {}
    for c in conv:
        dist, fonte = None, None
        ponto, fonte = (geocodificar_cep(c['cep']) if len(c['cep'] or '') == 8 else (None, None))
        mun = c.get('municipio')
        if ponto and not mun:
            mun = None                                   # cidade fora das 35 medidas: sem DFV carregado → sem medida
        if ponto and mun:
            if mun not in bairros_cache:
                bairros_cache[mun] = sql(f"select bairro, lat, lon from public.dfv_cobertura_bairro where parceiro_id = 'dharma' "
                                         f"and municipio = {lit(mun)} and lat is not null")
            # bairros do mais perto ao mais longe (pelo centro); lê as fachadas de 1 bairro por vez e para quando o centro
            # do próximo bairro está a mais de 3 km além da melhor distância já achada (bairro raramente passa de 3 km de raio)
            ordem = sorted(((haversine_m(ponto, (float(b['lat']), float(b['lon']))), b['bairro']) for b in bairros_cache[mun]))
            perto = [(dc, n) for dc, n in ordem if dc <= RAIO_BAIRROS_M]
            if not perto and ordem:
                dist = max(ordem[0][0], RAIO_BAIRROS_M)   # nada a 5 km: mais de 1 km com certeza
            elif not ordem:
                dist = None
            else:
                melhor = None
                for dc, nome in perto:
                    if melhor is not None and dc > melhor + 3000:
                        break
                    chave = (mun, nome)
                    if chave not in fach_cache:
                        try:
                            fach_cache[chave] = dfv.agregado(mun, ['CODIGO_LOGRADOURO', 'NO_FACHADA'],
                                                             [('lat', 1, 'LATITUDE'), ('lon', 1, 'LONGITUDE')],
                                                             extra_in={'BAIRRO': [nome]})
                        except RuntimeError as e:
                            print(f'  bairro pulado ({e})')
                            fach_cache[chave] = []
                    for p in fach_cache[chave]:
                        try:
                            d_ = haversine_m(ponto, (float(p['lat']), float(p['lon'])))
                        except (KeyError, TypeError, ValueError):
                            continue
                        melhor = d_ if melhor is None else min(melhor, d_)
                dist = melhor
        f = faixa(None if dist is None else round(dist))
        cont[f] = cont.get(f, 0) + 1
        linhas.append(f"({lit(c['id'])}::uuid, {lit(None if dist is None else int(round(dist)))}, {lit(f)}, {lit(fonte)}, now())")
    if linhas:
        sql('insert into public.conversa_cobertura_distancia (conversa_id, distancia_m, faixa, geo_fonte, calculado_em) values '
            + ', '.join(linhas) + ' on conflict (conversa_id) do update set distancia_m = excluded.distancia_m, '
            'faixa = excluded.faixa, geo_fonte = excluded.geo_fonte, calculado_em = now();', escrever=True)
    print('  faixas:', cont)
    return cont


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    a = sys.argv[1:] or ['tudo']
    so = a[a.index('--so') + 1] if '--so' in a else None
    d = DFV()
    if a[0] in ('cidades', 'tudo'):
        cmd_cidades(d, so)
    if a[0] in ('distancias', 'tudo'):
        cmd_distancias(d, '--refazer' in a)
