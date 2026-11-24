# NIOGEN | scripts/arquivar_diario.py | 23/11/2026 23:30 — Claude Code / Opus 5.5
# Arquiva o Diário de Bordo: 6 registros no topo (1 "Última atualização" + 5 "Anterior"), o resto desce para
# diario/AAAA-Sww.md pela semana ISO da data do próprio registro; drena a caixa de entrada do Cowork e o log
# do cabeçalho do INFRA.md. Prompt: docs/Prompt_arquivar_diario_infra_231126_2255.md (pasta do Drive).
#
#   python scripts/arquivar_diario.py              # só relata (padrão), não escreve nada
#   python scripts/arquivar_diario.py --aplicar    # backup, escreve, confere a conta; não fechou -> desfaz
#
# Travas: backup antes de escrever; a conta tem de fechar (cada registro de antes está, com o mesmo texto,
# no topo ou num arquivo de semana) senão restaura o backup; idempotente; nunca resume nem reescreve texto
# de registro — só move linhas e troca o rótulo "Última atualização:" <-> "Anterior:".
# rev. 23/11/2026 ~23h20: trava de escrita concorrente — se algum arquivo mudou (ou nasceu) entre a leitura e a
# gravação (o Cowork acrescentando na caixa, outra sessão escrevendo no Diário), não grava; se mudou no meio da
# gravação, desfaz pelo backup. Em qualquer caso: rodar de novo.
import argparse
import datetime as dt
import hashlib
import os
import re
import shutil
import sys

PASTA_PADRAO = r'C:\Users\ricar\Meu Drive\Projetos Claude\dharmapro-nio'
BACKUP_PADRAO = r'C:\Users\ricar\backups\niogen\diario'
DIARIO = 'ESTADO ATUAL — Diário de Bordo.md'
CAIXA = 'Diário — caixa de entrada do Cowork.md'
INFRA = 'INFRA.md'
TOPO_MAX = 6
INFRA_TOPO = 2
INFRA_CORTE = dt.date(2026, 11, 23)  # revisões até esta data vão para infra_revisoes_ate_231126.md
CAIXA_48H = dt.timedelta(hours=48)
MARCA_CAIXA = '<!-- entradas abaixo desta linha -->'
VAZIA_CAIXA = '_(caixa vazia — drenada'

RE_REG = re.compile(r'^(>\s*)?(Última atualização|Anterior):\s?(.*)$')
RE_INFRA = re.compile(r'^>\s*(Revisão anterior|Revisão|Anterior):\s?(.*)$')
RE_DATA = re.compile(r'(\d{1,2})/(\d{1,2})(?:/(\d{4}))?')
RE_HORA = re.compile(r'(\d{1,2})(?:h(\d{2})?|:(\d{2}))')


def ler(caminho):
    with open(caminho, encoding='utf-8', newline='') as f:
        return f.read()


LIDOS = {}  # caminho -> hash do texto lido no planejamento (trava de escrita concorrente)


def ler_fonte(caminho):
    texto = ler(caminho)
    LIDOS[caminho] = hashlib.sha256(texto.encode('utf-8')).hexdigest()
    return texto


def mudou(caminho, novos):
    """True se o arquivo mudou desde a leitura do planejamento (ou se um arquivo que ia nascer já existe)."""
    if caminho in novos:
        return os.path.exists(caminho)
    if caminho in LIDOS:
        if not os.path.exists(caminho):
            return True
        return hashlib.sha256(ler(caminho).encode('utf-8')).hexdigest() != LIDOS[caminho]
    return False


def gravar(caminho, texto):
    tmp = caminho + '.tmp_arquivar'
    with open(tmp, 'w', encoding='utf-8', newline='') as f:
        f.write(texto)
    os.replace(tmp, caminho)


def linhas(texto):
    return texto.split('\n')


def juntar(ls):
    return '\n'.join(ls)


def h(texto):
    return hashlib.sha256(texto.encode('utf-8')).hexdigest()[:12]


