#!/usr/bin/env python3
# NIOGEN | n8n/deploy_push.py | 15/11/2026 13:55 — Claude Code (Opus 5.5) · NIOGEN no celular, item 5 (Web Push)
# Workflow n8n "push_live": a cada 2 min pega a chave PÚBLICA no niogen-push (GET /chave), chama push_pendentes() no Supabase Nio
# (migration 0215: só os gatilhos do Live — janela de 24 h, objeção, documento, fatura, M-10, Mari parada; um por gatilho por
# cliente por dia), manda o lote ao niogen-push (POST /enviar, rede interna renata_web) e grava o retorno em push_resultado()
# (410/404 desliga o aparelho). Lista vazia = nenhum item = nada mais roda. Alerta interno vale a qualquer hora.
# Desligar sem mexer no n8n: config_regras.push.ligado = false.
#
# Credenciais (só nomes/IDs): "Supabase Nio (service role)". O niogen-push não tem credencial: não tem porta publicada.
# Chaves VAPID: só em /opt/niogen/push/.env na VPS (push/instalar.sh) — nunca aqui.
#
# Uso:
#   python n8n/deploy_push.py build      # gera n8n/push_live.json (export, sem segredos)
#   python n8n/deploy_push.py criar      # cria o workflow INATIVO; imprime o SQL do pulso_batimentos.workflow_id
#   python n8n/deploy_push.py estrutura  # PUT do workflow inteiro, backup antes (mantém o active atual)
#   python n8n/deploy_push.py ativar     # liga (recusa se o niogen-push não responder pelo n8n — rodar instalar.sh antes)
#   python n8n/deploy_push.py desativar  # desliga
#   python n8n/deploy_push.py exportar   # baixa o estado atual e grava o export sanitizado

import datetime
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'push_live.json')
WF_NOME = 'push_live'
ID_KEY = 'push_live_workflow_id'
PUSH = 'http://niogen-push:8096'


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/push_live/{name}'))}
        n.update(extra)
        nodes.append(n)

    add('1 · A cada 2 min', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'minutes', 'minutesInterval': 2}]}}, 0, 0)
    add('2 · Chave pública (niogen-push)', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'GET', 'url': f'{PUSH}/chave', 'options': {'timeout': 5000}}, 240, 0, onError='continueRegularOutput',
        notes='Só a chave PÚBLICA (vai para config_regras.push). A privada nunca sai da VPS.', notesInFlow=True)
    # Devolve uma lista (um item por aviso); lista vazia = nenhum item = nada mais roda.
    add('3 · Supabase avisos a mandar', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/push_pendentes',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify({ p_vapid_publica: $json.publica || null }) }}',
        'options': {'timeout': 20000}}, 480, 0, credentials=sb_cred)
    add('4 · Juntar o lote', 'n8n-nodes-base.code', 2, {
        'mode': 'runOnceForAllItems',
        'jsCode': "const itens = $input.all().map((i) => i.json).filter((j) => j && j.id && j.endpoint);\n"
                  "return itens.length ? [{ json: { itens } }] : [];"}, 720, 0)
    add('5 · Enviar (niogen-push)', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{PUSH}/enviar', 'sendBody': True, 'specifyBody': 'json',
        'jsonBody': '={{ JSON.stringify({ itens: $json.itens }) }}', 'options': {'timeout': 120000}}, 960, 0)
    add('6 · Supabase resultado', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/push_resultado',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify({ p_itens: $json.itens || [] }) }}',
        'options': {'timeout': 20000}}, 1200, 0, credentials=sb_cred)

    ordem = ['1 · A cada 2 min', '2 · Chave pública (niogen-push)', '3 · Supabase avisos a mandar', '4 · Juntar o lote',
             '5 · Enviar (niogen-push)', '6 · Supabase resultado']
    conns = {}
    for o, d in zip(ordem, ordem[1:]):
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
    if any(w.get('name') == WF_NOME for w in dm.api('GET', '/workflows?limit=250').get('data', [])):
        raise SystemExit(f'já existe um workflow chamado {WF_NOME} no n8n — nada foi criado.')
    wf = build(ids)
    dm.checar_sem_segredo(wf)
    r = dm.api('POST', '/workflows', wf)   # a API cria sempre inativo
    ids[ID_KEY] = r['id']
    dm.gravar_ids(ids)
    print(f'criado: {WF_NOME} ({r["id"]}), active={r.get("active")}')
    print(f"Pulso › Fluxos: update public.pulso_batimentos set workflow_id = '{r['id']}' where fluxo = 'push_live';")
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


def cmd_ativar(ligar=True):
    ids = dm.ler_ids()
    dm.api('POST', f"/workflows/{ids[ID_KEY]}/{'activate' if ligar else 'deactivate'}")
    print('active:', dm.api('GET', f'/workflows/{ids[ID_KEY]}').get('active'))
    cmd_exportar()


def cmd_exportar():
    ids = dm.ler_ids()
    salvar(dm.api('GET', f'/workflows/{ids[ID_KEY]}'))


if __name__ == '__main__':
    acoes = {'build': cmd_build, 'criar': cmd_criar, 'estrutura': cmd_estrutura, 'ativar': cmd_ativar,
             'desativar': lambda: cmd_ativar(False), 'exportar': cmd_exportar}
    if len(sys.argv) < 2 or sys.argv[1] not in acoes:
        raise SystemExit('uso: build | criar | estrutura | ativar | desativar | exportar')
    acoes[sys.argv[1]]()
