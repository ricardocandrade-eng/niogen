#!/usr/bin/env python3
# NIOGEN | n8n/deploy_meta_referral.py | 07/11/2026 — Claude Code (pedido do Ricardo: ad_id por conversa)
# Workflow n8n "meta_referral_entrada": recebe uma CÓPIA do webhook da WABA Nio (app NIOGEN inscrito na WABA com o
# callback aqui) e grava só o `referral` das mensagens que vêm de anúncio em meta_referrals (migration 0057).
# O Chatwoot NÃO depende disto: ele segue recebendo pelo app Renata Digital (override no número). Se este workflow cair,
# só a atribuição por anúncio para — o atendimento não. Nada do texto da mensagem é gravado.
#
# Caminho escolhido em 07/11 (C), no lugar de:
#   A) código por anúncio na mensagem pronta — reinicia o aprendizado, o cliente pode apagar, sem ctwa_clid;
#   B) webhook da WABA passando pelo n8n antes do Chatwoot — n8n fora do ar = atendimento cego.
#
# Uso:
#   python n8n/deploy_meta_referral.py build        # gera n8n/meta_referral_entrada.json (export, sem segredos)
#   python n8n/deploy_meta_referral.py criar        # cria e ATIVA o workflow (precisa estar no ar para a verificação da Meta)
#   python n8n/deploy_meta_referral.py estrutura    # PUT do workflow inteiro, backup antes
#   python n8n/deploy_meta_referral.py simular      # POST de um webhook falso com referral (telefone de teste) e mostra o retorno
#   python n8n/deploy_meta_referral.py permissoes   # confere se o META_ACCESS_TOKEN_NIO (app NIOGEN) tem whatsapp_business_management
#   python n8n/deploy_meta_referral.py inscrever    # inscreve o app NIOGEN na WABA Nio com override para este workflow
#   python n8n/deploy_meta_referral.py conferir     # lista os apps inscritos na WABA (Renata Digital deve continuar lá)
#   python n8n/deploy_meta_referral.py desinscrever # tira SÓ o app NIOGEN da WABA (o token é do NIOGEN) — volta ao estado de antes
#   python n8n/deploy_meta_referral.py exportar     # baixa o estado atual e grava o export sanitizado

import datetime
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'meta_referral_entrada.json')
WF_NOME = 'meta_referral_entrada'
ID_KEY = 'meta_referral_workflow_id'
SB = dm.SB
ROTA = 'niogen-meta-webhook-nio'
CALLBACK = f'{dm.N8N}/webhook/{ROTA}'
GRAPH = 'https://graph.facebook.com/v24.0'
WABA = '1419511943295487'                  # WABA Nio "Revendedor Autorizado Nio"
PHONE_ID_MARI = '1342993658907403'         # +55 31 2888-1265
TOKEN_ENV = 'META_ACCESS_TOKEN_NIO'        # system user Nio_API no app NIOGEN (precisa de whatsapp_business_management)
APP_NIOGEN = '1443153697173022'

