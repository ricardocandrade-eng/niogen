#!/usr/bin/env python3
# NIOGEN | n8n/deploy_resumo_diario.py | 09/11/2026 — Claude Code (rodada noturna, item 5 · onda 3.2 fase 1)
# Workflow n8n "resumo_diario": às 08h (seg–sáb, fuso de São Paulo) chama resumo_diario_whatsapp() no Supabase Nio (o resumo de
# ontem, o mesmo do cartão "Resumo de ontem" do Painel, em 6 campos) e manda o template `resumo_diario_interno` da WABA Nio para o
# celular do Ricardo (config_regras.resumo_destino_whatsapp). Canal decidido pelo Ricardo em 09/11: "Pode ser template de WhatsApp".
# O workflow nasce INATIVO; `ativar` só depois do template APPROVED (python n8n/waba_template_resumo.py --status).
#
# Credenciais (só IDs/nomes, nunca valores): "Supabase Nio (service role)", "WABA Nio (Nio_API)". Chave da API do n8n: N8N_API_KEY_NIO.
#
# Uso:
#   python n8n/deploy_resumo_diario.py build      # gera n8n/resumo_diario.json (export, sem segredos)
#   python n8n/deploy_resumo_diario.py criar      # cria o workflow INATIVO; falha se o nome já existe
#   python n8n/deploy_resumo_diario.py estrutura  # PUT do workflow inteiro, backup antes (mantém o active atual)
#   python n8n/deploy_resumo_diario.py ativar     # liga (recusa se o template não estiver APPROVED)
#   python n8n/deploy_resumo_diario.py exportar   # baixa o estado atual e grava o export sanitizado

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
    wa_cred = {'httpHeaderAuth': {'id': cred.get('waba', ''), 'name': dm.CRED_WABA}}
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
        'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/resumo_diario_whatsapp',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify({}) }}',   # sem p_dia = ontem (fuso SP)
        'options': {'timeout': 20000}}, 240, 0, credentials=sb_cred, retryOnFail=True, maxTries=2, waitBetweenTries=5000)
    corpo = ("={{ JSON.stringify({ messaging_product: 'whatsapp', to: $json.destino, type: 'template', template: { "
             "name: $json.template, language: { code: $json.idioma }, components: [{ type: 'body', "
             "parameters: $json.params.map(t => ({ type: 'text', text: t })) }] } }) }}")
    add('3 · WABA enviar ao Ricardo', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': 'https://graph.facebook.com/v21.0/1342993658907403/messages',
        'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': corpo,
        'options': {'timeout': 20000}}, 480, 0, credentials=wa_cred,
        notes='Template resumo_diario_interno (UTILITY, sem marca) da WABA Nio para o celular do Ricardo. Nunca para cliente.',
        notesInFlow=True)

    ligacoes = [('1 · 08h seg–sáb', '2 · Supabase resumo de ontem'), ('2 · Supabase resumo de ontem', '3 · WABA enviar ao Ricardo')]
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


def cmd_estrutura():
    ids = dm.ler_ids()
    atual = dm.api('GET', f'/workflows/{ids[ID_KEY]}')
    import datetime
    os.makedirs(os.path.join(AQUI, 'backups'), exist_ok=True)
    bk = os.path.join(AQUI, 'backups', f"{WF_NOME}_{datetime.datetime.now():%d%m%y_%H%M%S}.json")
    with open(bk, 'w', encoding='utf-8') as f:
        json.dump(atual, f, ensure_ascii=False, indent=2)
    print('backup:', os.path.relpath(bk, REPO))
    dm.put(ids[ID_KEY], build(ids))
    print('ok (active =', dm.api('GET', f'/workflows/{ids[ID_KEY]}').get('active'), ')')
    cmd_exportar()


def cmd_ativar():
    import waba_templates_lote_c as w
    r = w.graph('GET', f'/{w.WABA_NIO}/message_templates?name=resumo_diario_interno&fields=name,status')
    st = [m.get('status') for m in r.get('data', [])]
    if 'APPROVED' not in st:
        raise SystemExit(f'template resumo_diario_interno ainda não aprovado ({st}) — nada ligado.')
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
        raise SystemExit(__doc__ or 'uso: build | criar | exportar')
    acoes[sys.argv[1]]()