# ---------- datas ----------

def achar_data(texto, ano_padrao=None, no_inicio=False):
    """Devolve (datetime, tem_hora, ano_inferido) ou None. Pega a 1ª data DD/MM[/AAAA] e a hora logo depois."""
    alvo = texto
    if no_inicio:
        alvo = re.sub(r'^[\s>|*#\-_`]*(cabecalho:|linha:)?[\s|*#\-_`]*', '', texto)
        m = RE_DATA.match(alvo)
    else:
        m = RE_DATA.search(alvo[:200])
    if not m:
        return None
    d, mes, ano = int(m.group(1)), int(m.group(2)), m.group(3)
    inferido = False
    if ano:
        ano = int(ano)
    elif ano_padrao:
        ano, inferido = ano_padrao, True
    else:
        return None
    try:
        base = dt.datetime(ano, mes, d)
    except ValueError:
        return None
    resto = alvo[m.end():m.end() + 25]
    mh = RE_HORA.search(resto)
    tem_hora = False
    if mh and resto[:mh.start()].strip(' ,~(—–-*') == '':
        hh = int(mh.group(1))
        mm = int(mh.group(2) or mh.group(3) or 0)
        if hh <= 23 and mm <= 59:
            base = base.replace(hour=hh, minute=mm)
            tem_hora = True
    return base, tem_hora, inferido


def chave(reg):
    """Ordena: data/hora decrescente; sem hora fica abaixo dos com hora do mesmo dia."""
    quando, tem_hora = reg['quando'], reg['tem_hora']
    return (quando, 1 if tem_hora else 0)


def semana(quando):
    a, s, _ = quando.isocalendar()
    return '%d-S%02d' % (a, s)


def faixa_semana(nome):
    a, s = nome.split('-S')
    seg = dt.date.fromisocalendar(int(a), int(s), 1)
    dom = seg + dt.timedelta(days=6)
    return seg, dom


# ---------- registros ----------

def bloco_registro(primeira_corpo, continuacao, rotulo):
    return ['> %s: %s' % (rotulo, primeira_corpo)] + continuacao


def parse_topo(ls, ini, fim):
    """Registros entre ini e fim (exclusivo). Registro = linha de rótulo + linhas '> ...' de continuação.
    Linhas vazias e '>' sozinhas são separadores (não carregam fato)."""
    regs, separadores, soltas = [], 0, []
    atual = None
    for i in range(ini, fim):
        t = ls[i]
        m = RE_REG.match(t)
        if m:
            atual = {'corpo': m.group(3), 'cont': [], 'orig': [t]}
            dd = achar_data(m.group(3))
            atual['quando'], atual['tem_hora'] = (dd[0], dd[1]) if dd else (None, False)
            regs.append(atual)
        elif t.strip() in ('', '>'):
            separadores += 1
        elif t.startswith('>') and atual is not None:
            atual['cont'].append(t)
            atual['orig'].append(t)
        else:
            soltas.append((i + 1, t))
            # linha estranha: não some — vira continuação do registro anterior (ou fica solta no topo)
            if atual is not None:
                atual['cont'].append(t)
                atual['orig'].append(t)
    return regs, separadores, soltas


