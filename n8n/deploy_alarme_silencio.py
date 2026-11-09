#!/usr/bin/env python3
# NIOGEN | n8n/deploy_alarme_silencio.py | 09/11/2026 — Claude Code (docs/Prompt_mari_alarme_silencio_091126_0650.md · Onda 1.2, Parte 2)
# Workflow n8n "mari_alarme_silencio": a cada 1 min chama mari_alarme_proximos() no Supabase Nio (migration 0081) e, para cada linha
# (1º aviso ou lembrete), manda o template `alerta_mari_silencio` da WABA Nio para o celular do Ricardo (config_regras.resumo_destino_whatsapp).
# Falha de envio vai para mari_alarme_erro e não trava o laço. Só lê o banco: não mexe no mari_principal nem fala com cliente.
# O workflow nasce INATIVO; `ativar` só liga com o template APPROVED (python n8n/waba_template_resumo.py --template alerta_mari_silencio --status).
# Desligar sem mexer no n8n: config_regras.alarme_silencio_ligado = false.
#
# Credenciais (só IDs/nomes): "Supabase Nio (service role)", "WABA Nio (Nio_API)". Chave da API do n8n: N8N_API_KEY_NIO.
#
# Uso:
#   python n8n/deploy_alarme_silencio.py build      # gera n8n/mari_alarme_silencio.json (export, sem segredos)
#   python n8n/deploy_alarme_silencio.py criar      # cria o workflow INATIVO; falha se o nome já existe
#   python n8n/deploy_alarme_silencio.py estrutura  # PUT do workflow inteiro, backup antes (mantém o active atual)
#   python n8n/deploy_alarme_silencio.py ativar     # liga (recusa se o template não estiver APPROVED)
#   python n8n/deploy_alarme_silencio.py desativar  # desliga
#   python n8n/deploy_alarme_silencio.py exportar   # baixa o estado atual e grava o export sanitizado

import datetime
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'mari_alarme_silencio.json')
WF_NOME = 'mari_alarme_silencio'
ID_KEY = 'alarme_silencio_workflow_id'
TEMPLATE = 'alerta_mari_silencio'


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    wa_cred = {'httpHeaderAuth': {'id': cred.get('waba', ''), 'name': dm.CRED_WABA}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/mari_alarme_silencio/{name}'))}
        n.update(extra)
        nodes.append(n)

    add('1 · A cada 1 min', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'minutes', 'minutesInterval': 1}]}}, 0, 0)
    # Devolve uma lista (um item por aviso); lista vazia = nenhum item = nada mais roda.
    add('2 · Supabase alarmes a mandar', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/mari_alarme_proximos',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify({}) }}',
        'options': {'timeout': 20000}}, 240, 0, credentials=sb_cred)
    corpo = ("={{ JSON.stringify({ messaging_product: 'whatsapp', to: $json.destino, type: 'template', template: { "
             "name: $json.template, language: { code: $json.idioma }, components: [{ type: 'body', "
             "parameters: $json.params.map(t => ({ type: 'text', text: t })) }] } }) }}")
    add('3 · WABA enviar ao Ricardo', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': 'https://graph.facebook.com/v21.0/1342993658907403/messages',
        'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': corpo,
        'options': {'timeout': 20000}}, 480, 0, credentials=wa_cred, onError='continueRegularOutput',
        notes='Template alerta_mari_silencio (sem marca) só para o Ricardo. Nunca para cliente.', notesInFlow=True)
    add('4 · Supabase registrar erro', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/mari_alarme_erro',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json',
        'jsonBody': ("={{ JSON.stringify({ p_id: $('2 · Supabase alarmes a mandar').item.json.id, "
                     "p_erro: $json.error ? JSON.stringify($json.error).slice(0, 400) : null }) }}"),
        'options': {'timeout': 20000}}, 720, 0, credentials=sb_cred, onError='continueRegularOutput')

    ligacoes = [('1 · A cada 1 min', '2 · Supabase alarmes a mandar'), ('2 · Supabase alarmes a mandar', '3 · WABA enviar ao Ricardo'),
                ('3 · WABA enviar ao Ricardo', '4 · Supabase registrar erro')]
    conns = {}
    for o, d in ligacoes:
        conns.setdefault(o, {'main': [[]]})['main'][0].append({'node': d, 'type': 'main', 'index': 0})
    # 1.440 execuções/dia: sucesso não fica salvo; erro fica (e vai para o Error Trigger do mari_principal).
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
    if ligar:
        import waba_templates_lote_c as w
        r = w.graph('GET', f'/{w.WABA_NIO}/message_templates?name={TEMPLATE}&fields=name,status')
        st = [m.get('status') for m in r.get('data', [])]
        if 'APPROVED' not in st:
            raise SystemExit(f'template {TEMPLATE} ainda não aprovado ({st}) — nada ligado.')
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
