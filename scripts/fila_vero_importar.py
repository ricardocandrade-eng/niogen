#!/usr/bin/env python3
# NIOGEN | scripts/fila_vero_importar.py | 16/11/2026 — Claude Code (prompt docs/Prompt_fila_vero_piloto100_161126_1640.md)
# Importa UMA VEZ a base da Fila Vero para public.fila_vero (migration 0239) e roda o filtro de Juiz de Fora (faixa A).
# Lê o export CSV público da planilha (link em config_links.fila_vero_base — nunca no repo) direto para a memória:
# nada é gravado em arquivo, nada de dado do cliente é impresso (só contagens).
# Só os campos permitidos: nome, telefone (WhatsApp; se vazio, Tel. Ligação), CEP, rua, número, complemento, bairro,
# cidade, UF, segmento e data de ativação. NUNCA CPF/CNPJ, RG, nome da mãe, nascimento, e-mail ou IDs de contrato.
# Dedup por telefone; telefone com venda em andamento na Vero fica fora (nunca disparar).
#
# Uso:  python scripts/fila_vero_importar.py            # dry-run: só contagens
#       python scripts/fila_vero_importar.py --gravar   # importa e filtra
import csv
import datetime
import glob
import io
import json
import os
import re
import subprocess
import sys
import urllib.request

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SEG = {'3 - finalizada/instalada': 'instalado', '5 - finalizado': 'instalado', '4 - entregue': 'instalado',
       '4- entregue': 'instalado',
       'cancelamento comercial': 'nao_instalou', 'cancelamento tecnico': 'nao_instalou', 'cancelamento técnico': 'nao_instalou',
       'cancelado': 'nao_instalou', 'devolvido': 'nao_instalou', 'churn': 'churn',
       '2- aguardando entrega': 'em_andamento', '1- conferencia/ativação': 'em_andamento',
       '1- conferência/ativação': 'em_andamento', '2- aguardando instalação': 'em_andamento', 'pendencia vero': 'em_andamento'}
PRIORIDADE = {'instalado': 3, 'nao_instalou': 2, 'churn': 1}


def supabase_exe():
    # chama o binário direto (o npx.cmd passa pelo cmd.exe, que corta a linha em 8 KB)
    cands = glob.glob(os.path.expanduser('~/AppData/Local/npm-cache/_npx/*/node_modules/@supabase/cli-windows-x64/bin/supabase.exe'))
    if not cands:
        raise SystemExit('supabase.exe não encontrado (rode um "npx supabase --version" antes).')
    return max(cands, key=os.path.getmtime)


EXE = supabase_exe() if sys.platform == 'win32' else 'supabase'


def sql(q, escrita=False):
    args = [EXE, 'db', 'query', '--remote', '-o', 'json'] + (['--yes'] if escrita else ['--read-only']) + [q]
    p = subprocess.run(args, cwd=REPO, capture_output=True)
    out = p.stdout.decode('utf-8', 'replace')
    if p.returncode != 0:
        raise SystemExit(f'sql falhou: {p.stderr.decode("utf-8", "replace")[-400:]}')
    return json.loads(out[out.find('{'):]).get('rows', [])


def tel(*vals):
    for v in vals:
        d = re.sub(r'\D', '', v or '')
        d = d.lstrip('0')
        if d.startswith('55') and len(d) in (12, 13):
            return d
        if len(d) in (10, 11):
            return '55' + d
    return None


def data(v):
    v = (v or '').strip()[:10]
    for f in ('%d/%m/%Y', '%Y-%m-%d', '%d/%m/%y'):
        try:
            return datetime.datetime.strptime(v, f).date().isoformat()
        except ValueError:
            pass
    return None


def main():
    url = sql("select url from public.config_links where chave = 'fila_vero_base'")[0]['url']
    texto = urllib.request.urlopen(url, timeout=120).read().decode('utf-8').replace('\r', '')
    linhas = list(csv.reader(io.StringIO(texto)))
    h = linhas[0]
    col = {nome: i for i, nome in enumerate(h) if nome}
    g = lambda r, nome: (r[col[nome]] if col.get(nome) is not None and col[nome] < len(r) else '').strip()
    por_tel, andamento, sem_tel, sem_seg = {}, set(), 0, 0
    for r in linhas[1:]:
        seg = SEG.get(g(r, 'Status').lower())
        t = tel(g(r, 'WhatsApp'), g(r, 'Tel. Ligação'))
        if not t:
            sem_tel += 1
            continue
        if not seg:
            sem_seg += 1
            continue
        if seg == 'em_andamento':
            andamento.add(t)
            continue
        item = {'nome': g(r, 'Cliente'), 'telefone': t, 'cep': g(r, 'CEP'), 'rua': g(r, 'Rua'),
                'numero': g(r, 'Número da Fachada'), 'complemento': g(r, 'Complemento'), 'bairro': g(r, 'Bairro'),
                'cidade': g(r, 'Cidade'), 'uf': g(r, 'UF'), 'segmento': seg, 'ativacao': data(g(r, 'Data Ativação'))}
        atual = por_tel.get(t)
        if not atual or (PRIORIDADE[seg], item['ativacao'] or '') > (PRIORIDADE[atual['segmento']], atual['ativacao'] or ''):
            por_tel[t] = item
    for t in andamento:
        por_tel.pop(t, None)
    base = list(por_tel.values())
    jf = sum(1 for b in base if b['cidade'].upper().startswith('JUIZ DE FORA'))
    segs = {}
    for b in base:
        segs[b['segmento']] = segs.get(b['segmento'], 0) + 1
    print(f'linhas {len(linhas) - 1} · sem telefone {sem_tel} · sem status útil {sem_seg} · '
          f'telefones em venda Vero em andamento (fora) {len(andamento)}')
    print(f'telefones únicos a importar {len(base)} · Juiz de Fora {jf} · segmentos {segs}')
    if '--gravar' not in sys.argv:
        return
    lote = 'vero_' + datetime.datetime.now().strftime('%d%m%y_%H%M')
    total, passo = 0, 45
    for i in range(0, len(base), passo):
        j = json.dumps(base[i:i + passo], ensure_ascii=False, separators=(",", ":")).replace("'", "''")
        total += sql(f"select public.fila_vero_importar('{j}'::jsonb, '{lote}') n", escrita=True)[0]['n']
    print(f'importados {total} (lote {lote})')
    print('filtro JF:', sql('select public.fila_vero_filtrar_jf() f', escrita=True)[0]['f'])
    print('fila:', sql('select public.fila_vero_resumo() r', escrita=True)[0]['r']['por_status'])


if __name__ == '__main__':
    main()