def parse_caixa(ls):
    """Entradas da caixa. Começa entrada nova: '## ENTRADA' (fecha a anterior) ou linha que começa com data
    (cabecalho:, linha:, '| **DD/MM', '- DD/MM/AAAA', '### DD/MM/AAAA', '**DD/MM/AAAA'); a 1ª 'linha:' logo depois
    de um 'cabecalho:' é o par dele e fica junto. O resto é continuação."""
    try:
        ini = ls.index(MARCA_CAIXA) + 1
    except ValueError:
        raise SystemExit('caixa: não achei a linha "%s"' % MARCA_CAIXA)
    entradas, sep = [], 0
    atual = None
    # ano das entradas que só trazem DD/MM: o da 1ª data completa da caixa, depois o da entrada anterior
    m_ano = re.search(r'\d{1,2}/\d{1,2}/(\d{4})', '\n'.join(ls[ini:]))
    ano = int(m_ano.group(1)) if m_ano else None
    par_aberto = False
    for i in range(ini, len(ls)):
        t = ls[i]
        if t.startswith(VAZIA_CAIXA):
            continue
        if t.strip() == '':
            sep += 1
            continue
        if t.strip() == '## ENTRADA':
            sep += 1
            atual, par_aberto = None, False
            continue
        indentada = t.startswith(' ') or t.startswith('\t')
        if t.startswith('## ') or t.startswith('### '):
            # título com data em qualquer ponto do começo ("## ENTRADA — 19/11/2026 ~11h — …")
            m = RE_DATA.search(t[:60])
            dd = achar_data(t[m.start():], ano_padrao=ano) if m else None
        else:
            dd = None if indentada else achar_data(t, ano_padrao=ano, no_inicio=True)
        eh_linha = t.startswith('linha:')
        if dd and not (eh_linha and par_aberto and atual is not None):
            if not dd[2]:
                ano = dd[0].year
            atual = {'ls': [t], 'quando': dd[0], 'tem_hora': dd[1], 'ano_inferido': dd[2], 'n': i + 1}
            entradas.append(atual)
            par_aberto = t.startswith('cabecalho:')
        else:
            if atual is None:
                atual = {'ls': [t], 'quando': None, 'tem_hora': False, 'ano_inferido': False, 'n': i + 1}
                entradas.append(atual)
            else:
                atual['ls'].append(t)
            if eh_linha:
                par_aberto = False
    return ini, entradas, sep


def caixa_para_registro(ent):
    """Converte a entrada no formato de registro: 1ª linha -> '> Anterior: <texto>' (sai só o marcador
    'cabecalho:'/'linha:'/'- '/'### '), as outras -> '> <texto>' sem mudar nada."""
    pri = ent['ls'][0]
    corpo = re.sub(r'^(cabecalho:|linha:)\s*', '', pri)
    corpo = re.sub(r'^(- |### )', '', corpo)
    cont = ['> ' + x for x in ent['ls'][1:]]
    return {'corpo': corpo, 'cont': cont, 'quando': ent['quando'], 'tem_hora': ent['tem_hora'],
            'origem': 'caixa', 'orig': ent['ls']}


# ---------- arquivo de semana ----------

def cabecalho_semana(nome, agora):
    seg, dom = faixa_semana(nome)
    return [
        '<!-- NIOGEN | diario/%s.md | %s — histórico do Diário de Bordo movido (não resumido) por scripts/arquivar_diario.py -->'
        % (nome, agora.strftime('%d/%m/%Y %H:%M')),
        '',
        '# Diário de Bordo · %s (%s a %s)' % (nome, seg.strftime('%d/%m'), dom.strftime('%d/%m/%Y')),
        '',
        '> Texto movido do `ESTADO ATUAL — Diário de Bordo.md` sem alteração. O Diário guarda só o estado de hoje; o histórico fica aqui.',
        '',
        '## Atualizações (as linhas "Última atualização / Anterior" daquela semana)',
        '',
    ]


