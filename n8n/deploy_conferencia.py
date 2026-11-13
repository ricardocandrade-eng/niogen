#!/usr/bin/env python3
# NIOGEN | n8n/deploy_conferencia.py | 13/11/2026 — Claude Code (etapa 6a do plano do sistema fechado)
# Workflow n8n "conferencia_diaria": todo dia às 7h10 (hora de Brasília) chama conferencia_rodar() no Supabase Nio, que grava
# o retrato "a conta fecha" do dia (migration 0175). Uma chamada, uma gravação por dia. Não fala com cliente, não toca a Mari.
# Vermelho na conferência NÃO é erro do fluxo: aparece no Painel e na Live › Conferir. O fluxo só falha se o banco não responder.
#
# Credenciais (só nomes/IDs): "Supabase Nio (service role)" e "MARI_TESTE_SECRET" (rota de teste).
# Uso: python n8n/deploy_conferencia.py build | criar | estrutura | ativar | desativar | exportar | rodar

import datetime
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'conferencia_diaria.json')
WF_NOME = 'conferencia_diaria'
ID_KEY = 'conferencia_diaria_workflow_id'
ROTA_TESTE = 'niogen-conferencia-teste'

JS_RESUMO = r"""
// Só o resumo (sem nomes de cliente): o detalhe fica em conferencias_diarias.
const r = $input.first().json || {};
const itens = Array.isArray(r.itens) ? r.itens : [];
return [{ json: { ok: true, dia: r.dia, verde: r.verde, falhas: r.falhas, atencoes: r.atencoes, dias_verdes_seguidos: r.dias_verdes_seguidos,
                  nao_ok: itens.filter((i) => i.nivel === 'falha' || i.nivel === 'atencao').map((i) => i.codigo + ':' + i.nivel + ':' + i.n) } }];
"""


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    te_cred = {'httpHeaderAuth': {'id': cred.get('teste', ''), 'name': dm.CRED_TESTE}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/conferencia_diaria/{name}'))}
        n.update(extra)
        nodes.append(n)

    add('1 · todo dia 7h10', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'cronExpression', 'expression': '10 7 * * *'}]}}, 0, 0)
    add('1t · rota de teste', 'n8n-nodes-base.webhook', 2,
        {'httpMethod': 'POST', 'path': ROTA_TESTE, 'authentication': 'headerAuth', 'responseMode': 'lastNode', 'options': {}},
        0, 200, credentials=te_cred, webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/conferencia_diaria/webhook')))
    add('2 · Supabase conferir', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/conferencia_rodar',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': "={{ JSON.stringify({ p_origem: 'rotina' }) }}",
        'options': {'timeout': 60000}}, 240, 100, credentials=sb_cred, retryOnFail=True, maxTries=3, waitBetweenTries=5000)
    add('3 · Resumo', 'n8n-nodes-base.code', 2, {'jsCode': JS_RESUMO.strip()}, 480, 100)
    conns = {'1 · todo dia 7h10': {'main': [[{'node': '2 · Supabase conferir', 'type': 'main', 'index': 0}]]},
             '1t · rota de teste': {'main': [[{'node': '2 · Supabase conferir', 'type': 'main', 'index': 0}]]},
             '2 · Supabase conferir': {'main': [[{'node': '3 · Resumo', 'type': 'main', 'index': 0}]]}}
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
    acoes = {'build': cmd_build, 'criar': cmd_criar, 'estrutura': cmd_estrutura, 'ativar': cmd_ativar,
             'desativar': lambda: cmd_ativar(False), 'exportar': cmd_exportar, 'rodar': cmd_rodar}
    if len(sys.argv) < 2 or sys.argv[1] not in acoes:
        raise SystemExit('uso: ' + ' | '.join(acoes))
    acoes[sys.argv[1]]()
