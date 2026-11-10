#!/usr/bin/env python3
# NIOGEN | n8n/deploy_waba_qualidade.py | 10/11/2026 — Claude Code (prompt três telas + travas + sem teto, item C)
# Workflow n8n "waba_qualidade": 2x por dia (8h e 14h, fuso de São Paulo) lê na Graph API o quality_rating do número da WABA Nio
# (1342993658907403) e grava uma linha em public.waba_qualidade (migration 0102). O Painel do NIOGEN mostra um alarme quando a
# última leitura não é GREEN (ou quando não há leitura há mais de 2 dias). É alarme, não trava: nada deixa de sair por isso.
# Por quê: o teto 2/dia · 15/mês acabou (Ricardo, 10/11 10h29) — a qualidade do número passa a ser vigiada.
#
# Credenciais (só IDs/nomes, nunca valores): "Supabase Nio (service role)", "WABA Nio (Nio_API)". Chave da API do n8n: N8N_API_KEY_NIO.
#
# Uso:
#   python n8n/deploy_waba_qualidade.py build      # gera n8n/waba_qualidade.json (export, sem segredos)
#   python n8n/deploy_waba_qualidade.py criar      # cria o workflow (inativo); falha se o nome já existe
#   python n8n/deploy_waba_qualidade.py estrutura  # PUT do workflow inteiro, backup antes (mantém o active atual)
#   python n8n/deploy_waba_qualidade.py ativar     # liga
#   python n8n/deploy_waba_qualidade.py exportar   # baixa o estado atual e grava o export sanitizado

import datetime
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402  (api, ids, checagem de segredo)

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'waba_qualidade.json')
WF_NOME = 'waba_qualidade'
ID_KEY = 'waba_qualidade_workflow_id'
PHONE_ID = '1342993658907403'   # número da WABA Nio (o mesmo do resumo_diario)


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    wa_cred = {'httpHeaderAuth': {'id': cred.get('waba', ''), 'name': dm.CRED_WABA}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/waba_qualidade/{name}'))}
        n.update(extra)
        nodes.append(n)

    add('1 · 8h e 14h', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'cronExpression', 'expression': '0 8,14 * * *'}]}}, 0, 0)
    add('2 · Graph quality_rating', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'GET',
        'url': f'https://graph.facebook.com/v21.0/{PHONE_ID}?fields=quality_rating,messaging_limit_tier,status,name_status',
        'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
        'options': {'timeout': 20000}}, 240, 0, credentials=wa_cred, retryOnFail=True, maxTries=2, waitBetweenTries=5000)
    corpo = ("={{ JSON.stringify({ phone_number_id: '" + PHONE_ID + "', "
             "quality_rating: $json.quality_rating || null, messaging_limit_tier: $json.messaging_limit_tier || null, "
             "status: $json.status || null, bruto: $json }) }}")
    add('3 · Supabase gravar leitura', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{dm.SB}/rest/v1/waba_qualidade',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendHeaders': True, 'headerParameters': {'parameters': [{'name': 'Prefer', 'value': 'return=minimal'}]},
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': corpo,
        'options': {'timeout': 20000}}, 480, 0, credentials=sb_cred,
        notes='Só grava a leitura. O alarme (não GREEN) aparece no Painel do NIOGEN; não trava envio.', notesInFlow=True)

    ligacoes = [('1 · 8h e 14h', '2 · Graph quality_rating'), ('2 · Graph quality_rating', '3 · Supabase gravar leitura')]
    conns = {}
    for o, d in ligacoes:
        conns.setdefault(o, {'main': [[]]})['main'][0].append({'node': d, 'type': 'main', 'index': 0})
    settings = {'executionOrder': 'v1', 'saveDataErrorExecution': 'all', 'saveDataSuccessExecution': 'none',
                'saveManualExecutions': True, 'timezone': 'America/Sao_Paulo'}
    if ids.get('workflow_id'):
        settings['errorWorkflow'] = ids['workflow_id']
    return {'name': WF_NOME, 'nodes': nodes, 'connections': conns, 'settings': settings}


def salvar(wf):
    dm.checar_sem_segredo(wf)
    keep = {k: wf[k] for k in ('name', 'nodes', 'connections', 'settings') if k in wf}
    keep['active'] = wf.get('active', False)
    with open(EXPORT, 'w', encoding='utf-8') as f:
        json.dump(keep, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f'export: {os.path.relpath(EXPORT, REPO)} ({len(keep["nodes"])} nós, active={keep["active"]})')


def cmd_build():
    salvar(build(dm.ler_ids()))


def cmd_criar():
    ids = dm.ler_ids()
    if ids.get(ID_KEY):
        raise SystemExit(f'já existe {ID_KEY} {ids[ID_KEY]} — nada foi criado.')
    existentes = dm.api('GET', '/workflows?limit=250').get('data', [])
    if any(w.get('name') == WF_NOME for w in existentes):
        raise SystemExit(f'já existe um workflow chamado {WF_NOME} no n8n — nada foi criado.')
    wf = build(ids)
    dm.checar_sem_segredo(wf)
    r = dm.api('POST', '/workflows', wf)   # a API cria sempre inativo
    ids[ID_KEY] = r['id']
    dm.gravar_ids(ids)
    print(f'criado: {WF_NOME} ({r["id"]}), active={r.get("active")}')
    cmd_exportar()


def cmd_estrutura():
    ids = dm.ler_ids()
    atual = dm.api('GET', f'/workflows/{ids[ID_KEY]}')
    os.makedirs(os.path.join(AQUI, 'backups'), exist_ok=True)
    bk = os.path.join(AQUI, 'backups', f"{WF_NOME}_{datetime.datetime.now():%d%m%y_%H%M%S}.json")
    with open(bk, 'w', encoding='utf-8') as f:
        json.dump(atual, f, ensure_ascii=False, indent=2)
    print('backup:', os.path.relpath(bk, REPO))
    dm.put(ids[ID_KEY], build(ids))
    print('ok (active =', dm.api('GET', f'/workflows/{ids[ID_KEY]}').get('active'), ')')
    cmd_exportar()


def cmd_ativar():
    ids = dm.ler_ids()
    dm.api('POST', f'/workflows/{ids[ID_KEY]}/activate')
    print('ligado:', dm.api('GET', f'/workflows/{ids[ID_KEY]}').get('active'))
    cmd_exportar()


def cmd_exportar():
    ids = dm.ler_ids()
    salvar(dm.api('GET', f'/workflows/{ids[ID_KEY]}'))


if __name__ == '__main__':
    acoes = {'build': cmd_build, 'criar': cmd_criar, 'estrutura': cmd_estrutura, 'ativar': cmd_ativar, 'exportar': cmd_exportar}
    if len(sys.argv) < 2 or sys.argv[1] not in acoes:
        raise SystemExit('uso: build | criar | estrutura | ativar | exportar')
    acoes[sys.argv[1]]()