def inserir_na_semana(ls, regs):
    """Insere cada registro na seção '## Atualizações…' em ordem decrescente, sem mexer nas linhas que já estão
    lá: entra antes do 1º registro existente mais antigo que ele. Registro cuja 1ª linha já existe no arquivo é
    pulado (idempotência). Devolve (linhas, inseridos, ja_estavam)."""
    try:
        sec = next(i for i, t in enumerate(ls) if t.startswith('## Atualizações'))
    except StopIteration:
        # arquivo antigo sem a seção: cria no fim
        ls = ls + ['', '## Atualizações (as linhas "Última atualização / Anterior" daquela semana)', '']
        sec = len(ls) - 2
    existentes = set(ls)
    inseridos, ja = 0, 0
    for r in sorted(regs, key=chave, reverse=True):
        bloco = bloco_registro(r['corpo'], r['cont'], 'Anterior')
        if bloco[0] in existentes:
            ja += 1
            continue
        fim = next((i for i in range(sec + 1, len(ls)) if ls[i].startswith('## ')), len(ls))
        pos = None
        ultimo_reg = None
        for i in range(sec + 1, fim):
            m = RE_REG.match(ls[i])
            if not m:
                continue
            ultimo_reg = i
            dd = achar_data(m.group(3))
            if dd and (dd[0], 1 if dd[1] else 0) < chave(r):
                pos = i
                break
        if pos is None:
            if ultimo_reg is None:
                pos = sec + 1
                while pos < fim and ls[pos].strip() == '':
                    pos += 1
            else:
                pos = ultimo_reg + 1
                while pos < fim and ls[pos].startswith('>') and not RE_REG.match(ls[pos]) and ls[pos].strip() != '>':
                    pos += 1
        ls = ls[:pos] + bloco + ls[pos:]
        existentes.update(bloco)
        inseridos += 1
    return ls, inseridos, ja


def contar_registros(texto):
    n = 0
    for t in linhas(texto):
        if RE_REG.match(t) and t.startswith('>'):
            n += 1
        elif t.startswith('| **'):
            n += 1  # linha da Linha do tempo (a contagem antiga do Histórico somava as duas)
    return n


# ---------- o trabalho ----------

class Plano:
    def __init__(self):
        self.escritas = {}   # caminho -> texto novo
        self.novos = []      # arquivos que não existiam
        self.rel = []
        self.avisos = []
        self.esperado = []   # (descrição, linha que tem de existir, arquivo onde procurar ou None=qualquer)


