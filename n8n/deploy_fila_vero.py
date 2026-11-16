#!/usr/bin/env python3
# NIOGEN | n8n/deploy_fila_vero.py | 16/11/2026 — Claude Code (prompt docs/Prompt_fila_vero_piloto100_161126_1640.md)
# Workflow n8n "fila_vero_webhook": recebe o webhook da WABA do número do disparo (974428375341104, +55 32 2888-0150;
# app NIOGEN inscrito com override de callback — regra 5: por WABA, nunca no nível do app) e passa o "value" de cada
# mudança "messages" (status de entrega e respostas) para a RPC public.fila_vero_webhook (migration 0239), que atualiza
# a fila_vero: entregue/lido, falha (131050 → opt_out) e "Não tenho interesse"/SAIR → opt_out. Nada do texto fica no n8n.
#
# Uso:
#   python n8n/deploy_fila_vero.py criar        # cria e ativa o workflow (precisa estar no ar para a verificação da Meta)
#   python n8n/deploy_fila_vero.py estrutura    # PUT do workflow inteiro, backup antes
#   python n8n/deploy_fila_vero.py inscrever    # inscreve o app NIOGEN na WABA do disparo com override para este workflow
#   python n8n/deploy_fila_vero.py conferir     # lista os apps inscritos na WABA do disparo
#   python n8n/deploy_fila_vero.py simular      # POST de um status falso (wamid de teste: não acha linha, não grava nada)
#   python n8n/deploy_fila_vero.py exportar     # baixa o estado atual e grava o export sanitizado
import datetime
import json
import os
import secrets
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm               # noqa: E402
import deploy_meta_referral as mr      # noqa: E402

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'fila_vero_webhook.json')
WF_NOME = 'fila_vero_webhook'
ID_KEY = 'fila_vero_webhook_workflow_id'
ROTA = 'niogen-fila-vero-webhook'
CALLBACK = f'{dm.N8N}/webhook/{ROTA}'
WABA_FILA = '974428375341104'
PHONE_FILA = '1124589070738034'

