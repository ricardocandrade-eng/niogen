#!/usr/bin/env python3
# NIOGEN | n8n/deploy_resumo_diario.py | 09/11/2026 — Claude Code (rodada noturna, item 5 · onda 3.2 fase 1)
# Workflow n8n "resumo_diario": às 08h (seg–sáb, fuso de São Paulo) chama resumo_diario() no Supabase Nio (o resumo de ontem, o
# mesmo texto do cartão "Resumo de ontem" do Painel). O nó de ENVIO existe mas está DESLIGADO e marcado "aguarda canal": o canal é
# a mesma decisão do alarme da Mari (template WhatsApp × bot do Telegram). O workflow nasce INATIVO; este script não liga nada.
#
# Credenciais (só IDs/nomes, nunca valores): "Supabase Nio (service role)". Chave da API do n8n: N8N_API_KEY_NIO.
#
# Uso:
#   python n8n/deploy_resumo_diario.py build      # gera n8n/resumo_diario.json (export, sem segredos)
#   python n8n/deploy_resumo_diario.py criar      # cria o workflow INATIVO; falha se o nome já existe
#   python n8n/deploy_resumo_diario.py exportar   # baixa o estado atual e grava o export sanitizado
# Não há "ativar" aqui de propósito: ligar = decisão do Ricardo junto com o canal.

import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402  (api, ids, checagem de segredo)

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'resumo_diario.json')
WF_NOME = 'resumo_diario'
ID_KEY = 'resumo_diario_workflow_id'


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/resumo_diario/{name}'))}
        n.update(extra)
        nodes.append(n)

    add('1 · 08h seg–sáb', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'cronExpression', 'expression': '0 8 * * 1-6'}]}}, 0, 0,
        notes='Feriados ainda não entram (pendência 16): no feriado o resumo sairia igual.')
    add('2 · Supabase resumo de ontem', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/resumo_diario',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify({}) }}',   # sem p_dia = ontem (fuso SP)
        'options': {'timeout': 20000}}, 240, 0, credentials=sb_cred, retryOnFail=True, maxTries=2, waitBetweenTries=5000)
    add('3 · Enviar (AGUARDA CANAL)', 'n8n-nodes-base.noOp', 1, {}, 480, 0, disabled=True,
        notes='DESLIGADO — aguarda canal: template WhatsApp × bot do Telegram (cartão "Canal do alarme da Mari"). '
              'Quando decidir, troca este nó pelo envio ao Ricardo usando {{$json.texto}} e liga o workflow.',
        notesInFlow=True)

    ligacoes = [('1 · 08h seg–sáb', '2 · Supabase resumo de ontem'), ('2 · Supabase resumo de ontem', '3 · Enviar (AGUARDA CANAL)')]
    conns = {}
    for o, d in ligacoes:
        conns.setdefault(o, {'main': [[]]})['main'][0].append({'node': d, 'type': 'main', 'index': 0})
    settings = {'executionOrder': 'v1', 'saveDataErrorExecution': 'all', 'saveDataSuccessExecution': 'all',
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


def cmd_exportar():
    ids = dm.ler_ids()
    salvar(dm.api('GET', f'/workflows/{ids[ID_KEY]}'))


if __name__ == '__main__':
    acoes = {'build': cmd_build, 'criar': cmd_criar, 'exportar': cmd_exportar}
    if len(sys.argv) < 2 or sys.argv[1] not in acoes:
        raise SystemExit(__doc__ or 'uso: build | criar | exportar')
    acoes[sys.argv[1]]()