EXTRAIR = r"""
// Só as mudanças "messages" do número da Mari que tenham pelo menos 1 mensagem com referral.
// Status de entrega/leitura e mensagens sem referral não seguem (nada é gravado).
const corpo = $input.first().json.body || {};
const saida = [];
for (const e of corpo.entry || []) {
  for (const c of e.changes || []) {
    const v = c.value || {};
    if (c.field !== 'messages' || !Array.isArray(v.messages)) continue;
    if (String(v.metadata?.phone_number_id || '') !== '%PHONE%') continue;
    const comRef = v.messages.filter((m) => m && m.referral);
    if (!comRef.length) continue;
    saida.push({ json: { value: { metadata: v.metadata, messages: comRef.map((m) => ({
      id: m.id, from: m.from, timestamp: m.timestamp, referral: m.referral })) } } });
  }
}
return saida;
""".replace('%PHONE%', PHONE_ID_MARI)


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/{WF_NOME}/{name}'))}
        n.update(extra)
        nodes.append(n)

    # GET: verificação da Meta na inscrição (hub.mode=subscribe → devolve hub.challenge).
    add('1g · Verificação Meta (GET)', 'n8n-nodes-base.webhook', 2, {
        'httpMethod': 'GET', 'path': ROTA, 'responseMode': 'responseNode', 'options': {}}, 0, 0,
        webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/{ROTA}/get')))
    add('2g · Devolver challenge', 'n8n-nodes-base.respondToWebhook', 1.1, {
        'respondWith': 'text',
        'responseBody': "={{ $json.query['hub.mode'] === 'subscribe' ? ($json.query['hub.challenge'] || '') : '' }}",
        'options': {}}, 240, 0)
    # POST: responde 200 na hora (a Meta reenvia se demorar) e segue.
    add('1p · Webhook Meta (POST)', 'n8n-nodes-base.webhook', 2, {
        'httpMethod': 'POST', 'path': ROTA, 'responseMode': 'onReceived', 'options': {}}, 0, 220,
        webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/{ROTA}/post')))
    add('2p · Extrair referral', 'n8n-nodes-base.code', 2, {'jsCode': EXTRAIR.strip()}, 240, 220)
    add('3p · Supabase gravar', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{SB}/rest/v1/rpc/meta_referral_gravar',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json',
        'jsonBody': '={{ JSON.stringify({ p_value: $json.value }) }}',
        'options': {'timeout': 20000}}, 480, 220, credentials=sb_cred, retryOnFail=True, maxTries=3, waitBetweenTries=3000)

    ligacoes = [('1g · Verificação Meta (GET)', '2g · Devolver challenge'),
                ('1p · Webhook Meta (POST)', '2p · Extrair referral'),
                ('2p · Extrair referral', '3p · Supabase gravar')]
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


def _http(method, url, corpo=None, headers=None):
    data = json.dumps(corpo).encode() if corpo is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={'Content-Type': 'application/json', **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode()
            return r.status, raw
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:600]


def cmd_simular():
    """Webhook falso com referral num telefone de TESTE (5532999990099). Grava 1 linha em meta_referrals (wamid de teste)."""
    st, raw = _http('GET', f'{CALLBACK}?hub.mode=subscribe&hub.challenge=12345&hub.verify_token=x')
    print('GET verificação:', st, repr(raw[:40]))
    ts = str(int(time.time()))
    corpo = {'object': 'whatsapp_business_account', 'entry': [{'id': WABA, 'changes': [{'field': 'messages', 'value': {
        'messaging_product': 'whatsapp', 'metadata': {'display_phone_number': '553128881265', 'phone_number_id': PHONE_ID_MARI},
        'messages': [{'from': '5532999990099', 'id': f'wamid.NIOGEN_TESTE_{ts}', 'timestamp': ts, 'type': 'text',
                      'text': {'body': 'teste'}, 'referral': {'source_type': 'ad', 'source_id': 'TESTE_AD',
                                                               'ctwa_clid': 'TESTE_CLID', 'headline': 'teste'}}]}}]}]}
    st, raw = _http('POST', CALLBACK, corpo)
    print('POST webhook:', st, raw[:120])


def _meta(method, path, params=None):
    tok = dm.env_usuario(TOKEN_ENV)
    if not tok:
        raise SystemExit(f'{TOKEN_ENV} ausente.')
    url = f'{GRAPH}/{path}'
    data = None
    if method == 'GET' and params:
        url += '?' + urllib.parse.urlencode(params)
    elif params:
        data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(url, data=data, method=method, headers={'Authorization': f'Bearer {tok}'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        raise SystemExit(f'[Meta] HTTP {e.code} em {method} {path}: {e.read().decode()[:500]}')


def cmd_permissoes():
    perms = {p['permission'] for p in _meta('GET', 'me/permissions').get('data', []) if p.get('status') == 'granted'}
    precisa = {'whatsapp_business_management'}
    falta = precisa - perms
    print('whatsapp_business_management:', 'OK' if not falta else 'FALTA', '| whatsapp_business_messaging:',
          'sim' if 'whatsapp_business_messaging' in perms else 'não')
    if falta:
        raise SystemExit('O token do app NIOGEN não tem whatsapp_business_management — ver o passo do Ricardo no INFRA §7.')


def cmd_conferir():
    for a in _meta('GET', f'{WABA}/subscribed_apps').get('data', []):
        d = a.get('whatsapp_business_api_data', a)
        print(f'  app {d.get("name")} {d.get("id")} · override: {a.get("override_callback_uri") or "—"}')


def cmd_inscrever():
    cmd_permissoes()
    achar_wf(dm.ler_ids())
    print('antes:'); cmd_conferir()
    # O verify_token só serve para a Meta conferir o GET; o workflow devolve o challenge a qualquer GET de inscrição.
    r = _meta('POST', f'{WABA}/subscribed_apps', {'override_callback_uri': CALLBACK, 'verify_token': secrets.token_urlsafe(24)})
    print('inscrição:', r)
    print('depois:'); cmd_conferir()


def cmd_desinscrever():
    r = _meta('DELETE', f'{WABA}/subscribed_apps')
    print('desinscrição do app NIOGEN:', r)
    cmd_conferir()


if __name__ == '__main__':
    cmds = {'build': lambda: salvar_export(build(dm.ler_ids())), 'criar': cmd_criar, 'estrutura': cmd_estrutura,
            'simular': cmd_simular, 'permissoes': cmd_permissoes, 'inscrever': cmd_inscrever, 'conferir': cmd_conferir,
            'desinscrever': cmd_desinscrever, 'exportar': cmd_exportar}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        raise SystemExit('uso: ' + ' | '.join(cmds))
    cmds[sys.argv[1]]()