def planejar(pasta, agora, topo_max=TOPO_MAX):
    P = Plano()
    p_diario = os.path.join(pasta, DIARIO)
    p_caixa = os.path.join(pasta, CAIXA)
    p_infra = os.path.join(pasta, INFRA)
    p_dir = os.path.join(pasta, 'diario')

    # ---- Diário: topo ----
    tx = ler_fonte(p_diario)
    ls = linhas(tx)
    primeiro = next(i for i, t in enumerate(ls) if RE_REG.match(t))
    sec_onde = next(i for i in range(primeiro, len(ls)) if ls[i].startswith('## '))
    fim_topo = sec_onde
    while fim_topo > primeiro and ls[fim_topo - 1].strip() in ('', '---'):
        fim_topo -= 1
    regs, sep_topo, soltas = parse_topo(ls, primeiro, fim_topo)
    for r in regs:
        r['origem'] = 'topo'
    sem_data = [r for r in regs if r['quando'] is None]
    for n, t in soltas:
        P.avisos.append('Diário linha %d sem rótulo, mantida junto do registro anterior: %s' % (n, t[:110]))
    for r in sem_data:
        P.avisos.append('Diário: registro sem data legível, fica no topo: %s' % r['orig'][0][:110])

    # ---- caixa ----
    tc = ler_fonte(p_caixa)
    lc = linhas(tc)
    ini_caixa, entradas, sep_caixa = parse_caixa(lc)
    cx_sem_data = [e for e in entradas if e['quando'] is None]
    cx_ok = [e for e in entradas if e['quando'] is not None]
    inferidos = sum(1 for e in cx_ok if e['ano_inferido'])
    for e in cx_sem_data:
        P.avisos.append('Caixa linha %d: entrada sem data legível, fica na caixa: %s' % (e['n'], e['ls'][0][:110]))
    regs_cx = [caixa_para_registro(e) for e in cx_ok]
    recentes = [r for r in regs_cx if r['quando'] >= agora - CAIXA_48H]
    antigos_cx = [r for r in regs_cx if r['quando'] < agora - CAIXA_48H]

    # ---- ordenar e cortar o topo ----
    concorrem = [r for r in regs if r['quando'] is not None] + recentes
    concorrem.sort(key=chave, reverse=True)
    topo = concorrem[:topo_max]
    descem = concorrem[topo_max:] + antigos_cx

    novo_topo = []
    for k, r in enumerate(topo):
        novo_topo += bloco_registro(r['corpo'], r['cont'], 'Última atualização' if k == 0 else 'Anterior')
    for r in sem_data:
        novo_topo += bloco_registro(r['corpo'], r['cont'], 'Anterior')

    # ---- arquivos de semana ----
    por_semana = {}
    for r in descem:
        por_semana.setdefault(semana(r['quando']), []).append(r)
    semanas_texto = {}
    total_ins, total_ja = 0, 0
    rel_sem = []
    for nome in sorted(por_semana, reverse=True):
        cam = os.path.join(p_dir, nome + '.md')
        if os.path.exists(cam):
            base = linhas(ler_fonte(cam))
        else:
            base = cabecalho_semana(nome, agora)
            P.novos.append(cam)
        novo, ins, ja = inserir_na_semana(base, por_semana[nome])
        total_ins += ins
        total_ja += ja
        semanas_texto[nome] = juntar(novo)
        if ins:
            P.escritas[cam] = juntar(novo)
        elif cam in P.novos:
            P.novos.remove(cam)
        rel_sem.append('  %s: %d desce(m) (%d já estava(m) lá)%s' % (
            nome, ins + ja, ja, ' — arquivo novo' if cam in P.novos else ''))
    for r in descem:
        P.esperado.append((bloco_registro(r['corpo'], r['cont'], 'Anterior'),
                           os.path.join(p_dir, semana(r['quando']) + '.md')))
    for k, r in enumerate(topo):
        P.esperado.append((bloco_registro(r['corpo'], r['cont'], 'Última atualização' if k == 0 else 'Anterior'),
                           p_diario))

    # ---- Histórico (arquivado por semana) ----
    novo_ls = ls[:primeiro] + novo_topo + ls[fim_topo:]
    try:
        hi = next(i for i, t in enumerate(novo_ls) if t.startswith('## Histórico'))
        hf = next((i for i in range(hi + 1, len(novo_ls)) if novo_ls[i].startswith('## ')), len(novo_ls))
        idx = [i for i in range(hi, hf) if re.match(r'^- \[\d{4}-S\d{2}\]', novo_ls[i])]
        nomes = set()
        if os.path.isdir(p_dir):
            nomes |= {f[:-3] for f in os.listdir(p_dir) if re.match(r'^\d{4}-S\d{2}\.md$', f)}
        nomes |= set(semanas_texto)
        itens = []
        for nome in sorted(nomes, reverse=True):
            cam = os.path.join(p_dir, nome + '.md')
            texto = P.escritas.get(cam) or semanas_texto.get(nome) or ler(cam)
            seg, dom = faixa_semana(nome)
            itens.append('- [%s](diario/%s.md) — %s a %s · %d registros' % (
                nome, nome, seg.strftime('%d/%m'), dom.strftime('%d/%m'), contar_registros(texto)))
        if idx:
            novo_ls = novo_ls[:idx[0]] + itens + [t for i, t in enumerate(novo_ls[idx[0]:], idx[0]) if i not in idx]
        else:
            P.avisos.append('Diário: seção Histórico sem lista de semanas — lista não atualizada')
    except StopIteration:
        P.avisos.append('Diário: sem seção "## Histórico" — lista de semanas não atualizada')
    novo_diario = juntar(novo_ls)
    if novo_diario != tx:
        P.escritas[p_diario] = novo_diario

    # ---- caixa: fica só o cabeçalho (+ o que não tem data) ----
    if cx_ok:
        resto = []
        for e in cx_sem_data:
            resto += e['ls']
        nova_caixa = lc[:ini_caixa] + [
            '',
            '%s em %s por `scripts/arquivar_diario.py`; as entradas foram para o Diário e para `diario/AAAA-Sww.md`)_'
            % (VAZIA_CAIXA, agora.strftime('%d/%m/%Y %H:%M')),
        ] + ([''] + resto if resto else []) + ['']
        P.escritas[p_caixa] = juntar(nova_caixa)

    # ---- INFRA: cabeçalho ----
    ti = ler_fonte(p_infra)
    li = linhas(ti)
    sec1 = next(i for i, t in enumerate(li) if t.startswith('## '))
    reg_i = []
    sep_i = 0
    i_primeiro = None
    i_ultimo = None
    for i in range(sec1):
        m = RE_INFRA.match(li[i])
        if m:
            dd = achar_data(m.group(2))
            reg_i.append({'linha': li[i], 'rot': m.group(1), 'corpo': m.group(2),
                          'quando': dd[0] if dd else None, 'tem_hora': dd[1] if dd else False})
            i_primeiro = i if i_primeiro is None else i_primeiro
            i_ultimo = i
    infra_mov = []
    if reg_i:
        miolo = li[i_primeiro:i_ultimo + 1]
        nao_reg = [t for t in miolo if not RE_INFRA.match(t)]
        estranhas = [t for t in nao_reg if t.strip() not in ('', '>')]
        sep_i = len(nao_reg) - len(estranhas)
        for t in estranhas:
            P.avisos.append('INFRA: linha sem rótulo no meio do log (mantida no topo): %s' % t[:110])
        i_sem = [r for r in reg_i if r['quando'] is None]
        for r in i_sem:
            P.avisos.append('INFRA: revisão sem data legível, fica no topo: %s' % r['linha'][:110])
        i_ok = sorted([r for r in reg_i if r['quando'] is not None], key=chave, reverse=True)
        fica = i_ok[:INFRA_TOPO]
        infra_mov = i_ok[INFRA_TOPO:]
        novo_cab = []
        for k, r in enumerate(fica):
            novo_cab.append('> %s: %s' % ('Revisão' if k == 0 else 'Anterior', r['corpo']))
        novo_cab += [r['linha'] for r in i_sem] + estranhas
        novo_infra = juntar(li[:i_primeiro] + novo_cab + li[i_ultimo + 1:])
        for r in fica:
            P.esperado.append((['> %s: %s' % ('Revisão' if fica.index(r) == 0 else 'Anterior', r['corpo'])], p_infra))
        if novo_infra != ti:
            P.escritas[p_infra] = novo_infra
        # destino das que saem
        destinos = {}
        for r in infra_mov:
            if r['quando'].date() <= INFRA_CORTE:
                nome = 'infra_revisoes_ate_%s' % INFRA_CORTE.strftime('%d%m%y')
            else:
                nome = 'infra_revisoes_' + semana(r['quando'])
            destinos.setdefault(nome, []).append(r)
        for nome, rs in destinos.items():
            cam = os.path.join(p_dir, nome + '.md')
            if cam in P.escritas:
                base = linhas(P.escritas[cam])
            elif os.path.exists(cam):
                base = linhas(ler_fonte(cam))
            else:
                base = [
                    '<!-- NIOGEN | diario/%s.md | %s — log do cabeçalho do INFRA.md movido (não resumido) por scripts/arquivar_diario.py -->'
                    % (nome, agora.strftime('%d/%m/%Y %H:%M')),
                    '',
                    '# INFRA — revisões antigas do cabeçalho',
                    '',
                    '> Linhas "Revisão / Anterior" que saíram do topo do `INFRA.md`, sem alteração, da mais nova para a mais antiga.',
                    '> O `INFRA.md` guarda no topo só a revisão mais recente e uma anterior.',
                    '',
                ]
                P.novos.append(cam)
            existentes = set(base)
            novas = [r['linha'] for r in rs if r['linha'] not in existentes]
            # mais novas no começo da lista (as que já estão ali são mais antigas, de rodadas anteriores)
            pos = next((i for i, t in enumerate(base) if RE_INFRA.match(t)), len(base))
            base = base[:pos] + novas + base[pos:]
            if novas:
                P.escritas[cam] = juntar(base) + ('' if base[-1] == '' else '\n')
            elif cam in P.novos:
                P.novos.remove(cam)
            for r in rs:
                P.esperado.append(([r['linha']], cam))

    # ---- relatório ----
    P.rel += [
        'Diário (%s, %d KB):' % (DIARIO, len(tx.encode('utf-8')) // 1024),
        '  registros no topo hoje: %d (%d "Última atualização", %d "Anterior"); separadores soltos: %d'
        % (len(regs), sum(1 for r in regs if 'Última atualização' in r['orig'][0][:25]),
           sum(1 for r in regs if r['orig'][0].lstrip('> ').startswith('Anterior')), sep_topo),
        '  sem data legível: %d' % len(sem_data),
        '  ficam no topo: %d   descem do topo: %d' % (len(topo), len([r for r in descem if r['origem'] == 'topo'])),
        'Caixa do Cowork (%s, %d linhas):' % (CAIXA, len(lc)),
        '  entradas: %d (ano deduzido do vizinho em %d; sem data: %d); linhas vazias/"## ENTRADA": %d'
        % (len(entradas), inferidos, len(cx_sem_data), sep_caixa),
        '  das últimas 48 h (concorrem ao topo): %d — entram no topo: %d' % (
            len(recentes), len([r for r in topo if r['origem'] == 'caixa'])),
        '  descem direto para a semana: %d' % len([r for r in descem if r['origem'] == 'caixa']),
        'Arquivos de semana (%d registros descem; %d gravados agora, %d já estavam lá):' % (
            len(descem), total_ins, total_ja),
    ] + rel_sem + [
        'INFRA (%s): %d linhas de log no cabeçalho, %d ficam, %d vão para diario/; separadores soltos: %d' % (
            INFRA, len(reg_i), len(reg_i) - len(infra_mov), len(infra_mov), sep_i),
        'Topo depois:',
    ] + ['  %s' % bloco_registro(r['corpo'], r['cont'], 'Última atualização' if k == 0 else 'Anterior')[0][:120]
         for k, r in enumerate(topo)]
    P.conta = {'antes': len(regs) + len(cx_ok), 'topo': len(topo) + len(sem_data),
               'semanas': total_ins + total_ja, 'infra_antes': len(reg_i),
               'infra_depois': len(reg_i) - len(infra_mov) + len(infra_mov)}
    return P


def conferir_conta(P):
    """Depois de gravar: relê do disco e confere que cada bloco esperado está, inteiro e na ordem, no arquivo."""
    falhas = []
    cache = {}
    for bloco, cam in P.esperado:
        if cam not in cache:
            cache[cam] = ler(cam) if os.path.exists(cam) else ''
        if juntar(bloco) not in cache[cam]:
            falhas.append('%s: falta %s' % (os.path.basename(cam), bloco[0][:90]))
    c = P.conta
    if c['antes'] != c['topo'] + c['semanas']:
        falhas.append('conta: antes %d != topo %d + semanas %d' % (c['antes'], c['topo'], c['semanas']))
    return falhas


def main():
    ap = argparse.ArgumentParser(description='Arquiva o Diário de Bordo, a caixa do Cowork e o cabeçalho do INFRA.')
    g = ap.add_mutually_exclusive_group()
    g.add_argument('--conferir', action='store_true', help='só relata (padrão)')
    g.add_argument('--aplicar', action='store_true', help='faz backup, escreve e confere a conta')
    ap.add_argument('--pasta', default=os.environ.get('NIOGEN_PASTA', PASTA_PADRAO))
    ap.add_argument('--backup', default=os.environ.get('NIOGEN_BACKUP_DIARIO', BACKUP_PADRAO))
    ap.add_argument('--topo', type=int, default=TOPO_MAX, help='registros que ficam no topo (0 = desce todos; usado na virada para o retrato)')
    ap.add_argument('--agora', help='data/hora de referência DD/MM/AAAA HH:MM (teste)')
    a = ap.parse_args()
    sys.stdout.reconfigure(encoding='utf-8')
    agora = dt.datetime.strptime(a.agora, '%d/%m/%Y %H:%M') if a.agora else dt.datetime.now().replace(second=0, microsecond=0)

    P = planejar(a.pasta, agora, a.topo)
    print('arquivar_diario — %s — %s' % ('APLICAR' if a.aplicar else 'conferir (não escreve nada)', agora.strftime('%d/%m/%Y %H:%M')))
    print('\n'.join(P.rel))
    c = P.conta
    print('Conta: %d registros antes (topo + caixa) = %d no topo + %d nos arquivos de semana -> %s' % (
        c['antes'], c['topo'], c['semanas'], 'fecha' if c['antes'] == c['topo'] + c['semanas'] else 'NÃO FECHA'))
    if P.avisos:
        print('Avisos (%d):' % len(P.avisos))
        for x in P.avisos:
            print('  - ' + x)
    print('Arquivos que mudariam: %d' % len(P.escritas))
    for cam in P.escritas:
        print('  %s%s' % (os.path.relpath(cam, a.pasta), ' (novo)' if cam in P.novos else ''))
    if not a.aplicar:
        return 0
    if not P.escritas:
        print('Nada a fazer.')
        return 0
    if c['antes'] != c['topo'] + c['semanas']:
        print('ABORTADO: a conta não fecha antes de escrever.')
        return 2
    mexidos = [c for c in P.escritas if mudou(c, P.novos)]
    if mexidos:
        print('ABORTADO sem gravar nada: arquivo mudou enquanto o script lia (alguém escrevendo agora?). Rode de novo.')
        for c in mexidos:
            print('  - ' + os.path.relpath(c, a.pasta))
        return 5

    # backup
    dest = os.path.join(a.backup, agora.strftime('%Y%m%d_%H%M'))
    n = 1
    while os.path.exists(dest):
        n += 1
        dest = os.path.join(a.backup, agora.strftime('%Y%m%d_%H%M') + '_%d' % n)
    os.makedirs(dest)
    salvos = {}
    for cam in P.escritas:
        if cam in P.novos:
            continue
        rel = os.path.relpath(cam, a.pasta)
        alvo = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(alvo), exist_ok=True)
        shutil.copy2(cam, alvo)
        if ler(alvo) != ler(cam):
            print('ABORTADO: backup de %s não confere.' % rel)
            return 3
        salvos[cam] = alvo
    print('Backup: %s (%d arquivos)' % (dest, len(salvos)))

    gravados = []
    try:
        for cam, texto in P.escritas.items():
            if mudou(cam, P.novos):
                raise RuntimeError('%s mudou durante a gravação (alguém escrevendo agora?) — rode de novo'
                                   % os.path.relpath(cam, a.pasta))
            os.makedirs(os.path.dirname(cam), exist_ok=True)
            gravar(cam, texto)
            gravados.append(cam)
        falhas = conferir_conta(P)
    except Exception as e:  # noqa: BLE001
        falhas = ['erro ao gravar: %r' % e]
    if falhas:
        for cam in gravados:
            if cam in salvos:
                shutil.copy2(salvos[cam], cam)
            elif cam in P.novos and os.path.exists(cam):
                os.remove(cam)
        print('DESFEITO pelo backup — não gravou até o fim ou a conta não fechou:')
        for f in falhas[:20]:
            print('  - ' + f)
        return 4
    print('Gravado e conferido: %d arquivos; a conta fecha.' % len(gravados))
    for cam in gravados:
        print('  %s  %s' % (h(ler(cam)), os.path.relpath(cam, a.pasta)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