EXTRAIR = r"""
// Só as mudanças "messages" do número do disparo. Vai só o necessário: status (id, status, errors) e mensagens
// (from, tipo, texto do botão/texto). Nome do perfil do cliente não segue.
const corpo = $input.first().json.body || {};
const saida = [];
for (const e of corpo.entry || []) {
  for (const c of e.changes || []) {
    const v = c.value || {};
    if (c.field !== 'messages') continue;
    if (String(v.metadata?.phone_number_id || '') !== '%PHONE%') continue;
    const statuses = (v.statuses || []).map((s) => ({ id: s.id, status: s.status, errors: s.errors || [] }));
    const messages = (v.messages || []).map((m) => ({ from: m.from, type: m.type, button: m.button,
      interactive: m.interactive, text: m.text }));
    if (!statuses.length && !messages.length) continue;
    saida.push({ json: { value: { metadata: { phone_number_id: v.metadata.phone_number_id }, statuses, messages } } });
  }
}
return saida;
""".replace('%PHONE%', PHONE_FILA)


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/{WF_NOME}/{name}'))}
        n.update(extra)
        nodes.append(n)

    add('1g · Verificação Meta (GET)', 'n8n-nodes-base.webhook', 2, {
        'httpMethod': 'GET', 'path': ROTA, 'responseMode': 'responseNode', 'options': {}}, 0, 0,
        webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/{ROTA}/get')))
    add('2g · Devolver challenge', 'n8n-nodes-base.respondToWebhook', 1.1, {
        'respondWith': 'text',
        'responseBody': "={{ $json.query['hub.mode'] === 'subscribe' ? ($json.query['hub.challenge'] || '') : '' }}",
        'options': {}}, 240, 0)
    add('1p · Webhook Meta (POST)', 'n8n-nodes-base.webhook', 2, {
        'httpMethod': 'POST', 'path': ROTA, 'responseMode': 'onReceived', 'options': {}}, 0, 220,
        webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/{ROTA}/post')))
    add('2p · Extrair status e respostas', 'n8n-nodes-base.code', 2, {'jsCode': EXTRAIR.strip()}, 240, 220)
    add('3p · Supabase fila_vero_webhook', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/fila_vero_webhook',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json',
        'jsonBody': '={{ JSON.stringify({ p_value: $json.value }) }}',
        'options': {'timeout': 20000}}, 480, 220, credentials=sb_cred, retryOnFail=True, maxTries=3, waitBetweenTries=3000)

    ligacoes = [('1g · Verificação Meta (GET)', '2g · Devolver challenge'),
                ('1p · Webhook Meta (POST)', '2p · Extrair status e respostas'),
                ('2p · Extrair status e respostas', '3p · Supabase fila_vero_webhook')]
    conns = {}
    for o, d in ligacoes:
        conns.setdefault(o, {'main': [[]]})['main'][0].append({'node': d, 'type': 'main', 'index': 0})
    settings = {'executionOrder': 'v1', 'saveDataErrorExecution': 'all', 'saveDataSuccessExecution': 'none',
                'saveManualExecutions': True, 'timezone': 'America/Sao_Paulo'}
    if ids.get('workflow_id'):
        settings['errorWorkflow'] = ids['workflow_id']
    return {'name': WF_NOME, 'nodes': nodes, 'connections': conns, 'settings': settings}


def salvar_export(wf):
    dm.checar_sem_segredo(wf)
    with open(EXPORT, 'w', encoding='utf-8') as f:
        json.dump(wf, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f'export: {os.path.relpath(EXPORT, REPO)} ({len(wf["nodes"])} nós)')


def achar_wf(ids):
    wid = ids.get(ID_KEY)
    if not wid:
        raise SystemExit(f'{ID_KEY} ausente em mari_ids.json — rode "criar" antes.')
    wf = dm.api('GET', f'/workflows/{wid}')
    if wf.get('name') != WF_NOME:
        raise SystemExit(f'o ID {wid} não é o {WF_NOME} (é "{wf.get("name")}") — abortado.')
    return wf


def cmd_criar():
    ids = dm.ler_ids()
    if ids.get(ID_KEY):
        raise SystemExit(f'já existe {ID_KEY} {ids[ID_KEY]} — use "estrutura".')
    if any(w.get('name') == WF_NOME for w in dm.api('GET', '/workflows?limit=250').get('data', [])):
        raise SystemExit(f'já existe um workflow chamado {WF_NOME} no n8n — nada foi criado.')
    wf = build(ids)
    dm.checar_sem_segredo(wf)
    r = dm.api('POST', '/workflows', wf)
    ids[ID_KEY] = r['id']
    dm.gravar_ids(ids)
    a = dm.api('POST', f'/workflows/{r["id"]}/activate')
    print(f'criado: {WF_NOME} ({r["id"]}), active={a.get("active")} · callback {CALLBACK}')
    cmd_exportar()


def cmd_estrutura():
    ids = dm.ler_ids()
    atual = achar_wf(ids)
    os.makedirs(dm.BACKUP_DIR, exist_ok=True)
    p = os.path.join(dm.BACKUP_DIR, f'{WF_NOME}_{datetime.datetime.now().strftime("%d%m%y_%H%M%S")}.json')
    with open(p, 'w', encoding='utf-8') as f:
        json.dump(atual, f, ensure_ascii=False, indent=2)
    print(f'backup: {os.path.relpath(p, REPO)}')
    dm.put(ids[ID_KEY], build(ids))
    cmd_exportar()


def cmd_exportar():
    wf = achar_wf(dm.ler_ids())
    salvar_export({'name': wf['name'], 'nodes': wf['nodes'], 'connections': wf['connections'],
                   'settings': wf.get('settings', {}), 'active': wf.get('active')})


def cmd_conferir():
    for a in mr._meta('GET', f'{WABA_FILA}/subscribed_apps').get('data', []):
        d = a.get('whatsapp_business_api_data', a)
        print(f'  app {d.get("name")} {d.get("id")} · override: {a.get("override_callback_uri") or "—"}')


def cmd_inscrever():
    achar_wf(dm.ler_ids())
    print('antes:'); cmd_conferir()
    print('inscrição simples:', mr._meta('POST', f'{WABA_FILA}/subscribed_apps'))
    r = mr._meta('POST', f'{WABA_FILA}/subscribed_apps',
                 {'override_callback_uri': CALLBACK, 'verify_token': secrets.token_urlsafe(24)})
    print('inscrição com override:', r)
    print('depois:'); cmd_conferir()


def cmd_simular():
    st, raw = mr._http('GET', f'{CALLBACK}?hub.mode=subscribe&hub.challenge=12345&hub.verify_token=x')
    print('GET verificação:', st, repr(raw[:40]))
    corpo = {'object': 'whatsapp_business_account', 'entry': [{'id': WABA_FILA, 'changes': [{'field': 'messages', 'value': {
        'messaging_product': 'whatsapp', 'metadata': {'display_phone_number': '553228880150', 'phone_number_id': PHONE_FILA},
        'statuses': [{'id': 'wamid.NIOGEN_TESTE_FILA', 'status': 'delivered', 'recipient_id': '5532999990099'}]}}]}]}
    st, raw = mr._http('POST', CALLBACK, corpo)
    print('POST webhook:', st, raw[:120])


if __name__ == '__main__':
    cmds = {'build': lambda: salvar_export(build(dm.ler_ids())), 'criar': cmd_criar, 'estrutura': cmd_estrutura,
            'inscrever': cmd_inscrever, 'conferir': cmd_conferir, 'simular': cmd_simular, 'exportar': cmd_exportar}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        raise SystemExit('uso: ' + ' | '.join(cmds))
    cmds[sys.argv[1]]()
