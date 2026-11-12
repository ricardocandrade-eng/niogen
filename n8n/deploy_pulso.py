#!/usr/bin/env python3
# NIOGEN | n8n/deploy_pulso.py | 12/11/2026 — Claude Code (docs/Prompt_pulso_live_121126_1035.md)
# Workflow n8n "pulso_coleta": a cada 5 min lê na API do n8n SÓ os workflows listados em pulso_batimentos.workflow_id (RPC
# pulso_fluxos — nada da Vero), pega de cada um: ligado/desligado, se guarda execução com sucesso, a última execução ok e a última
# com erro, manda tudo numa chamada (pulso_bater_lote, migration 0144) e depois pulso_registrar() abre/fecha os incidentes.
# Não altera nenhum workflow existente. Não fala com cliente. Não guarda execução com sucesso (só erro), para não encher o n8n.
#
# Credenciais (só nomes/IDs): "Supabase Nio (service role)" e "n8n API Nio (pulso)" (httpHeaderAuth X-N8N-API-KEY; o valor sai da
# variável de usuário N8N_API_KEY_NIO direto para o n8n — nunca impresso nem gravado em arquivo).
#
# Uso:
#   python n8n/deploy_pulso.py credencial  # cria "n8n API Nio (pulso)" no n8n (uma vez)
#   python n8n/deploy_pulso.py build       # gera n8n/pulso_coleta.json (export, sem segredos)
#   python n8n/deploy_pulso.py criar       # cria o workflow INATIVO
#   python n8n/deploy_pulso.py estrutura   # PUT do workflow inteiro, backup antes
#   python n8n/deploy_pulso.py ativar | desativar | exportar
#   python n8n/deploy_pulso.py rodar       # roda agora pela rota de teste e mostra o resultado

import datetime
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'pulso_coleta.json')
WF_NOME = 'pulso_coleta'
ID_KEY = 'pulso_coleta_workflow_id'
CRED_N8N = 'n8n API Nio (pulso)'
ROTA_TESTE = 'niogen-pulso-teste'

JS_MONTAR = r"""
// Um item por fluxo, na mesma ordem do "2 · Supabase fluxos" (os nós 3–5 rodam item a item).
const fl = $('2 · Supabase fluxos').all();
const wf = $('3 · n8n workflow').all();
const ok = $('4 · n8n último ok').all();
const er = $('5 · n8n último erro').all();
const itens = fl.map((f, i) => {
  const w = (wf[i] || {}).json || {};
  const o = (((ok[i] || {}).json || {}).data || [])[0];
  const e = (((er[i] || {}).json || {}).data || [])[0];
  const lido = typeof w.active === 'boolean';
  return {
    fluxo: f.json.fluxo,
    ativo: lido ? w.active : null,
    salva_ok: lido ? ((w.settings || {}).saveDataSuccessExecution || 'all') !== 'none' : null,
    ok_em: o ? (o.stoppedAt || o.startedAt) : null,
    erro_em: e ? (e.stoppedAt || e.startedAt) : null,
    erro_id: e ? String(e.id) : null,
    erro: e ? 'execução ' + e.id + ' com erro' : (lido ? null : 'API do n8n não respondeu para este fluxo'),
  };
});
return [{ json: { itens } }];
"""


def build(ids):
    cred = ids.get('credenciais', {})
    if not cred.get('n8n_api'):
        raise SystemExit(f'credencial "{CRED_N8N}" ausente em mari_ids.json — rode "credencial" antes.')
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    n8_cred = {'httpHeaderAuth': {'id': cred['n8n_api'], 'name': CRED_N8N}}
    te_cred = {'httpHeaderAuth': {'id': cred.get('teste', ''), 'name': dm.CRED_TESTE}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/pulso_coleta/{name}'))}
        n.update(extra)
        nodes.append(n)

    def sb(name, rpc, body, x, y):
        add(name, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/{rpc}',
            'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
            'sendBody': True, 'specifyBody': 'json', 'jsonBody': body, 'options': {'timeout': 20000}},
            x, y, credentials=sb_cred, retryOnFail=True, maxTries=2, waitBetweenTries=3000)

    def n8(name, path, x, y):
        add(name, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'GET', 'url': f'={dm.N8N}/api/v1{path}',
            'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
            'options': {'timeout': 20000, 'response': {'response': {'neverError': True}}}},
            x, y, credentials=n8_cred, onError='continueRegularOutput')

    add('1 · a cada 5 min', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'minutes', 'minutesInterval': 5}]}}, 0, 0)
    add('1t · rota de teste', 'n8n-nodes-base.webhook', 2,
        {'httpMethod': 'POST', 'path': ROTA_TESTE, 'authentication': 'headerAuth', 'responseMode': 'lastNode', 'options': {}},
        0, 200, credentials=te_cred, webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/pulso_coleta/webhook')))
    sb('2 · Supabase fluxos', 'pulso_fluxos', '={{ JSON.stringify({}) }}', 240, 100)
    WID = "{{ $('2 · Supabase fluxos').item.json.workflow_id }}"
    n8('3 · n8n workflow', f'/workflows/{WID}', 480, 100)
    n8('4 · n8n último ok', f'/executions?workflowId={WID}&status=success&limit=1', 720, 100)
    n8('5 · n8n último erro', f'/executions?workflowId={WID}&status=error&limit=1', 960, 100)
    add('6 · Montar batimentos', 'n8n-nodes-base.code', 2, {'jsCode': JS_MONTAR.strip()}, 1200, 100)
    sb('7 · Supabase bater', 'pulso_bater_lote', '={{ JSON.stringify({ p_itens: $json.itens }) }}', 1440, 100)
    sb('8 · Supabase registrar', 'pulso_registrar', '={{ JSON.stringify({}) }}', 1680, 100)

    seq = ['2 · Supabase fluxos', '3 · n8n workflow', '4 · n8n último ok', '5 · n8n último erro', '6 · Montar batimentos',
           '7 · Supabase bater', '8 · Supabase registrar']
    conns = {'1 · a cada 5 min': {'main': [[{'node': seq[0], 'type': 'main', 'index': 0}]]},
             '1t · rota de teste': {'main': [[{'node': seq[0], 'type': 'main', 'index': 0}]]}}
    for a, b in zip(seq, seq[1:]):
        conns[a] = {'main': [[{'node': b, 'type': 'main', 'index': 0}]]}
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


def cmd_credencial():
    ids = dm.ler_ids()
    cred = ids.setdefault('credenciais', {})
    if cred.get('n8n_api'):
        print(f'já existe: {CRED_N8N} ({cred["n8n_api"]}) — nada a fazer')
        return
    chave = dm.env_usuario('N8N_API_KEY_NIO')
    if not chave:
        raise SystemExit('N8N_API_KEY_NIO ausente — nada foi criado.')
    r = dm.api('POST', '/credentials', {'name': CRED_N8N, 'type': 'httpHeaderAuth',
                                        'data': {'name': 'X-N8N-API-KEY', 'value': chave}})
    del chave
    cred['n8n_api'] = r['id']
    dm.gravar_ids(ids)
    print(f'criada: {CRED_N8N} ({r["id"]}) — valor lido de N8N_API_KEY_NIO, não exibido')


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
    r = dm.api('POST', '/workflows', wf)
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


def cmd_ativar(ligar=True):
    ids = dm.ler_ids()
    dm.api('POST', f'/workflows/{ids[ID_KEY]}/{"activate" if ligar else "deactivate"}')
    print('active:', dm.api('GET', f'/workflows/{ids[ID_KEY]}').get('active'))
    cmd_exportar()


def cmd_exportar():
    salvar(dm.api('GET', f'/workflows/{dm.ler_ids()[ID_KEY]}'))


def cmd_rodar():
    import urllib.request
    import urllib.error
    segredo = dm.env_usuario('MARI_TESTE_SECRET')
    if not segredo:
        raise SystemExit('MARI_TESTE_SECRET ausente.')
    req = urllib.request.Request(f'{dm.N8N}/webhook/{ROTA_TESTE}', data=b'{}', method='POST',
                                 headers={dm.HEADER_TESTE: segredo, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            print(json.dumps(json.loads(r.read().decode() or 'null'), ensure_ascii=False, indent=1))
    except urllib.error.HTTPError as e:
        raise SystemExit(f'HTTP {e.code}: {e.read().decode()[:800]}')


if __name__ == '__main__':
    acoes = {'credencial': cmd_credencial, 'build': cmd_build, 'criar': cmd_criar, 'estrutura': cmd_estrutura,
             'ativar': cmd_ativar, 'desativar': lambda: cmd_ativar(False), 'exportar': cmd_exportar, 'rodar': cmd_rodar}
    if len(sys.argv) < 2 or sys.argv[1] not in acoes:
        raise SystemExit('uso: ' + ' | '.join(acoes))
    acoes[sys.argv[1]]()
